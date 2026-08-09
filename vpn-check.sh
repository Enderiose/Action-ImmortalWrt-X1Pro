#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 状态检测脚本
# 用法:  sh /tmp/vpn-check.sh [接口名] [远端目标IP] [远端网段]
#       不传接口名则自动检测第一个 L2TP 接口
# 示例:  sh /tmp/vpn-check.sh 111 10.0.0.253 10.0.0.0/24
#        sh /tmp/vpn-check.sh               # 自动检测
# ============================================================

# --- 自动检测 L2TP 接口 ---
auto_detect_ifname() {
    # 从 /etc/config/network 中找 l2tp 类型的接口名
    # 排除注释行，找 option proto 'l2tp' 的上一个 config interface 'xxx' 行
    uci show network 2>/dev/null \
        | sed -n "/network\./s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" \
        | head -1
}

if [ -n "$1" ]; then
    IFNAME="$1"
else
    IFNAME=$(auto_detect_ifname)
    if [ -z "$IFNAME" ]; then
        echo "错误: 未找到 L2TP 接口, 请手动指定接口名"
        echo "用法: $0 <接口名> [远端IP] [远端网段]"
        exit 1
    fi
    echo "自动检测到 L2TP 接口: $IFNAME"
fi

DST_TARGET="${2:-10.0.0.253}"
DST_SUBNET="${3:-10.0.0.0/24}"
NET_DEV="l2tp-$IFNAME"

PASS=0
FAIL=0
check(){ [ $? -eq 0 ] && { echo "  [ok] $1"; PASS=$((PASS+1)); } || { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }; }

echo "=============================================="
echo " L2TP/IPsec VPN 状态检测"
echo "  if=$IFNAME  dev=$NET_DEV  target=$DST_TARGET"
echo "=============================================="

# --- 1. 默认路由必须在 WAN ---
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"
check "默认路由在 WAN: $(ip route show default)"

# --- 2. 静态路由: 远端网段走 L2TP ---
echo "[2] 远端网段 $DST_SUBNET 路由"
ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"
check "VPN 路由: $(ip route show "$DST_SUBNET" 2>/dev/null)"

# --- 3. IPsec ESTABLISHED ---
echo "[3] IPsec 隧道"
ipsec status 2>/dev/null | grep -q ESTABLISHED
check "IPsec: $(ipsec status 2>/dev/null | grep ESTABLISHED | head -1 | sed 's/^[[:space:]]*//')"

# --- 4. ESP 加密 SA 数 >= 1 ---
echo "[4] ESP 加密"
ESP=$(ip xfrm state 2>/dev/null | grep -c "proto esp")
[ "$ESP" -ge 1 ]
check "ESP SA 数: $ESP (>=1 即加密已生效)"

# --- 5. L2TP 接口 UP ---
echo "[5] L2TP 接口"
ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'
IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
check "L2TP UP, IP: $IP"

# --- 6. ping 远端目标 ---
echo "[6] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
check "ping $DST_TARGET 通 (不通可能对端禁 ICMP, 看 curl 验证)"

# --- 7. curl 远端业务 ---
echo "[7] curl $DST_TARGET"
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && [ "$CODE" != "000" ]
check "HTTP $CODE"

# --- 8. 外网连通 (走 WAN) ---
echo "[8] 外网"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
check "外网(223.5.5.5): $([ $? -eq 0 ] && echo "通(走 WAN)" || echo "不通")"

echo "=============================================="
echo " 结果: $PASS 项通过, $FAIL 项失败"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康 ✓" || echo " 状态: 异常 ✗"
echo "=============================================="

exit $FAIL
