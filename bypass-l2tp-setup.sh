#!/bin/sh
# ============================================================
# bypass-l2tp-setup.sh — 旁路设备 L2TP/IPsec 一键配置脚本
#
# 场景: 旁路设备通过 br-lan 挂主路由, 建立 L2TP/IPsec 隧道到远端
# 拓扑:
#   LAN设备 ←→ 主路由(192.168.68.1) ←→ 旁路设备(192.168.68.x)
#                                                   │
#                                          L2TP/IPsec 隧道
#                                                   │
#                                             远端 10.0.0.0/24
#
# 用法:
#   交互:  sh bypass-l2tp-setup.sh
#   非交互: 先写 /tmp/bypass-l2tp.conf, 再 sh bypass-l2tp-setup.sh
#
# 环境变量 (全部必填, 交互模式逐个询问):
#   IFNAME        L2TP 接口名 (如 001)
#   IPSEC_SERVER  IPsec 服务端地址 (域名或IP)
#   DST_SUBNET    远端网段 (如 10.0.0.0/24)
#   DST_TARGET    远端目标IP (用于检测, 如 10.0.0.253)
#   IKE_RIGHTID   对端 IKE 标识 (ikuai 填远端内网IP, 如 10.0.0.253)
#   L2TP_USER     L2TP 用户名
#   L2TP_PASS     L2TP 密码
#   PSK           IPsec 预共享密钥
#   MAIN_GW       主路由网关 (默认自动检测)
#   MAIN_LAN      主路由 LAN 网段 (默认自动检测)
# ============================================================

set -e

# --- 配置加载 ---
if [ -f /tmp/bypass-l2tp.conf ]; then
  . /tmp/bypass-l2tp.conf
  echo ">>> 从 /tmp/bypass-l2tp.conf 加载配置"
fi

# --- 交互输入 ---
ask() {
  local var="$1" prompt="$2" default="$3"
  local val
  eval "val=\${$var:-}"
  [ -n "$val" ] && return
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read -r val </dev/tty
  [ -z "$val" ] && val="$default"
  eval "$var=\"$val\""
}

ask_psw() {
  local var="$1" prompt="$2"
  eval "[ -n \"\${$var:-}\" ]" && return
  printf "%s: " "$prompt"
  stty -echo </dev/tty 2>/dev/null
  read -r val </dev/tty
  stty echo </dev/tty 2>/dev/null
  echo
  eval "$var=\"$val\""
}

ask IFNAME    "L2TP 接口名"           "001"
ask IPSEC_SERVER "IPsec 服务端地址"
ask DST_SUBNET   "远端目标网段 (如 10.0.0.0/24)"
ask DST_TARGET   "远端测试IP (如 10.0.0.253)"
ask IKE_RIGHTID  "对端IKE标识 (ikuai填远端内网IP)"
ask L2TP_USER    "L2TP 用户名"
ask_psw L2TP_PASS "L2TP 密码"
ask_psw PSK       "IPsec 预共享密钥"

# 自动检测主路由信息
auto_detect_main() {
  local lan_if="br-lan"

  # 网关
  if [ -z "$MAIN_GW" ]; then
    MAIN_GW=$(ip route show default 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
    [ -z "$MAIN_GW" ] && MAIN_GW=$(uci -q get network.lan.gateway 2>/dev/null)
    [ -z "$MAIN_GW" ] && MAIN_GW="192.168.68.1"
  fi

  # LAN IP
  if [ -z "$MAIN_LAN_IP" ]; then
    MAIN_LAN_IP=$(ip addr show "$lan_if" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$MAIN_LAN_IP" ] && MAIN_LAN_IP="192.168.68.111"
  fi

  echo ">>> 主路由网关: $MAIN_GW, 本机IP: $MAIN_LAN_IP"
}
auto_detect_main

L2TP_DEV="l2tp-$IFNAME"

# ============================================================
# 前置: 检测/安装 strongswan
# ============================================================
echo ""
echo "===== [0] 环境检测 ====="

if ! which ipsec >/dev/null 2>&1; then
  echo "  [*] strongswan 未安装, 正在安装..."
  opkg update >/dev/null 2>&1
  opkg install strongswan-default strongswan-ipsec strongswan-mod-stroke >/dev/null 2>&1 || {
    echo "  [FAIL] strongswan 安装失败, 请手工安装"
    exit 1
  }
  echo "  [ok] strongswan 已安装"
else
  echo "  [ok] strongswan 已就绪"
fi

if ! which xl2tpd >/dev/null 2>&1; then
  echo "  [FAIL] xl2tpd 未安装, 请 opkg install xl2tpd"
  exit 1
fi
echo "  [ok] xl2tpd 已就绪"

# kernel-libipsec 检查 (必须禁用)
if ipsec listplugins 2>/dev/null | grep -q kernel-libipsec; then
  sed -i 's/^[[:space:]]*load.*kernel-libipsec/#\0/' /etc/strongswan.d/charon/*.conf 2>/dev/null
  sed -i 's/^[[:space:]]*load =.*kernel-libipsec/#\0/' /etc/strongswan.d/charon/*.conf 2>/dev/null
  echo "  [*] kernel-libipsec 已禁用"
fi

# ============================================================
# 1. IPsec 配置
# ============================================================
echo ""
echo "===== [1] 写 IPsec 配置 ====="

cat > /etc/ipsec.secrets <<EOF
: PSK "$PSK"
EOF
echo "  [ok] /etc/ipsec.secrets"

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
    keylife=24h
    rekeymargin=20m
    ikelifetime=48h
    dpdaction=restart
    dpddelay=60s
    dpdtimeout=300s
EOF
echo "  [ok] /etc/ipsec.conf"

# ============================================================
# 2. xl2tpd 配置
# ============================================================
echo ""
echo "===== [2] 写 xl2tpd 配置 ====="

# xl2tpd 隧道密钥
if ! grep -q "yxd456258" /etc/xl2tpd/xl2tp-secrets 2>/dev/null; then
  echo "* * $PSK" > /etc/xl2tpd/xl2tp-secrets
fi
echo "  [ok] /etc/xl2tpd/xl2tp-secrets"

# PPP 用户认证 (追加不覆盖已有其他用户)
grep -q "^$L2TP_USER " /etc/ppp/chap-secrets 2>/dev/null || \
  echo "$L2TP_USER * $L2TP_PASS 10.1.0.0/24" >> /etc/ppp/chap-secrets
echo "  [ok] /etc/ppp/chap-secrets"

# PPP options
cat > /etc/ppp/options.xl2tpd <<EOF
noauth
debug
dump
logfd 2
logfile /var/log/xl2tpd.log
noccp
novj
novjccomp
nopcomp
noaccomp
nodeflate
nobsdcomp
mtu 1300
mru 1300
require-mschap-v2
lcp-echo-interval 20
lcp-echo-failure 15
connect-delay 5000
nodefaultroute
noipdefault
EOF
echo "  [ok] /etc/ppp/options.xl2tpd (MTU=1300, LCP=300s)"

# ============================================================
# 3. 清理旧配置 + 写 UCI
# ============================================================
echo ""
echo "===== [3] 写 UCI 网络/防火墙配置 ====="

# 清理旧的 L2TP 接口 (包括残留的同名对象)
for old in $(uci -q show network | grep "=interface" | cut -d= -f1 | sed 's/network\.//'); do
  proto=$(uci -q get network."$old".proto 2>/dev/null)
  if [ "$proto" = "l2tp" ] && [ "$old" != "$IFNAME" ]; then
    uci delete network."$old" 2>/dev/null
    echo "  [*] 清理旧 L2TP 接口: $old"
  fi
done

# 清理旧的 L2TP 路由
for rt in $(uci -q show network | grep "=route" | cut -d= -f1); do
  rt_if=$(uci -q get "$rt".interface 2>/dev/null)
  case "$rt_if" in
    l2tp-*|"$IFNAME") uci delete "$rt" 2>/dev/null ;;
  esac
done

# 写 L2TP 接口
uci -q delete network."$IFNAME" 2>/dev/null
uci set network."$IFNAME"=interface
uci set network."$IFNAME".proto=l2tp
uci set network."$IFNAME".server="$IPSEC_SERVER"
uci set network."$IFNAME".username="$L2TP_USER"
uci set network."$IFNAME".password="$L2TP_PASS"
uci set network."$IFNAME".mtu=1300
uci set network."$IFNAME".auto=1
uci set network."$IFNAME".defaultroute=0
echo "  [ok] network.$IFNAME (proto=l2tp, defaultroute=0)"

# 远端静态路由
uci -q delete network.vpn_route 2>/dev/null
uci set network.vpn_route=route
uci set network.vpn_route.interface="$IFNAME"
uci set network.vpn_route.target="${DST_SUBNET%/*}"
uci set network.vpn_route.netmask="255.255.255.0"
echo "  [ok] network.vpn_route (${DST_SUBNET%/*}/$NETMASK dev $L2TP_DEV)"

# 防火墙 — VPN zone
uci -q delete firewall.VPN 2>/dev/null
uci set firewall.VPN=zone
uci set firewall.VPN.name=VPN
uci set firewall.VPN.network="$IFNAME"
uci set firewall.VPN.input=ACCEPT
uci set firewall.VPN.output=ACCEPT
uci set firewall.VPN.forward=ACCEPT
uci set firewall.VPN.masq=1
echo "  [ok] firewall.VPN zone (masq=1)"

# 防火墙 — lan ↔ VPN 转发
for fwd in lan_to_vpn vpn_to_lan; do
  uci -q delete firewall."$fwd" 2>/dev/null
done
uci set firewall.lan_to_vpn=forwarding
uci set firewall.lan_to_vpn.src=lan
uci set firewall.lan_to_vpn.dest=VPN
uci set firewall.vpn_to_lan=forwarding
uci set firewall.vpn_to_lan.src=VPN
uci set firewall.vpn_to_lan.dest=lan
echo "  [ok] lan ↔ VPN forwarding"

uci commit network
uci commit firewall
/etc/init.d/network reload 2>/dev/null
/etc/init.d/firewall reload 2>/dev/null

# ============================================================
# 4. 修复默认路由 (旁路设备用 br-lan 当 WAN)
# ============================================================
fix_default_route() {
  local lan_if="br-lan"
  # 删掉 L2TP 抢走的默认路由
  ip route del default dev "$L2TP_DEV" 2>/dev/null
  # 确保默认路由在主路由
  if ! ip route show default 2>/dev/null | grep -q "dev $lan_if"; then
    ip route del default 2>/dev/null
    ip route add default via "$MAIN_GW" dev "$lan_if" 2>/dev/null
    echo "  [!] 默认路由已修正: via $MAIN_GW dev $lan_if"
  fi
}
fix_default_route
echo "  [ok] 默认路由: $(ip route show default)"

# ============================================================
# 5. 重启 IPsec + L2TP
# ============================================================
echo ""
echo "===== [5] 启动 IPsec ====="

/etc/init.d/ipsec stop 2>/dev/null
sleep 2
ipsec stop 2>/dev/null
sleep 1
ip xfrm state flush 2>/dev/null
ip xfrm policy flush 2>/dev/null

/etc/init.d/ipsec start 2>/dev/null
sleep 3

# 等待 IPsec 建立
echo "  [*] 等待 IPsec ESTABLISHED..."
for i in $(seq 1 15); do
  if ipsec status 2>/dev/null | grep -q ESTABLISHED; then
    echo "  [ok] IPsec ESTABLISHED"
    break
  fi
  [ $i -eq 15 ] && echo "  [FAIL] IPsec 未建立, 请检查 ipsec status"
  sleep 2
done

# ============================================================
# 6. 拉起 L2TP
# ============================================================
echo ""
echo "===== [6] 拉起 L2TP ====="

ifdown "$IFNAME" 2>/dev/null; sleep 2
ifup "$IFNAME"; sleep 8

# 等待 L2TP UP
for i in $(seq 1 10); do
  if ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
    L2TP_IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
    echo "  [ok] L2TP UP, IP: $L2TP_IP"
    break
  fi
  [ $i -eq 10 ] && echo "  [FAIL] L2TP 未 UP"
  sleep 2
done

# 再次修复默认路由 + 补静态路由
sleep 2
fix_default_route
ip route replace "${DST_SUBNET%/*}/${DST_SUBNET##*/}" dev "$L2TP_DEV" 2>/dev/null

# ============================================================
# 7. 安装 hotplug 脚本
# ============================================================
echo ""
echo "===== [7] 安装 hotplug 自修复 ====="

mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-fix-l2tp-route <<HOTPLUG
#!/bin/sh
# 旁路 L2TP 默认路由修复 (自动匹配任意 L2TP 接口)
[ "\$ACTION" = "ifup" ] || exit 0
PROTO=\$(uci -q get network."\$INTERFACE".proto 2>/dev/null)
[ "\$PROTO" = "l2tp" ] || exit 0
L2TP_DEV="l2tp-\$INTERFACE"
sleep 10
# 删掉 L2TP 抢走的默认路由
ip route del default dev "\$L2TP_DEV" 2>/dev/null
# 确保默认路由在 br-lan (主路由)
if ! ip route show default | grep -q "dev br-lan"; then
  ip route del default 2>/dev/null
  ip route add default via $MAIN_GW dev br-lan 2>/dev/null
  logger -t l2tp-fix "默认路由已修正: via $MAIN_GW dev br-lan"
fi
# 补 VPN 静态路由
for RT in \$(uci -q show network | grep "=route" | cut -d= -f1); do
  RT_IF=\$(uci -q get "\$RT".interface 2>/dev/null)
  [ "\$RT_IF" = "\$INTERFACE" ] || continue
  TARGET=\$(uci -q get "\$RT".target 2>/dev/null)
  NETMASK=\$(uci -q get "\$RT".netmask 2>/dev/null)
  [ -z "\$TARGET" ] && continue
  PREFIX=\$(echo "\$NETMASK" | awk -F. '{b=0;for(i=1;i<=4;i++){n=\$i;while(n>0){b+=n%2;n=int(n/2)}}print b}')
  ip route replace "\$TARGET/\$PREFIX" dev "\$L2TP_DEV" 2>/dev/null
done
HOTPLUG
chmod +x /etc/hotplug.d/iface/99-fix-l2tp-route
echo "  [ok] /etc/hotplug.d/iface/99-fix-l2tp-route"

# ============================================================
# 8. 验证
# ============================================================
echo ""
echo "=============================================="
echo " 验证:"
echo "  ESP SA 数: $(ip xfrm state 2>/dev/null | grep -c 'proto esp')  (>=1 即加密)"
echo "  默认路由: $(ip route show default)"
echo "  VPN 路由: $(ip route show "${DST_SUBNET%/*}/${DST_SUBNET##*/}" 2>/dev/null)"
echo "  ping $DST_TARGET: $(
  ping -c 1 -W 2 "$DST_TARGET" >/dev/null 2>&1 && echo "通" || echo "不通(可能禁ICMP, 看curl)"
)"
echo "  curl http://$DST_TARGET/: HTTP $(
  curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$DST_TARGET/" 2>/dev/null || echo "失败"
)"
echo "  外网: $(
  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && echo "通(走主路由)" || echo "不通"
)"
echo "=============================================="
echo " 完成."
echo ""
echo " 下一步: 主路由添加静态路由 10.0.0.0/24 → $MAIN_LAN_IP"
echo "=============================================="
