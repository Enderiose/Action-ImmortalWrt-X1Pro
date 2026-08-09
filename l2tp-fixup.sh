#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 一键配置脚本  (幂等 + 自动重试 + 自包含)
# ------------------------------------------------------------
# 用法:  刷机后把本脚本上传到 /tmp, 运行  sh /tmp/l2tp-fixup.sh
# 配置:  必须交互输入; 也可用 /tmp/l2tp-fixup.conf 预填 (KEY=VALUE)。
#        conf 支持的变量: IFNAME IPSEC_SERVER DST_SUBNET DST_TARGET
#        IKE_RIGHTID L2TP_USER L2TP_PASS PSK MTU
#
# 本脚本一次性完成:
#   1. 安装 strongswan      6. 防火墙 (WAN 放行 IPsec + VPN zone)
#   2. 禁用 kernel-libipsec  7. 启动 IPsec
#   3. 写 IPsec 配置        8. 拉起 L2TP
#   4. 清理旧 VPN 配置      9. 静态路由
#   5. L2TP 接口配置       10. 验证
#
# 幂等: 第二次运行会找到已有接口/配置并修改测试, 不会重复新建。
# ============================================================

CONF="/tmp/l2tp-fixup.conf"
[ -f "$CONF" ] && . "$CONF"

# ---------- 0. 配置项 (无默认值, 必须提供) ----------
IFNAME="${IFNAME:-}"
IPSEC_SERVER="${IPSEC_SERVER:-}"
DST_SUBNET="${DST_SUBNET:-}"
DST_TARGET="${DST_TARGET:-}"
IKE_RIGHTID="${IKE_RIGHTID:-}"
L2TP_USER="${L2TP_USER:-}"
L2TP_PASS="${L2TP_PASS:-}"
PSK="${PSK:-}"
MTU="${MTU:-1400}"

# 交互输入 (已有环境变量/conf 则跳过对应提示)
read -p "L2TP 逻辑接口名: " v; [ -n "$v" ] && IFNAME=$v
[ -z "$IFNAME" ] && { echo "[ERROR] 接口名不能为空"; exit 1; }

read -p "IPsec 服务器域名或IP: " v; [ -n "$v" ] && IPSEC_SERVER=$v
[ -z "$IPSEC_SERVER" ] && { echo "[ERROR] 服务器不能为空"; exit 1; }

read -p "远端网段(CIDR, 如 10.0.0.0/24): " v; [ -n "$v" ] && DST_SUBNET=$v
[ -z "$DST_SUBNET" ] && { echo "[ERROR] 远端网段不能为空"; exit 1; }

read -p "远端目标IP (用于测试连通): " v; [ -n "$v" ] && DST_TARGET=$v
[ -z "$DST_TARGET" ] && { echo "[ERROR] 远端目标IP不能为空"; exit 1; }

read -p "IKE rightid (通常=远端目标IP): " v; [ -n "$v" ] && IKE_RIGHTID=$v
[ -z "$IKE_RIGHTID" ] && IKE_RIGHTID="$DST_TARGET"

read -p "L2TP 用户名: " v; [ -n "$v" ] && L2TP_USER=$v
[ -z "$L2TP_USER" ] && { echo "[ERROR] 用户名不能为空"; exit 1; }

[ -z "$L2TP_PASS" ] && { read -s -p "L2TP 密码: " L2TP_PASS; echo; }
[ -z "$L2TP_PASS" ] && { echo "[ERROR] L2TP 密码不能为空"; exit 1; }

[ -z "$PSK" ] && { read -s -p "IPsec PSK: " PSK; echo; }
[ -z "$PSK" ] && { echo "[ERROR] IPsec PSK 不能为空"; exit 1; }

read -p "MTU [$MTU]: " v; [ -n "$v" ] && MTU=$v

echo "=============================================="
echo " 应用配置:"
echo "  if=$IFNAME (dev l2tp-$IFNAME)"
echo "  server=$IPSEC_SERVER  rightid=$IKE_RIGHTID"
echo "  subnet=$DST_SUBNET  target=$DST_TARGET"
echo "  user=$L2TP_USER"
echo "=============================================="

# CIDR -> target / netmask
NET_TARGET="${DST_SUBNET%/*}"
NET_PREFIX="${DST_SUBNET#*/}"
cidr2mask() {
  local p=$1 full=$(( 0xFFFFFFFF << (32 - p) ))
  full=$(( full & 0xFFFFFFFF ))
  printf "%d.%d.%d.%d" $(( (full >> 24) & 255 )) $(( (full >> 16) & 255 )) \
                       $(( (full >> 8) & 255 )) $(( full & 255 ))
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
log "[ok] 已写 /etc/ipsec.secrets"

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
uci commit network
log "[ok] 已写 network.$IFNAME (defaultroute=0, 不抢默认路由)"

# ---------- 6. 防火墙 (必须先配, 否则 IPsec 的 UDP 500/4500 被拦) -----
echo "[6] 配置防火墙 ..."
# WAN zone: 放行 IPsec IKE/NAT-T (UDP 500, 4500) + L2TP (UDP 1701) 入站
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
wait_established(){
  local t=0
  while [ $t -lt 30 ]; do
    ipsec status 2>/dev/null | grep -q ESTABLISHED && return 0
    sleep 2; t=$((t + 2))
  done
  return 1
}
bring_ipsec(){
  /etc/init.d/ipsec restart >/dev/null 2>&1
  wait_established
}
IPSEC_OK=0
for ATT in 1 2 3; do
  echo "[7] 启动 IPsec (尝试 $ATT/3) ..."
  /etc/init.d/ipsec stop >/dev/null 2>&1
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
done
[ $IPSEC_OK -eq 1 ] || { echo "[ERROR] IPsec 多次重试仍失败, 请检查 WAN/服务端/PSK/rightid"; exit 1; }

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
ESP=$(ip xfrm state 2>/dev/null | grep -ic "proto esp")
if [ "$ESP" -ge 1 ]; then echo "  ESP SA 数: $ESP  (已加密)"; else echo "  ESP SA 数: 0  (未加密!)"; fi
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
echo " 完成. 接口 $IFNAME / 远端 $DST_SUBNET 走加密隧道, 其余走 WAN."
