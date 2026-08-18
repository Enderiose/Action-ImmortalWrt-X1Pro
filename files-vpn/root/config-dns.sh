#!/bin/sh
# ============================================================
# X1Pro DNS 服务器修改脚本
# ------------------------------------------------------------
# 交互式设置主/备 DNS, 关闭运营商 DNS 下发 (peerdns)
# 修改 network.wan/wan6.peerdns + dhcp.dnsmasq.server + noresolv
#
# 用法:  sh /root/config-dns.sh
# ============================================================

[ "$(id -u)" -ne 0 ] && { echo "错误：此脚本需要 root 权限。"; exit 1; }

# IPv4 校验正则
IP_RE='^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

echo "=============================================="
echo "       X1Pro DNS 服务器修改工具"
echo "=============================================="

# 显示当前 DNS 配置
echo "当前 DNS 配置:"
CUR_DNS=$(uci -q show dhcp.@dnsmasq[0].server 2>/dev/null)
if [ -n "$CUR_DNS" ]; then
    echo "$CUR_DNS" | sed "s/^/  /"
else
    echo "  (未设置自定义 DNS, 使用运营商下发)"
fi
echo ""

# 常用 DNS 速查
echo "常用 DNS 服务器:"
echo "  阿里 DNS:       223.5.5.5        223.6.6.6"
echo "  腾讯 DNSPod:    119.29.29.29     182.254.116.116"
echo "  Google:         8.8.8.8          8.8.4.4"
echo "  Cloudflare:     1.1.1.1          1.0.0.1"
echo "  114DNS:         114.114.114.114  114.114.115.115"
echo "=============================================="

# ---------- 输入主 DNS ----------
while true; do
    printf "请输入主 DNS (必填): "
    read -r DNS1
    if echo "$DNS1" | grep -qE "$IP_RE"; then
        break
    else
        echo "❌ 不是有效的 IPv4 地址, 请重新输入。"
    fi
done

# ---------- 输入备 DNS (可选) ----------
DNS2=""
printf "请输入备 DNS (可选, 留空跳过): "
read -r DNS2
if [ -n "$DNS2" ]; then
    if ! echo "$DNS2" | grep -qE "$IP_RE"; then
        echo "⚠️  备 DNS 格式无效, 已忽略"
        DNS2=""
    fi
fi

echo "✅ 主 DNS: $DNS1"
[ -n "$DNS2" ] && echo "✅ 备 DNS: $DNS2"

# ---------- 确认 ----------
echo "=============================================="
echo " 即将应用:"
echo "  主 DNS: $DNS1"
[ -n "$DNS2" ] && echo "  备 DNS: $DNS2"
echo "  peerdns: 关闭 (不使用运营商下发 DNS)"
echo "  noresolv: 开启 (仅使用配置的 DNS)"
echo "=============================================="
printf "确认修改? [y/N]: "
read -r ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
esac

# ---------- 备份当前配置 ----------
uci -q commit dhcp
uci -q commit network
uci -q export dhcp > "/tmp/dhcp_backup_$(date +%Y%m%d%H%M%S).uci"

# ---------- 1. 关闭 peerdns (WAN/WAN6 不接受运营商 DNS) ----------
uci set network.wan.peerdns='0'
# wan6 可能不存在, 用 -q 静默
uci -q set network.wan6.peerdns='0'

# ---------- 2. 清除旧 DNS, 写入新 DNS ----------
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="$DNS1"
[ -n "$DNS2" ] && uci add_list dhcp.@dnsmasq[0].server="$DNS2"

# ---------- 3. 不读 /etc/resolv.conf, 只用配置的 DNS ----------
uci set dhcp.@dnsmasq[0].noresolv='1'

uci commit network
uci commit dhcp

echo "正在重启 dnsmasq..."
/etc/init.d/dnsmasq restart 2>/dev/null

# ---------- 验证 ----------
echo "=============================================="
echo "✅ DNS 已更新"
echo "  dnsmasq DNS 服务器:"
NEW_DNS=$(uci -q show dhcp.@dnsmasq[0].server 2>/dev/null)
if [ -n "$NEW_DNS" ]; then
    echo "$NEW_DNS" | sed "s/dhcp\.@dnsmasq\[0\]\.server='//" | sed "s/'$//" | sed "s/^/    /"
fi
echo "  peerdns (wan): $(uci -q get network.wan.peerdns 2>/dev/null || echo 未设置)"
echo "  noresolv: $(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"
echo "=============================================="
