#!/bin/sh
# 脚本：修改 OpenWrt LAN 口 IP（仅允许私有地址）

# 检查是否以 root 运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：此脚本需要 root 权限。"
    exit 1
fi

# 精确匹配私有 IP 的正则表达式（RFC 1918）
# 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
PRIVATE_IP_REGEX='^(10\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))|(172\.(1[6-9]|2[0-9]|3[0-1])\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))|(192\.168\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))$'

echo "=================================================="
echo "       OpenWrt LAN 口 IP 修改工具"
echo "=================================================="

while true; do
    printf "请输入新的内网 IP 地址（如 192.168.1.1）："
    read new_ip

    # 使用正则表达式判断是否为合法的私有 IP
    if echo "$new_ip" | grep -qE "$PRIVATE_IP_REGEX"; then
        break
    else
        echo "❌ 输入的不是合法的私有局域网 IP（10.x.x.x / 172.16-31.x.x / 192.168.x.x）。"
        echo "   请重新输入。"
    fi
done

echo "✅ 输入的 IP 地址 $new_ip 有效。"

# 获取当前 LAN 接口名称（默认为 'lan'）
LAN_IFACE="lan"
if ! uci get network.$LAN_IFACE >/dev/null 2>&1; then
    echo "警告：未找到接口 'lan'，请确认您的 LAN 接口名称。"
    exit 1
fi

# 备份当前配置（可选）
uci -q commit network && uci -q export network > "/tmp/network_backup_$(date +%Y%m%d%H%M%S).uci"

# 修改 IP 地址
uci set network.$LAN_IFACE.ipaddr="$new_ip"
uci commit network

echo "正在重启网络服务以应用新 IP..."
/etc/init.d/network restart

echo "=================================================="
echo "✅ LAN 口 IP 已成功修改为 $new_ip"
echo "请注意：如果通过 SSH 连接，您可能需要使用新 IP 重新连接。"
echo "=================================================="