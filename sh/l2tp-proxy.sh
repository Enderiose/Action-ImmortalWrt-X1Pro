#!/bin/sh
# ── L2TP 代理模式切换脚本 ──
# 用法：scp 到路由器 → chmod +x → ./l2tp-proxy.sh
# 可变配置：改下面变量

# L2TP 接口名
IFNAME="BJ"

# L2TP 服务端域名（用于自动解析 WAN 直连 IP）
SERVER_DOMAIN="x.zzcz.cc"

echo ""
echo "═════════════════════════════════"
echo "  L2TP 代理模式切换"
echo "═════════════════════════════════"
echo ""
echo "  当前模式："

CURRENT=$(uci get network.${IFNAME}.defaultroute 2>/dev/null)
if [ "$CURRENT" = "1" ]; then
    echo "  ✅ 全局代理 — 所有流量走 L2TP"
else
    echo "  ⚪ 分流模式 — 仅远端内网走 L2TP"
fi

echo ""
echo "  [1] 开启全局代理（所有流量走 L2TP）"
echo "  [2] 恢复分流模式（仅内网走 L2TP）"
echo "  [q] 退出"
echo ""
printf "  请选择 [1/2/q]: "
read CHOICE

case "$CHOICE" in
    1)
        echo ""
        echo "  ⏳ 切换中..."

        # 开全局
        uci set network.${IFNAME}.defaultroute='1'
        uci commit network

        # 确保服务端 IP 走 WAN（避免隧道套娃隧道）
        SERVER_IP=$(nslookup "$SERVER_DOMAIN" 2>/dev/null | awk '/^Address [0-9]/ {print $2; exit}')
        WAN_GW=$(ip route | grep '^default via' | awk '{print $3; exit}')
        WAN_DEV=$(ip route | grep '^default via' | awk '{print $5; exit}')

        if [ -n "$SERVER_IP" ] && [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
            ip route replace "$SERVER_IP" via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
            echo "  ✅ ${SERVER_DOMAIN} → ${SERVER_IP} 走 WAN 直连"
        fi

        # 重连
        ifdown "$IFNAME" 2>/dev/null
        sleep 1
        ifup "$IFNAME" 2>/dev/null
        sleep 3

        echo ""
        echo "  ═════════════════════════════════"
        echo "  ✅ 全局代理已开启"
        echo "     所有流量 → l2tp-${IFNAME} → ikuai 出口"
        echo "  ═════════════════════════════════"
        echo ""
        echo "  新路由表："
        ip route | head -6
        ;;

    2)
        echo ""
        echo "  ⏳ 恢复中..."

        uci set network.${IFNAME}.defaultroute='0'
        uci commit network
        ifdown "$IFNAME" 2>/dev/null
        sleep 1
        ifup "$IFNAME" 2>/dev/null
        sleep 3

        echo ""
        echo "  ═════════════════════════════════"
        echo "  ⚪ 已恢复分流模式"
        echo "     仅内网走 l2tp-${IFNAME}，其余走 WAN"
        echo "  ═════════════════════════════════"
        echo ""
        echo "  新路由表："
        ip route | head -6
        ;;

    *)
        echo "  已取消"
        exit 0
        ;;
esac
