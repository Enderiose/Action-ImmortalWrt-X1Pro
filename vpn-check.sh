#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 状态检测 + 自动修复脚本
# 用法:  sh /tmp/vpn-check.sh [接口名] [远端目标IP] [远端网段]
#       不传接口名则自动检测第一个 L2TP 接口
# 示例:  sh /tmp/vpn-check.sh                     # 自动检测+修复
#        sh /tmp/vpn-check.sh 111 10.0.0.253 10.0.0.0/24
# ============================================================

# --- 加载配置 (用于修复时重建连接) ---
CONF="/tmp/l2tp-fixup.conf"
[ -f "$CONF" ] && . "$CONF"

# --- 自动检测 L2TP 接口 ---
auto_detect_ifname() {
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

# 从 UCI 读取配置
DST_TARGET="${2:-$(uci -q get network.vpn_route.target 2>/dev/null)}"
[ -z "$DST_TARGET" ] && DST_TARGET="${DST_TARGET:-10.0.0.253}"

DST_SUBNET="${3:-$(uci -q get network.vpn_route.target 2>/dev/null)/$(uci -q get network.vpn_route.netmask 2>/dev/null | sed 's/255\.255\.255\.0/24/;s/255\.255\.0\.0/16/;s/255\.0\.0\.0/8/')}"
# 简单 netmask→prefix 转换
_mask2prefix() {
    case "$1" in
        255.255.255.0) echo 24 ;; 255.255.0.0) echo 16 ;; 255.0.0.0) echo 8 ;;
        255.255.255.128) echo 25 ;; 255.255.255.192) echo 26 ;; 255.255.255.224) echo 27 ;;
        255.255.255.240) echo 28 ;; 255.255.255.248) echo 29 ;; 255.255.255.252) echo 30 ;;
        *) echo 24 ;;
    esac
}
if echo "$DST_SUBNET" | grep -q '/'; then
    : # already CIDR
else
    NM=$(uci -q get network.vpn_route.netmask 2>/dev/null)
    [ -n "$NM" ] && DST_SUBNET="$DST_SUBNET/$(_mask2prefix "$NM")"
    [ -z "$DST_SUBNET" ] && DST_SUBNET="10.0.0.0/24"
fi

NET_DEV="l2tp-$IFNAME"

# 检测 WAN 设备 & 网关 (用于修复)
WAN_DEV="$(ip route show default 2>/dev/null | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
WAN_GW="$(ip route show default dev "$WAN_DEV" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
[ -z "$WAN_GW" ] && WAN_GW="$(ip route show default 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"

PASS=0
FAIL=0
FIXED=0

check(){ [ $? -eq 0 ] && { echo "  [ok] $1"; PASS=$((PASS+1)); } || { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }; }

die(){
    echo "  [FATAL] $1 - 无法自动修复, 请手动处理"
    exit 1
}

# ============================================================
# 修复函数
# ============================================================

# fix1: 默认路由不在 WAN (L2TP 抢走了)
fix_default_route(){
    echo "  → 修复: 恢复默认路由到 WAN ..."
    ip route del default dev "$NET_DEV" 2>/dev/null
    if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
        ip route del default 2>/dev/null
        ip route add default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
        ip route show default 2>/dev/null | grep -q "dev $WAN_DEV" && { FIXED=$((FIXED+1)); echo "  [fixed] 默认路由已恢复到 $WAN_DEV via $WAN_GW"; return 0; }
    fi
    return 1
}

# fix2: 远端网段路由缺失
fix_subnet_route(){
    echo "  → 修复: 添加 $DST_SUBNET 路由 ..."
    ip route replace "$DST_SUBNET" dev "$NET_DEV" 2>/dev/null
    if ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
        # 同时写入 UCI
        uci -q delete network.vpn_route 2>/dev/null
        uci set network.vpn_route=route
        uci set network.vpn_route.interface="$IFNAME"
        uci set network.vpn_route.target="${DST_SUBNET%/*}"
        uci set network.vpn_route.netmask="$(cidr2mask "${DST_SUBNET#*/}")"
        uci commit network
        FIXED=$((FIXED+1)); echo "  [fixed] 路由已添加: $DST_SUBNET dev $NET_DEV"; return 0
    fi
    return 1
}

cidr2mask() {
    local p=$1 full=$(( 0xFFFFFFFF << (32 - p) ))
    full=$(( full & 0xFFFFFFFF ))
    printf "%d.%d.%d.%d" $(( (full >> 24) & 255 )) $(( (full >> 16) & 255 )) \
                         $(( (full >> 8) & 255 )) $(( full & 255 ))
}

# fix3/4: IPsec 重启 (含 kernel-libipsec 禁用 + ESP 重协商)
fix_ipsec(){
    echo "  → 修复: 重启 IPsec ..."
    # 确保 kernel-libipsec 已禁用
    if [ -f /etc/strongswan.d/charon/kernel-libipsec.conf ]; then
        sed -i 's/^[[:space:]]*load[[:space:]]*=[[:space:]]*yes/load = no/' \
            /etc/strongswan.d/charon/kernel-libipsec.conf
    fi
    # 确保默认路由在 WAN (IPsec 依赖)
    fix_default_route
    # 清 XFRM state 并重启
    ip xfrm state flush >/dev/null 2>&1
    /etc/init.d/ipsec stop >/dev/null 2>&1
    sleep 1
    /etc/init.d/ipsec start >/dev/null 2>&1
    # 等待 ESTABLISHED (最多 30s)
    local t=0
    while [ $t -lt 30 ]; do
        ipsec status 2>/dev/null | grep -q ESTABLISHED && break
        sleep 2; t=$((t + 2))
    done
    if ipsec status 2>/dev/null | grep -q ESTABLISHED; then
        FIXED=$((FIXED+1)); echo "  [fixed] IPsec ESTABLISHED"; return 0
    fi
    return 1
}

# fix5: L2TP 接口未 UP
fix_l2tp_up(){
    echo "  → 修复: 重新拉起 L2TP ..."
    ifdown "$IFNAME" >/dev/null 2>&1
    sleep 2
    ifup "$IFNAME" >/dev/null 2>&1
    local t=0
    while [ $t -lt 30 ]; do
        ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' && break
        sleep 3; t=$((t + 3))
    done
    if ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
        IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
        FIXED=$((FIXED+1)); echo "  [fixed] L2TP UP, IP: $IP"
        # 修复路由 (ifup 可能扰乱路由)
        fix_default_route
        return 0
    fi
    return 1
}

# fix6: ping 远端不通
fix_ping_target(){
    echo "  → 修复: 检查 ping $DST_TARGET ..."
    # 先确认路由
    if ! ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
        fix_subnet_route
    fi
    # 再确认 L2TP UP
    if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
        fix_l2tp_up
    fi
    # 再试
    if ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] ping $DST_TARGET 通"; return 0
    fi
    # ping 不通但可能对端禁 ICMP, 这是常见的, 不算致命
    echo "  [note] ping 不通但可能对端禁 ICMP, 检查 curl 验证"
    return 1
}

# fix7: curl 远端不通
fix_curl_target(){
    echo "  → 修复: 检查 curl $DST_TARGET ..."
    # 先修复 IPsec + L2TP + 路由
    if ! ipsec status 2>/dev/null | grep -q ESTABLISHED; then
        fix_ipsec
    fi
    if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
        fix_l2tp_up
    fi
    if ! ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
        fix_subnet_route
    fi
    # 重试 curl
    CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
    [ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
    if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
        FIXED=$((FIXED+1)); echo "  [fixed] curl HTTP $CODE"; return 0
    fi
    return 1
}

# fix8: 外网不通
fix_internet(){
    echo "  → 修复: 恢复外网连接 ..."
    fix_default_route
    if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] 外网已恢复"; return 0
    fi
    return 1
}

# ============================================================
# 检测
# ============================================================
echo "=============================================="
echo " L2TP/IPsec VPN 状态检测"
echo "  if=$IFNAME  dev=$NET_DEV  target=$DST_TARGET"
echo "=============================================="

# --- 1. 默认路由必须在 WAN ---
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"
RES=$?
check "默认路由在 WAN: $(ip route show default)"
[ $RES -ne 0 ] && { fix_default_route || die "默认路由修复失败"; }

# --- 2. 静态路由: 远端网段走 L2TP ---
echo "[2] 远端网段 $DST_SUBNET 路由"
ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"
RES=$?
check "VPN 路由: $(ip route show "$DST_SUBNET" 2>/dev/null)"
[ $RES -ne 0 ] && { fix_subnet_route || die "子网路由修复失败"; }

# --- 3. IPsec ESTABLISHED ---
echo "[3] IPsec 隧道"
ipsec status 2>/dev/null | grep -q ESTABLISHED
RES=$?
check "IPsec: $(ipsec status 2>/dev/null | grep ESTABLISHED | head -1 | sed 's/^[[:space:]]*//')"
[ $RES -ne 0 ] && { fix_ipsec || echo "  [WARN] IPsec 修复失败, 继续检测..."; }

# --- 4. ESP 加密 SA 数 >= 1 ---
echo "[4] ESP 加密"
ESP=$(ip xfrm state 2>/dev/null | grep -c "proto esp")
[ "$ESP" -ge 1 ]
RES=$?
check "ESP SA 数: $ESP (>=1 即加密已生效)"
[ $RES -ne 0 ] && { fix_ipsec || echo "  [WARN] ESP 修复失败, 继续检测..."; }

# --- 5. L2TP 接口 UP ---
echo "[5] L2TP 接口"
ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'
RES=$?
IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
check "L2TP UP, IP: $IP"
[ $RES -ne 0 ] && { fix_l2tp_up || die "L2TP 接口修复失败"; }

# --- 6. ping 远端目标 ---
echo "[6] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
RES=$?
check "ping $DST_TARGET 通 (不通可能对端禁 ICMP, 看 curl 验证)"
[ $RES -ne 0 ] && { fix_ping_target || echo "  [info] ping 不通, 可能是对端禁 ICMP"; }

# --- 7. curl 远端业务 ---
echo "[7] curl $DST_TARGET"
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && [ "$CODE" != "000" ]
RES=$?
check "HTTP $CODE"
[ $RES -ne 0 ] && { fix_curl_target || echo "  [WARN] curl 修复失败, 隧道可能未通"; }

# --- 8. 外网连通 (走 WAN) ---
echo "[8] 外网"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
RES=$?
check "外网(223.5.5.5): $([ $? -eq 0 ] && echo "通(走 WAN)" || echo "不通")"
[ $RES -ne 0 ] && { fix_internet || echo "  [WARN] 外网修复失败"; }

echo "=============================================="
echo " 结果: $PASS 项通过, $FAIL 项失败, $FIXED 项已修复"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康 ✓" || echo " 状态: 异常 ✗ (仍有 $FAIL 项失败)"
echo "=============================================="

exit $FAIL
