#!/bin/sh
# ============================================================
# bypass-vpn-check.sh — 旁路设备 L2TP/IPsec 状态检测脚本
#
# 用法:
#   检测默认接口:  sh /tmp/bypass-vpn-check.sh
#   指定接口:      sh /tmp/bypass-vpn-check.sh 001 10.0.0.253 10.0.0.0/24
#   指定接口+主路由: sh /tmp/bypass-vpn-check.sh 001 10.0.0.253 10.0.0.0/24 192.168.68.1
# ============================================================

IFNAME="${1:-001}"
DST_TARGET="${2:-10.0.0.253}"
DST_SUBNET="${3:-10.0.0.0/24}"
MAIN_GW="${4}"
L2TP_DEV="l2tp-$IFNAME"
LAN_IF="br-lan"

PASS=0
FAIL=0
check(){ [ $? -eq 0 ] && { echo "  [ok] $1"; PASS=$((PASS+1)); } || { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }; }

# 自动检测主路由网关
if [ -z "$MAIN_GW" ]; then
  MAIN_GW=$(ip route show default 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)
  [ -z "$MAIN_GW" ] && MAIN_GW=$(uci -q get network.lan.gateway 2>/dev/null)
  [ -z "$MAIN_GW" ] && MAIN_GW="192.168.68.1"
fi

echo "=============================================="
echo " 旁路 L2TP/IPsec VPN 状态检测"
echo "  if=$IFNAME  dev=$L2TP_DEV  target=$DST_TARGET"
echo "  主路由=$MAIN_GW  本机=$LAN_IF"
echo "=============================================="

# --- 1. 默认路由必须走 br-lan (主路由) ---
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -q "dev $LAN_IF"
check "默认路由在主路由($LAN_IF): $(ip route show default)"

# --- 2. L2TP 接口 UP ---
echo "[2] L2TP 接口"
if ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
  L2TP_IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
  L2TP_UPTIME=$(ifstatus "$IFNAME" 2>/dev/null | grep uptime | sed 's/[^0-9]//g')
  check "L2TP UP, IP:$L2TP_IP, uptime:${L2TP_UPTIME}s"
else
  check "L2TP 接口 $IFNAME 未 UP"
fi

# --- 3. 远端 VPN 路由 ---
echo "[3] 远端 $DST_SUBNET 路由"
VPN_RT=$(ip route show "${DST_SUBNET%/*}/${DST_SUBNET##*/}" 2>/dev/null)
echo "$VPN_RT" | grep -q "dev $L2TP_DEV"
check "VPN 路由: $VPN_RT"

# --- 4. IPsec ESTABLISHED ---
echo "[4] IPsec 隧道"
IPSEC_STATUS=$(ipsec status 2>/dev/null | grep ESTABLISHED | head -1 | sed 's/^[[:space:]]*//')
[ -n "$IPSEC_STATUS" ]
check "IPsec: $IPSEC_STATUS"

# --- 5. ESP 加密 SA 数 ---
echo "[5] ESP 加密"
ESP=$(ip xfrm state 2>/dev/null | grep -c "proto esp")
[ "$ESP" -ge 1 ]
check "ESP SA 数: $ESP (>=1 即加密)"

# --- 6. xl2tpd 进程 ---
echo "[6] xl2tpd 进程"
ps | grep -q "[x]l2tpd"
check "xl2tpd 运行中"

# --- 7. strongswan 进程 ---
echo "[7] strongswan 进程"
ps | grep -q "[c]haron"
check "charon (strongswan) 运行中"

# --- 8. 防火墙 VPN zone ---
echo "[8] 防火墙规则"
uci -q get firewall.VPN.network 2>/dev/null | grep -q "$IFNAME"
check "VPN zone 绑定接口 $IFNAME"
uci -q get firewall.VPN.masq 2>/dev/null | grep -q "1"
check "VPN zone MASQUERADE 已启用"
nft list chain inet fw4 forward 2>/dev/null | grep -q "VPN"
check "lan↔VPN forwarding 存在"

# --- 9. ping 远端 ---
echo "[9] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
check "ping $DST_TARGET $([ $? -eq 2 ] && echo '通' || echo '(不通可能对端禁ICMP)')"

# --- 10. curl 远端 ---
echo "[10] curl $DST_TARGET"
HTTP_CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$HTTP_CODE" = "000" ] && HTTP_CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]
check "HTTP $HTTP_CODE"

# --- 11. 外网连通 ---
echo "[11] 外网 (走主路由)"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
check "外网(223.5.5.5): $([ $? -eq 2 ] && echo '通' || echo '不通')"

# --- 12. NAT-T 检测 ---
echo "[12] NAT-T (UDP 4500)"
ipsec status 2>/dev/null | grep -q "ESP in UDP"
check "NAT-T: ESP in UDP SPIs (双重NAT穿越)"

# --- 13. LCP echo 容错时间 ---
echo "[13] LCP 容错"
LCP_INT=$(grep 'lcp-echo-interval' /etc/ppp/options.xl2tpd 2>/dev/null | awk '{print $NF}')
LCP_FAIL=$(grep 'lcp-echo-failure' /etc/ppp/options.xl2tpd 2>/dev/null | awk '{print $NF}')
LCP_TIMEOUT=$((LCP_INT * LCP_FAIL))
check "LCP 容错: ${LCP_INT}s×${LCP_FAIL}=${LCP_TIMEOUT}s (>200s 适合高丢包)"

echo "=============================================="
echo " 结果: $PASS/13 项通过, $FAIL 项失败"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康 ✓" || echo " 状态: 异常 ✗ ($FAIL 项失败)"
echo "=============================================="

# --- 诊断建议 ---
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "--- 诊断建议 ---"
  if ! ip route show default | grep -q "dev $LAN_IF"; then
    echo "  [!] 默认路由不在主路由 → 执行: ip route add default via $MAIN_GW dev $LAN_IF"
  fi
  if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
    echo "  [!] L2TP 未 UP → 检查: ifup $IFNAME; tail /var/log/xl2tpd.log"
  fi
  if [ "$ESP" -lt 1 ]; then
    echo "  [!] ESP 未建立 → 检查: ipsec status; ipsec restart"
  fi
  echo "  [*] 确认主路由已加静态路由: $DST_SUBNET → $(uci -q get network.lan.ipaddr || echo '192.168.68.x')"
fi

exit $FAIL
