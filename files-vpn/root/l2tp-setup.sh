#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 一键配置脚本  (幂等 + 自动重试)
# ------------------------------------------------------------
# 用法:  刷机后把本脚本上传到任意目录, 运行  sh /path/l2tp-setup.sh
# 配置:  必须交互输入; 也可用 本脚本同目录的 l2tp-setup.conf 预填 (KEY=VALUE)。
#        conf 支持的变量: IFNAME IPSEC_SERVER DST_SUBNET DST_TARGET
#        IKE_RIGHTID L2TP_USER L2TP_PASS PSK MTU
#        注: PSK 可选 — 留空则纯 L2TP (不启用 IPsec); 非空则 L2TP/IPsec (PSK 认证)
#
# 本脚本一次性完成:
#   1. 安装 strongswan      6. 防火墙 (WAN 放行 IPsec + VPN zone)
#   2. 禁用 kernel-libipsec  7. 启动 IPsec
#   3. 写 IPsec 配置        8. 拉起 L2TP
#   4. 清理旧 VPN 配置      9. 静态路由
#   5. L2TP 接口配置       10. 验证
#
# 幂等: 第二次运行会找到已有接口/配置并修改测试, 不会重复新建。
# 配套脚本 (l2tp-remove.sh 等) 统一由 down-scripts.sh 一次性拉取, 本脚本不再自行下载。
# ============================================================

# conf 与本脚本同目录 (不写死 /tmp, 避免重启即丢)
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR="$(pwd)"
CONF="$SCRIPT_DIR/l2tp-setup.conf"
if [ -f "$CONF" ]; then
  echo "[info] 检测到 $CONF (脚本同目录), 已载入其中的配置作为默认值"
  . "$CONF"
else
  echo "[info] 未检测到 $CONF, 将使用交互输入 (运行后可选择在同目录生成该文件以便下次快速配置)"
fi

# ---------- 0. 配置项 ----------
IFNAME="${IFNAME:-}"
IPSEC_SERVER="${IPSEC_SERVER:-}"
DST_SUBNET="${DST_SUBNET:-}"
DST_TARGET="${DST_TARGET:-}"
IKE_RIGHTID="${IKE_RIGHTID:-}"
L2TP_USER="${L2TP_USER:-}"
L2TP_PASS="${L2TP_PASS:-}"
PSK="${PSK:-}"
MTU="${MTU:-1400}"

_have_tty() { [ -t 0 ] && return 0 || return 1; }

# 无终端 (hotplug/sshpass) → 从 UCI 现有 L2TP 接口自动读取
# 有终端 → 交互输入
if ! _have_tty; then
  [ -z "$IFNAME" ] && IFNAME=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" | head -1)
  if [ -n "$IFNAME" ]; then
    [ -z "$IPSEC_SERVER" ] && IPSEC_SERVER=$(uci -q get network.$IFNAME.server)
    [ -z "$DST_SUBNET" ] && DST_SUBNET=$(uci -q get network.$IFNAME.dst_subnet)
    [ -z "$DST_TARGET" ] && DST_TARGET=$(uci -q get network.$IFNAME.dst_target)
    [ -z "$IKE_RIGHTID" ] && IKE_RIGHTID=$(uci -q get network.$IFNAME.ike_rightid)
    [ -z "$L2TP_USER" ] && L2TP_USER=$(uci -q get network.$IFNAME.username)
    [ -z "$L2TP_PASS" ] && L2TP_PASS=$(uci -q get network.$IFNAME.password)
    [ -z "$PSK" ] && PSK=$(uci -q get network.$IFNAME.psks)
    [ -z "$MTU" ] && MTU=$(uci -q get network.$IFNAME.mtu)
  fi
else
  _must() {
    local prompt="$1" var="$2" current="$3"
    eval "local val=\$$var"
    while [ -z "$val" ]; do
      [ -n "$current" ] && printf '%s [%s]: ' "$prompt" "$current" || printf '%s: ' "$prompt"
      read -r val
      [ -z "$val" ] && [ -n "$current" ] && val="$current"
      [ -z "$val" ] && echo '  [!] 不能为空'
    done
    eval "$var=\"$val\""
  }
  _must_sec() {
    local prompt="$1" var="$2" current="$3"
    eval "local val=\$$var"
    while [ -z "$val" ]; do
      [ -n "$current" ] && printf '%s [****]: ' "$prompt" || printf '%s: ' "$prompt"
      read -s -r val; echo
      [ -z "$val" ] && [ -n "$current" ] && val="$current"
      [ -z "$val" ] && echo '  [!] 不能为空'
    done
    eval "$var=\"$val\""
  }
  _must "L2TP 逻辑接口名" IFNAME "$IFNAME"
  _must "IPsec 服务器域名或IP" IPSEC_SERVER "$IPSEC_SERVER"
  _must "远端网段(如 10.0.0.0/24)" DST_SUBNET "$DST_SUBNET"
  _must "远端目标IP(测试连通)" DST_TARGET "$DST_TARGET"
  _must "L2TP 用户名" L2TP_USER "$L2TP_USER"
  _must_sec "L2TP 密码" L2TP_PASS "$L2TP_PASS"
  printf 'IPsec PSK (留空=纯L2TP不加密): '; read -s -r v; echo
  [ -n "$v" ] && PSK="$v"
  if [ -n "$PSK" ]; then
    [ -z "$IKE_RIGHTID" ] && IKE_RIGHTID="$DST_TARGET"
    _must "IKE rightid" IKE_RIGHTID "$IKE_RIGHTID"
  fi
  printf 'MTU [%s]: ' "${MTU:-1400}"; read -r v; [ -n "$v" ] && MTU="$v"
fi

# PSK 为空 → 纯 L2TP (不启用 IPsec)
USE_IPSEC=0
[ -n "$PSK" ] && USE_IPSEC=1

# 最终校验: 缺任何必填则退出
_missing(){ [ -z "$(eval echo \$$1)" ] && echo "  [ERROR] $2 未设置 (无终端时请先跑一次交互版或在脚本同目录填 l2tp-setup.conf)"; }
err=0
_missing IFNAME "接口名" && err=1
_missing IPSEC_SERVER "服务器" && err=1
_missing DST_SUBNET "远端网段" && err=1
_missing DST_TARGET "远端目标IP" && err=1
[ $USE_IPSEC -eq 1 ] && _missing IKE_RIGHTID "IKE rightid" && err=1
_missing L2TP_USER "L2TP用户名" && err=1
_missing L2TP_PASS "L2TP密码" && err=1
[ $err -eq 1 ] && exit 1

echo "=============================================="
echo " 应用配置:"
echo "  if=$IFNAME (dev l2tp-$IFNAME)"
echo "  server=$IPSEC_SERVER"
echo "  subnet=$DST_SUBNET  target=$DST_TARGET"
echo "  user=$L2TP_USER"
if [ $USE_IPSEC -eq 1 ]; then
  echo "  IPsec: PSK 认证 (rightid=$IKE_RIGHTID)"
else
  echo "  IPsec: 未启用 (纯 L2TP 明文)"
fi
echo "=============================================="

# CIDR -> target / netmask
NET_TARGET="${DST_SUBNET%/*}"
NET_PREFIX="${DST_SUBNET#*/}"
cidr2mask() {
  # 逐字节构造 32 位掩码, 避免 shell 32 位算术对 0xFFFFFFFF<<N 的溢出(原实现 p=24 算成 0.0.0.0)
  local p=$1 byte i result=""
  for i in 0 1 2 3; do
    if [ "$p" -ge 8 ]; then
      byte=255; p=$((p - 8))
    else
      byte=0
      [ "$p" -gt 0 ] && byte=$(( 256 - (1 << (8 - p)) ))
      p=0
    fi
    result="$result$byte"
    [ "$i" -lt 3 ] && result="$result."
  done
  echo "$result"
}
NET_MASK="$(cidr2mask "$NET_PREFIX")"

log(){ echo "  $*"; }
NET_DEV="l2tp-$IFNAME"
WAN_DEV="${WAN_DEV:-$(ip route show default 2>/dev/null | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)}"
[ -z "$WAN_DEV" ] && { echo "[ERROR] 无法检测 WAN 设备"; exit 1; }

# ── 探测 WAN 网关（仅作建议值，最终由用户确认）──
_suggest_gateway(){
  local gw
  gw=$(ip route show default dev "$WAN_DEV" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
  [ -z "$gw" ] && gw=$(ip route show default 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
  [ -z "$gw" ] && gw=$(ifstatus wan 2>/dev/null | sed -n 's/.*"gateway": "\([^"]*\)".*/\1/p' | head -1)
  [ -z "$gw" ] && gw=$(awk '/^gateway/{print $2; exit}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
  echo "$gw"
}

SUGGESTED_GW=$(_suggest_gateway)

# WAN_GW: 优先环境变量/conf，其次交互输入，再次探测值
if [ -z "$WAN_GW" ]; then
  read -p "WAN 网关 (建议: $SUGGESTED_GW): " v
  [ -n "$v" ] && WAN_GW=$v
  [ -z "$WAN_GW" ] && WAN_GW="$SUGGESTED_GW"
fi
[ -z "$WAN_GW" ] && { echo "[ERROR] WAN 网关不能为空"; exit 1; }
log "WAN 网关: $WAN_GW (dev $WAN_DEV)"

# 确保默认路由在 WAN(eth0), 并删除任何走 L2TP 的默认路由 (防抢默认路由)
fix_default_route(){
  # 先把 L2TP 抢走的默认路由删掉
  ip route del default dev "$NET_DEV" 2>/dev/null
  # 再确保默认路由在 WAN（用预探测的网关）
  if ! ip route show default 2>/dev/null | grep -q "dev $WAN_DEV"; then
    log "[!] 默认路由不在 WAN, 修正为 via $WAN_GW dev $WAN_DEV"
    ip route del default 2>/dev/null
    ip route add default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
  fi
}

# ---------- 1. 安装 strongswan (若缺失) ----------
if [ $USE_IPSEC -eq 1 ]; then
if [ ! -x /usr/sbin/ipsec ]; then
  echo "[1] 未检测到 strongswan, opkg 安装中..."
  opkg update >/dev/null 2>&1
  opkg install strongswan strongswan-default strongswan-ipsec strongswan-mod-stroke \
    strongswan-mod-vici strongswan-swanctl strongswan-mod-kernel-netlink \
    strongswan-mod-kernel-libipsec swanmon 2>&1 | tail -3
fi
[ -x /usr/sbin/ipsec ] || { echo "[ERROR] strongswan 安装失败, 请检查 opkg 源"; exit 1; }
/etc/init.d/ipsec enable >/dev/null 2>&1
log "[ok] strongswan 就绪"

# ---------- 2. 禁用 kernel-libipsec ----------
if [ -f /etc/strongswan.d/charon/kernel-libipsec.conf ]; then
  sed -i 's/^[[:space:]]*load[[:space:]]*=[[:space:]]*yes/load = no/' \
    /etc/strongswan.d/charon/kernel-libipsec.conf
  log "[ok] kernel-libipsec 已禁用"
fi

# ---------- 3. 写 IPsec 配置 ----------
cat > /etc/ipsec.secrets <<EOF
: PSK "$PSK"
EOF
chmod 600 /etc/ipsec.secrets
log "[ok] 已写 /etc/ipsec.secrets (PSK 认证)"

cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 1, knl 1, cfg 0"
    uniqueids=no

conn l2tp-$IFNAME
    keyexchange=ikev1
    ike=aes256-sha256-modp2048,aes256-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha256,aes256-sha1,3des-sha1!
    left=%defaultroute
    leftprotoport=17/1701
    right=$IPSEC_SERVER
    rightid=$IKE_RIGHTID
    rightprotoport=17/1701
    type=transport
    authby=secret
    auto=start
    keyingtries=%forever
    dpdaction=restart
    dpddelay=30s
    dpdtimeout=120s
EOF
log "[ok] 已写 /etc/ipsec.conf (conn l2tp-$IFNAME)"
else
  log "[skip] PSK 为空, 不安装/配置 IPsec (纯 L2TP 明文模式)"
fi

# ---------- 4. 清理旧的 VPN 残留 (幂等, 防重复) ----------
echo "[4] 清理旧 VPN 配置 (接口/路由/防火墙) ..."
for i in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=interface/\1/p'); do
  if [ "$(uci -q get network.$i.proto)" = "l2tp" ] && [ "$i" != "$IFNAME" ]; then
    uci delete network.$i; log "  [clean] 删旧 L2TP 接口 $i"
  fi
done
for r in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=route/\1/p'); do
  case "$(uci -q get network.$r.interface)" in l2tp-*|$IFNAME) uci delete network.$r ;; esac
done
for z in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone/\1/p'); do
  [ "$(uci -q get firewall.$z.name)" = "VPN" ] && uci delete firewall.$z
done
for f in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=forwarding/\1/p'); do
  s=$(uci -q get firewall.$f.src); d=$(uci -q get firewall.$f.dest)
  if { [ "$s" = "lan" ] && [ "$d" = "VPN" ]; } || { [ "$s" = "VPN" ] && [ "$d" = "lan" ]; }; then
    uci delete firewall.$f
  fi
done
log "[ok] 旧 VPN 残留已清理"

# ---------- 5. L2TP 接口 (幂等) ----------
uci set network.$IFNAME=interface
uci set network.$IFNAME.proto='l2tp'
uci set network.$IFNAME.server="$IPSEC_SERVER"
uci set network.$IFNAME.username="$L2TP_USER"
uci set network.$IFNAME.password="$L2TP_PASS"
uci set network.$IFNAME.mtu="$MTU"
uci set network.$IFNAME.auto='1'
uci set network.$IFNAME.defaultroute='0'
uci set network.$IFNAME.metric='100'
uci commit network
log "[ok] 已写 network.$IFNAME (defaultroute=0, metric=100, 不抢默认路由)"

# 持久化 IPsec 参数到 UCI (sysupgrade 保留配置时备份, 升级后自动恢复)
# PSK 为空 → 纯 L2TP, 持久化空 psks 标记模式
uci set network.$IFNAME.psks="$PSK"
if [ $USE_IPSEC -eq 1 ]; then
  uci set network.$IFNAME.ike_rightid="$IKE_RIGHTID"
  uci set network.$IFNAME.ike_keyexchange='ikev1'
  uci set network.$IFNAME.ike_algo='aes256-sha256-modp2048,aes256-sha1-modp1024,3des-sha1-modp1024!'
  uci set network.$IFNAME.ike_esp='aes256-sha256,aes256-sha1,3des-sha1!'
  uci set network.$IFNAME.ike_type='transport'
  uci set network.$IFNAME.ike_auto='start'
  uci set network.$IFNAME.ike_keyingtries='%forever'
  uci set network.$IFNAME.ike_dpdaction='restart'
  uci set network.$IFNAME.ike_dpddelay='30s'
  uci set network.$IFNAME.ike_dpdtimeout='120s'
fi
uci commit network
log "[ok] ipsec 参数已持久到 UCI"

# 持久化 DST_TARGET/DST_SUBNET → 供 check-vpn.sh / hotplug 自动检测
uci set network.$IFNAME.dst_target="$DST_TARGET"
uci set network.$IFNAME.dst_subnet="$DST_SUBNET"
uci commit network
log "[ok] DST_TARGET/SUBNET 已持久到 UCI"

# ---------- 6. 防火墙 (必须先配, 否则 IPsec 的 UDP 500/4500 被拦) -----
echo "[6] 配置防火墙 ..."
# WAN zone: 放行 IPsec IKE/NAT-T (UDP 500, 4500) + L2TP (UDP 1701) 入站
if [ $USE_IPSEC -eq 1 ]; then
uci set firewall.wan_ipsec=rule
uci set firewall.wan_ipsec.name='Allow-IPsec'
uci set firewall.wan_ipsec.src='wan'
uci set firewall.wan_ipsec.proto='udp'
uci set firewall.wan_ipsec.dest_port='500 4500'
uci set firewall.wan_ipsec.target='ACCEPT'

# WAN zone: 允许 ESP 协议 (IP protocol 50) — 内核已处理，加规则保底
uci set firewall.wan_esp=rule
uci set firewall.wan_esp.name='Allow-ESP'
uci set firewall.wan_esp.src='wan'
uci set firewall.wan_esp.proto='esp'
uci set firewall.wan_esp.target='ACCEPT'
fi

# VPN zone: 虚拟接口、全放行 + masq (出隧道做 SNAT)
uci set firewall.VPN=zone
uci set firewall.VPN.name='VPN'
uci set firewall.VPN.network="$IFNAME"
uci set firewall.VPN.input='ACCEPT'
uci set firewall.VPN.output='ACCEPT'
uci set firewall.VPN.forward='ACCEPT'
uci set firewall.VPN.masq='1'

# lan ↔ VPN 转发
uci set firewall.lan_to_vpn=forwarding
uci set firewall.lan_to_vpn.src='lan'
uci set firewall.lan_to_vpn.dest='VPN'
uci set firewall.vpn_to_lan=forwarding
uci set firewall.vpn_to_lan.src='VPN'
uci set firewall.vpn_to_lan.dest='lan'

uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
log "[ok] 防火墙: WAN UDP 500/4500 + ESP + VPN zone + lan↔VPN 转发"

# ---------- 7. 启动 IPsec (重试 + 诊断) ----------
if [ $USE_IPSEC -eq 1 ]; then
wait_established(){
  local t=0
  while [ $t -lt 30 ]; do
    ipsec status 2>/dev/null | grep -q ESTABLISHED && return 0
    sleep 2; t=$((t + 2))
  done
  return 1
}
bring_ipsec(){
  # 彻底停掉所有残留的 charon/starter (自编译固件 init stop 可能杀不干净)
  /etc/init.d/ipsec stop >/dev/null 2>&1
  killall -9 charon starter 2>/dev/null
  sleep 1
  # 确保 ipsec.conf 存在 (缺失则从 UCI 重建)
  [ -f /etc/ipsec.conf ] || { log "[!] ipsec.conf 缺失, 从 UCI 重建"; /etc/uci-defaults/92-recover-ipsec; }
  ipsec start >/dev/null 2>&1
  wait_established
}
IPSEC_OK=0
for ATT in 1 2 3; do
  echo "[7] 启动 IPsec (尝试 $ATT/3) ..."
  /etc/init.d/ipsec stop >/dev/null 2>&1
  killall -9 charon starter 2>/dev/null
  sleep 1
  ip xfrm state flush >/dev/null 2>&1
  # 确保默认路由在 WAN
  fix_default_route
  # 前置: kernel-libipsec 必须禁用
  if grep -qs "load = yes" /etc/strongswan.d/charon/kernel-libipsec.conf 2>/dev/null; then
    sed -i 's/^[[:space:]]*load[[:space:]]*=[[:space:]]*yes/load = no/' \
      /etc/strongswan.d/charon/kernel-libipsec.conf
    log "[!] 重新禁用 kernel-libipsec"
  fi
  if bring_ipsec; then IPSEC_OK=1; echo "  [ok] IPsec ESTABLISHED"; break; fi
  echo "  [!] 未建立. 当前默认路由: $(ip route show default)"
  echo "  [diag] charon status: $(pgrep charon >/dev/null 2>&1 && echo running || echo dead)"
  echo "  [diag] ipsec.log tail: $(tail -3 /var/log/daemon 2>/dev/null | grep charon || logread -e charon 2>/dev/null | tail -3)"
done
[ $IPSEC_OK -eq 1 ] || { echo "[ERROR] IPsec 多次重试仍失败, 请检查 WAN/服务端/PSK/rightid"; exit 1; }
else
  log "[skip] 未启用 IPsec, 直接进入 L2TP 阶段"
fi

# ---------- 8. 拉起 L2TP (重试) ----------
L2TP_OK=0
for ATT in 1 2 3; do
  echo "[7] 拉起 L2TP (尝试 $ATT/3) ..."
  ifdown $IFNAME >/dev/null 2>&1; sleep 2
  ifup $IFNAME >/dev/null 2>&1
  t=0
  while [ $t -lt 30 ]; do
    ifstatus $IFNAME 2>/dev/null | grep -q '"up": true' && { L2TP_OK=1; break 2; }
    sleep 3; t=$((t + 3))
  done
  echo "  [!] L2TP 未 UP, 重试..."
done
[ $L2TP_OK -eq 1 ] || { echo "[ERROR] L2TP 无法 UP"; exit 1; }
log "[ok] L2TP UP"

# ---------- 9. 静态路由 (幂等 + 即时) ----------
uci set network.vpn_route=route
uci set network.vpn_route.interface="$IFNAME"
uci set network.vpn_route.target="$NET_TARGET"
uci set network.vpn_route.netmask="$NET_MASK"
uci commit network
ip route replace "$DST_SUBNET" dev "$NET_DEV"
log "[ok] 静态路由 $DST_SUBNET dev $NET_DEV"

# 兜底: 防止 L2TP 抢默认路由 (defaultroute=0 在本固件未必可靠)
fix_default_route

# ---------- 10. 验证 ----------
echo "=============================================="
echo " 验证:"
if [ $USE_IPSEC -eq 1 ]; then
  ESP=$(ip xfrm state 2>/dev/null | grep -ic "proto esp")
  if [ "$ESP" -ge 1 ]; then echo "  ESP SA 数: $ESP  (已加密)"; else echo "  ESP SA 数: 0  (未加密!)"; fi
else
  echo "  IPsec: 未启用 (纯 L2TP 明文传输)"
fi
echo "  默认路由: $(ip route show default)"
echo "  VPN 路由: $(ip route show $DST_SUBNET)"
if ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
  echo "  ping $DST_TARGET: 通"
else
  echo "  ping $DST_TARGET: 不通(对端常禁 ICMP, 看 curl)"
fi
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && echo "  curl http://$DST_TARGET/ -> HTTP $CODE"
if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
  echo "  外网(223.5.5.5): 通 (走 WAN)"
else
  echo "  外网(223.5.5.5): 不通"
fi
echo "=============================================="
if [ $USE_IPSEC -eq 1 ]; then
  echo " 完成. 接口 $IFNAME / 远端 $DST_SUBNET 走加密隧道, 其余走 WAN."
else
  echo " 完成. 接口 $IFNAME / 远端 $DST_SUBNET 走纯 L2TP (不加密), 其余走 WAN."
fi

# ---------- 11. 是否保存配置以便下次使用 ----------
if [ -t 0 ] && [ ! -f "$CONF" ]; then
  echo
  printf '是否生成 %s 以便下次快速配置? [y/N]: ' "$CONF"
  read -r ans
  case "$ans" in
    y|Y|yes|YES)
      {
        echo "# 由 l2tp-setup.sh 自动生成, 下次运行将作为默认值读取"
        echo "IFNAME=\"$IFNAME\""
        echo "IPSEC_SERVER=\"$IPSEC_SERVER\""
        echo "DST_SUBNET=\"$DST_SUBNET\""
        echo "DST_TARGET=\"$DST_TARGET\""
        echo "L2TP_USER=\"$L2TP_USER\""
        echo "L2TP_PASS=\"$L2TP_PASS\""
        echo "MTU=\"$MTU\""
        [ -n "$IKE_RIGHTID" ] && echo "IKE_RIGHTID=\"$IKE_RIGHTID\""
        [ -n "$PSK" ] && echo "PSK=\"$PSK\""
      } > "$CONF"
      echo "[ok] 已生成 $CONF (含账号/密码明文; 与脚本同目录, 下次运行自动读取)"
      ;;
    *) echo "已跳过, 未生成 $CONF" ;;
  esac
elif [ -f "$CONF" ]; then
  echo "提示: 已存在 $CONF, 下次运行将直接读取其中配置作为默认值"
fi
