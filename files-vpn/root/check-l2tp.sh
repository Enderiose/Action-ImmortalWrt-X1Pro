#!/bin/sh
# ============================================================
# X1Pro L2TP 状态检测 + 自动修复脚本 (纯 L2TP, 不检测 IPsec)
# 基于 check-vpn.sh 精简: 移除 IPsec 隧道/ESP 加密检测
# 检测项:
#   [1] 默认路由在 WAN (防止 VPN 抢走默认路由断外网)
#   [2] 远端网段路由指向 L2TP
#   [3] L2TP 接口 UP
#   [4] ping 远端目标
#   [5] curl 远端目标
#   [6] 外网连通
# 每项检测失败时自动尝试对应修复
# 用法:  sh /tmp/check-l2tp.sh [接口名] [远端目标IP] [远端网段]
#       不传接口名则自动检测第一个 L2TP 接口
#       conf 优先级: /tmp/l2tp-setup.conf 中的 DST_TARGET/DST_SUBNET
# 示例:  sh check-l2tp.sh                    # 自动检测+修复
# ============================================================

CONF="/tmp/l2tp-setup.conf"
[ -f "$CONF" ] && . "$CONF"

# --- 自动检测 L2TP 接口 ---
auto_detect_ifname() {
    uci show network 2>/dev/null \
        | sed -n "/network\./s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" \
        | head -1
}

# 接口名: CLI arg > conf > UCI 自动检测, 都无则退出
[ -n "$1" ] && IFNAME="$1"
[ -z "$IFNAME" ] && IFNAME="${IFNAME:-$(auto_detect_ifname)}"
[ -z "$IFNAME" ] && { echo "[skip] 未找到 L2TP 接口"; exit 0; }

# 远端目标 IP: CLI arg > conf > UCI, 都无则退出
[ -n "$2" ] && DST_TARGET="$2"
[ -z "$DST_TARGET" ] && DST_TARGET=$(uci -q get network.$IFNAME.dst_target 2>/dev/null)
[ -z "$DST_TARGET" ] && DST_TARGET=$(uci -q get network.vpn_route.target 2>/dev/null)
[ -z "$DST_TARGET" ] && { echo "[skip] DST_TARGET 未配置"; exit 0; }

# 远端网段: conf > CLI arg > UCI > vpn_route 推断, 都无则退出
[ -z "$DST_SUBNET" ] && [ -n "$3" ] && DST_SUBNET="$3"
[ -z "$DST_SUBNET" ] && DST_SUBNET=$(uci -q get network.$IFNAME.dst_subnet 2>/dev/null)
if [ -z "$DST_SUBNET" ]; then
    RT_TARGET=$(uci -q get network.vpn_route.target 2>/dev/null)
    RT_NETMASK=$(uci -q get network.vpn_route.netmask 2>/dev/null)
    case "$RT_NETMASK" in
        255.255.255.0) DST_SUBNET="$RT_TARGET/24" ;;
        255.255.0.0)   DST_SUBNET="$RT_TARGET/16" ;;
        255.0.0.0)     DST_SUBNET="$RT_TARGET/8"  ;;
    esac
fi
[ -z "$DST_SUBNET" ] && { echo "[skip] DST_SUBNET 未配置"; exit 0; }

NET_DEV="l2tp-$IFNAME"

# 检测 WAN (多级回退)
detect_wan() {
    # 方法1: 从默认路由
    WAN_DEV="$(ip route show default 2>/dev/null | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    WAN_GW="$(ip route show default 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
    # 方法2: 从其他路由找 via + 设备
    if [ -z "$WAN_DEV" ]; then
        WAN_DEV="$(ip route 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_DEV" ] && WAN_DEV="$(ip route 2>/dev/null | grep 'proto static' | grep -v 'dev ppp\|dev l2tp\|dev br-lan' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_DEV" ] && WAN_DEV="$(ip addr 2>/dev/null | grep -E '^[0-9]+: (eth|wan|usb|enp)' | sed 's/.*: \([^:@]*\).*/\1/' | head -1)"
    fi
    if [ -z "$WAN_GW" ]; then
        WAN_GW="$(ip route 2>/dev/null | grep "dev $WAN_DEV" | grep 'via ' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
        [ -z "$WAN_GW" ] && WAN_GW="$(ifstatus wan 2>/dev/null | sed -n 's/.*"gateway": "\([^"]*\).*/\1/p' | head -1)"
        [ -z "$WAN_GW" ] && WAN_GW="$(uci -q get network.wan.gateway 2>/dev/null)"
    fi
}
detect_wan

PASS=0
FAIL=0
FIXED=0

# check 函数: 参数1=退出码, 参数2=描述文字
check() {
    if [ "$1" -eq 0 ]; then
        echo "  [ok] $2"; PASS=$((PASS+1))
    else
        echo "  [FAIL] $2"; FAIL=$((FAIL+1))
    fi
}

die() {
    echo "  [FATAL] $1"; exit 1
}

# ============================================================
# 修复函数
# ============================================================

fix_default_route() {
    echo "  → 修复: 恢复默认路由到 WAN ..."
    ip route del default dev "$NET_DEV" 2>/dev/null
    if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
        ip route del default 2>/dev/null
        ip route add default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
        if ip route show default 2>/dev/null | grep -q "dev $WAN_DEV"; then
            FIXED=$((FIXED+1)); echo "  [fixed] 默认路由已恢复 $WAN_DEV via $WAN_GW"; return 0
        fi
    fi
    return 1
}

mask_from_prefix() {
    # 逐字节构造 32 位掩码。
    # 注意: 本机 busybox ash 的 $(()) 不支持 0x 十六进制字面量, 故全部用十进制+位移实现
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

fix_subnet_route() {
    echo "  → 修复: 添加 $DST_SUBNET dev $NET_DEV ..."
    ip route replace "$DST_SUBNET" dev "$NET_DEV" 2>/dev/null
    if ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
        uci -q delete network.vpn_route 2>/dev/null
        uci set network.vpn_route=route
        uci set network.vpn_route.interface="$IFNAME"
        uci set network.vpn_route.target="${DST_SUBNET%/*}"
        uci set network.vpn_route.netmask="$(mask_from_prefix "${DST_SUBNET#*/}")"
        uci commit network
        FIXED=$((FIXED+1)); echo "  [fixed] $DST_SUBNET dev $NET_DEV"; return 0
    fi
    return 1
}

fix_l2tp_up() {
    echo "  → 修复: 重新拉起 L2TP (ifdown/ifup) ..."
    ifdown "$IFNAME" >/dev/null 2>&1; sleep 2
    ifup "$IFNAME" >/dev/null 2>&1
    local t=0
    while [ $t -lt 30 ]; do
        ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' && break
        sleep 3; t=$((t + 3))
    done
    if ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
        IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
        FIXED=$((FIXED+1)); echo "  [fixed] L2TP UP, IP: $IP"
        fix_default_route >/dev/null 2>&1
        return 0
    fi
    return 1
}

fix_ping_target() {
    echo "  → 修复: ping $DST_TARGET ..."
    ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV" || fix_subnet_route >/dev/null 2>&1
    ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' || fix_l2tp_up
    if ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] ping $DST_TARGET 通"; return 0
    fi
    echo "  [note] ping 不通 (可能对端禁 ICMP)"
    return 1
}

fix_curl_target() {
    echo "  → 修复: curl $DST_TARGET ..."
    ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true' || fix_l2tp_up
    ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV" || fix_subnet_route >/dev/null 2>&1
    CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
    [ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
    if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then
        FIXED=$((FIXED+1)); echo "  [fixed] curl HTTP $CODE"; return 0
    fi
    return 1
}

fix_internet() {
    echo "  → 修复: 外网 ..."
    fix_default_route >/dev/null 2>&1
    if ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
        FIXED=$((FIXED+1)); echo "  [fixed] 外网已恢复"; return 0
    fi
    return 1
}

# ============================================================
# 检测 + 修复
# ============================================================
echo "=============================================="
echo " L2TP VPN 状态检测 (纯 L2TP, 不含 IPsec)"
echo "  if=$IFNAME  dev=$NET_DEV  target=$DST_TARGET"
echo "=============================================="

# [1] 默认路由在 WAN
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"
check $? "默认路由在 WAN: $(ip route show default)"
if ! ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"; then
    if fix_default_route; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else die "默认路由修复失败"; fi
fi

# [2] 远端网段路由
echo "[2] 远端网段 $DST_SUBNET 路由"
ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"
check $? "VPN 路由: $(ip route show "$DST_SUBNET" 2>/dev/null)"
if ! ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
    if fix_subnet_route; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else die "子网路由修复失败"; fi
fi

# [3] L2TP UP
echo "[3] L2TP 接口"
IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'
check $? "L2TP UP, IP: ${IP:-无}"
if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
    if fix_l2tp_up; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else die "L2TP 接口修复失败"; fi
fi

# [4] ping 远端
echo "[4] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
check $? "ping $DST_TARGET"
if ! ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
    if fix_ping_target; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [info] ping 不通 (可能对端禁 ICMP)"; fi
fi

# [5] curl 远端
echo "[5] curl $DST_TARGET"
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && [ "$CODE" != "000" ]
check $? "HTTP ${CODE:-000}"
if [ "${CODE:-000}" = "000" ]; then
    if fix_curl_target; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] curl 修复失败"; fi
fi

# [6] 外网
echo "[6] 外网"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
check $? "外网 223.5.5.5"
if ! ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
    if fix_internet; then FAIL=$((FAIL-1)); PASS=$((PASS+1)); else echo "  [WARN] 外网修复失败"; fi
fi

echo "=============================================="
echo " 结果: $PASS 通过, $FAIL 失败, $FIXED 已修复"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康" || echo " 状态: 异常 (仍有 $FAIL 项失败)"
echo "=============================================="

exit $FAIL
