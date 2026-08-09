#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 状态检测 + 自动修复脚本
# 用法:  sh /tmp/vpn-check.sh [接口名] [远端目标IP] [远端网段]
#       不传接口名则自动检测第一个 L2TP 接口
#       conf 优先级: /tmp/l2tp-fixup.conf 中的 DST_TARGET/DST_SUBNET
# 示例:  sh vpn-check.sh                     # 自动检测+修复
#        sh vpn-check.sh 001 10.0.0.253 10.0.0.0/24
# ============================================================

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
    [ -z "$IFNAME" ] && { echo "错误: 未找到 L2TP 接口"; echo "用法: $0 <接口名> [远端IP] [远端网段]"; exit 1; }
    echo "自动检测到 L2TP 接口: $IFNAME"
fi

# 远端目标 IP: 参数2 > conf DST_TARGET > 默认
DST_TARGET="${2:-${DST_TARGET:-10.0.0.253}}"

# 远端网段: conf DST_SUBNET > 参数3 > UCI > 默认
if [ -n "$DST_SUBNET" ]; then
    :  # conf 已有
elif [ -n "$3" ]; then
    DST_SUBNET="$3"
else
    RT_TARGET=$(uci -q get network.vpn_route.target 2>/dev/null)
    RT_NETMASK=$(uci -q get network.vpn_route.netmask 2>/dev/null)
    case "$RT_NETMASK" in
        255.255.255.0) DST_SUBNET="$RT_TARGET/24" ;;
        255.255.0.0)   DST_SUBNET="$RT_TARGET/16" ;;
        255.0.0.0)     DST_SUBNET="$RT_TARGET/8"  ;;
        "")            DST_SUBNET="10.0.0.0/24" ;;
        *)             DST_SUBNET="$RT_TARGET/24" ;;
    esac
fi

NET_DEV="l2tp-$IFNAME"

# 检测 WAN
WAN_DEV="$(ip route show default 2>/dev/null | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
WAN_GW="$(ip route show default dev "$WAN_DEV" 2>/dev/null | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"
[ -z "$WAN_GW" ] && WAN_GW="$(ip route show default 2>/dev/null | grep 'via ' | grep -v 'dev ppp\|dev l2tp' | sed -n 's/.*via \([^ ]*\).*/\1/p' | head -1)"

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
    local p=$1 full=$(( 0xFFFFFFFF << (32 - p) ))
    full=$(( full & 0xFFFFFFFF ))
    printf "%d.%d.%d.%d" $(( (full >> 24) & 255 )) $(( (full >> 16) & 255 )) \
                         $(( (full >> 8) & 255 )) $(( full & 255 ))
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

fix_ipsec() {
    echo "  → 修复: 重启 IPsec ..."
    [ -f /etc/strongswan.d/charon/kernel-libipsec.conf ] && \
        sed -i 's/^[[:space:]]*load[[:space:]]*=[[:space:]]*yes/load = no/' \
            /etc/strongswan.d/charon/kernel-libipsec.conf
    fix_default_route >/dev/null 2>&1
    ip xfrm state flush >/dev/null 2>&1
    /etc/init.d/ipsec stop >/dev/null 2>&1
    sleep 1
    /etc/init.d/ipsec start >/dev/null 2>&1
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
    ipsec status 2>/dev/null | grep -q ESTABLISHED || fix_ipsec
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
echo " L2TP/IPsec VPN 状态检测"
echo "  if=$IFNAME  dev=$NET_DEV  target=$DST_TARGET"
echo "=============================================="

# [1] 默认路由在 WAN
echo "[1] 默认路由"
ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"
check $? "默认路由在 WAN: $(ip route show default)"
if ! ip route show default 2>/dev/null | grep -v "dev $NET_DEV" | grep -q "default"; then
    fix_default_route || die "默认路由修复失败"
fi

# [2] 远端网段路由
echo "[2] 远端网段 $DST_SUBNET 路由"
ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"
check $? "VPN 路由: $(ip route show "$DST_SUBNET" 2>/dev/null)"
if ! ip route show "$DST_SUBNET" 2>/dev/null | grep -q "dev $NET_DEV"; then
    fix_subnet_route || die "子网路由修复失败"
fi

# [3] IPsec ESTABLISHED
echo "[3] IPsec 隧道"
ipsec status 2>/dev/null | grep -q ESTABLISHED
check $? "IPsec: $(ipsec status 2>/dev/null | grep ESTABLISHED | head -1 | sed 's/^[[:space:]]*//')"
if ! ipsec status 2>/dev/null | grep -q ESTABLISHED; then
    fix_ipsec || echo "  [WARN] IPsec 修复失败"
fi

# [4] ESP 加密
echo "[4] ESP 加密"
ESP=$(ip xfrm state 2>/dev/null | grep -c "proto esp")
[ "$ESP" -ge 1 ]
check $? "ESP SA 数: $ESP"
if [ "$ESP" -lt 1 ]; then
    fix_ipsec || echo "  [WARN] ESP 修复失败"
fi

# [5] L2TP UP
echo "[5] L2TP 接口"
IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'
check $? "L2TP UP, IP: ${IP:-无}"
if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
    fix_l2tp_up || die "L2TP 接口修复失败"
fi

# [6] ping 远端
echo "[6] ping $DST_TARGET"
ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1
check $? "ping $DST_TARGET"
if ! ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
    fix_ping_target || echo "  [info] ping 不通 (可能对端禁 ICMP)"
fi

# [7] curl 远端
echo "[7] curl $DST_TARGET"
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ "$CODE" = "000" ] && CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "https://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && [ "$CODE" != "000" ]
check $? "HTTP ${CODE:-000}"
if [ "${CODE:-000}" = "000" ]; then
    fix_curl_target || echo "  [WARN] curl 修复失败"
fi

# [8] 外网
echo "[8] 外网"
ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1
check $? "外网 223.5.5.5"
if ! ping -c 2 -W 2 223.5.5.5 >/dev/null 2>&1; then
    fix_internet || echo "  [WARN] 外网修复失败"
fi

echo "=============================================="
echo " 结果: $PASS 通过, $FAIL 失败, $FIXED 已修复"
[ "$FAIL" -eq 0 ] && echo " 状态: 健康" || echo " 状态: 异常 (仍有 $FAIL 项失败)"
echo "=============================================="

exit $FAIL
