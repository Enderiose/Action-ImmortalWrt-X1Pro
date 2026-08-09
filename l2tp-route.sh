#!/bin/sh
# ============================================================
# X1Pro L2TP 下级子网路由脚本 (幂等)
# ------------------------------------------------------------
# 用途: 在 X1Pro 添加静态路由, 使 L2TP 隧道对端可访问下级子网设备
# 用法: sh /tmp/l2tp-route.sh
# 配置: /tmp/l2tp-route.conf (可选, 预填变量)
#       支持的变量:
#         SUBNET  - 下级子网 (如 192.168.123.0/24)
#         GATEWAY - 下级路由器 IP (在 X1Pro LAN 里的地址)
#         IFNAME  - L2TP 接口名 (默认从 l2tp-fixup.conf 读取)
#         VPN_IP  - X1Pro 在 L2TP 隧道的 IP (自动检测)
# ============================================================

CONF="/tmp/l2tp-route.conf"
[ -f "$CONF" ] && . "$CONF"

# 从 l2tp-fixup.conf 读取 L2TP 接口名
FIXUP_CONF="/tmp/l2tp-fixup.conf"
if [ -z "$IFNAME" ] && [ -f "$FIXUP_CONF" ]; then
  IFNAME=$(awk -F= '/^IFNAME=/{print $2}' "$FIXUP_CONF")
fi

# ── 交互输入 ──
[ -n "$SUBNET" ]  || read -p "下级子网 (如 192.168.123.0/24): " SUBNET
[ -z "$SUBNET" ]  && { echo "[ERROR] 子网不能为空"; exit 1; }

[ -n "$GATEWAY" ] || read -p "下级路由器在 X1Pro LAN 的 IP: " GATEWAY
[ -z "$GATEWAY" ] && { echo "[ERROR] 网关不能为空"; exit 1; }

NET_DEV="l2tp-$IFNAME"

echo ""
echo "=============================================="
echo " L2TP 下级子网路由"
echo "  隧道: $NET_DEV   下级子网: $SUBNET"
echo "  下级网关: $GATEWAY"
echo "=============================================="

# ── 1. 检查 L2TP 是否 UP ──
if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
  echo "[!] L2TP 接口 $IFNAME 未 UP, 请先运行 l2tp-fixup.sh"
  exit 1
fi
echo "[ok] L2TP 接口 $IFNAME 已 UP"

# ── 2. 添加 X1Pro 本机静态路由: 下级子网 → 下级路由器 ──
echo "[2] X1Pro 静态路由: $SUBNET via $GATEWAY"
if ip route replace "$SUBNET" via "$GATEWAY"; then
  echo "  [ok] $(ip route show "$SUBNET")"
else
  echo "  [FAIL] 添加失败"
fi

# 持久化到 UCI (重启保持)
ROUTE_NAME="l2tp_subnet_${IFNAME}"
uci set network.$ROUTE_NAME=route
uci set network.$ROUTE_NAME.target="$SUBNET"
uci set network.$ROUTE_NAME.gateway="$GATEWAY"
uci commit network
echo "  [ok] 已写入 /etc/config/network (重启后保持)"

# ── 3. 确保 l2tp-001 → LAN 的转发已放行 ──
L2TP_ZONE=$(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)\.network=.*'"$IFNAME"'.*/\1/p' | head -1)
if [ -n "$L2TP_ZONE" ]; then
  # 如果已有 VPN zone 且 forward=ACCEPT, 就够用了
  FWD=$(uci -q get firewall.$L2TP_ZONE.forward)
  [ "$FWD" != "ACCEPT" ] && uci set firewall.$L2TP_ZONE.forward='ACCEPT'

  # lan → VPN 转发
  HAS_FWD=$(uci show firewall 2>/dev/null | grep "firewall.lan_to_vpn.src='lan'" | head -1)
  [ -z "$HAS_FWD" ] && {
    uci set firewall.lan_to_vpn=forwarding
    uci set firewall.lan_to_vpn.src='lan'
    uci set firewall.lan_to_vpn.dest="$L2TP_ZONE"
  }

  # VPN → lan 转发
  HAS_FWD2=$(uci show firewall 2>/dev/null | grep "firewall.vpn_to_lan.src='$L2TP_ZONE'" | head -1)
  [ -z "$HAS_FWD2" ] && {
    uci set firewall.vpn_to_lan=forwarding
    uci set firewall.vpn_to_lan.src="$L2TP_ZONE"
    uci set firewall.vpn_to_lan.dest='lan'
  }

  uci commit firewall
  /etc/init.d/firewall restart >/dev/null 2>&1
  echo "  [ok] FORWARD 链已确认: $L2TP_ZONE ↔ lan"
else
  echo "  [!] 未找到 L2TP 接口对应的防火墙 zone, 需要 l2tp-fixup.sh 先配防火墙"
fi

# ── 4. 获取 X1Pro 的 L2TP IP (给远程 ikuai 加路由用) ──
VPN_IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
echo ""
echo "=============================================="
echo " X1Pro 本机路由已完成"
echo "=============================================="
echo ""
echo " ⚠️  远程 ikuai (10.0.0.253) 还需要添加一条静态路由:"
echo ""
echo "     目的: $SUBNET"
echo "     网关: $VPN_IP  (X1Pro 的 L2TP 地址)"
echo ""
echo "   才能在远端直接访问 $SUBNET 内的设备"
echo ""
echo "   刷入此命令到远程路由器:"
echo "   ip route add $SUBNET via $VPN_IP"
echo "=============================================="
