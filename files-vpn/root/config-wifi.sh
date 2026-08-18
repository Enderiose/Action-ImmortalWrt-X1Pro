#!/bin/sh
# ============================================================
# X1Pro WiFi 配置修改脚本
# ------------------------------------------------------------
# 交互式设置 2.4G / 5G SSID 和共享密码
# 自动检测 WiFi 接口 (按 wifi-device.band 识别), 兼容 mtwifi 驱动
# 信道自动设置为 auto (让驱动自动选择最优信道)
#
# 用法:  sh /root/config-wifi.sh
# ============================================================

[ "$(id -u)" -ne 0 ] && { echo "错误：此脚本需要 root 权限。"; exit 1; }

echo "=============================================="
echo "       X1Pro WiFi 配置修改工具"
echo "=============================================="

# ---------- 自动检测 WiFi 接口 (按 band) ----------
# 遍历所有 wifi-iface, 通过其 device 的 band 字段区分 2.4G / 5G
WIFI_2G_IFACE=""
WIFI_5G_IFACE=""
for sec in $(uci show wireless 2>/dev/null | grep '=wifi-iface$' | sed 's/^wireless\.\([^=]*\)=.*/\1/'); do
    dev=$(uci -q get wireless.$sec.device)
    [ -z "$dev" ] && continue
    band=$(uci -q get wireless.$dev.band 2>/dev/null)
    case "$band" in
        2g) [ -z "$WIFI_2G_IFACE" ] && WIFI_2G_IFACE="$sec" ;;
        5g) [ -z "$WIFI_5G_IFACE" ] && WIFI_5G_IFACE="$sec" ;;
    esac
done

if [ -z "$WIFI_2G_IFACE" ] && [ -z "$WIFI_5G_IFACE" ]; then
    echo "[ERROR] 未检测到任何 WiFi 接口"
    exit 1
fi

# 显示当前配置
echo "当前 WiFi 配置:"
if [ -n "$WIFI_2G_IFACE" ]; then
    echo "  2.4G: SSID=$(uci -q get wireless.$WIFI_2G_IFACE.ssid)  加密=$(uci -q get wireless.$WIFI_2G_IFACE.encryption)"
fi
if [ -n "$WIFI_5G_IFACE" ]; then
    echo "  5G:   SSID=$(uci -q get wireless.$WIFI_5G_IFACE.ssid)  加密=$(uci -q get wireless.$WIFI_5G_IFACE.encryption)"
fi
echo "=============================================="

# ---------- 输入新 SSID ----------
if [ -n "$WIFI_2G_IFACE" ]; then
    printf "请输入 2.4G WiFi 名称 (SSID): "
    read -r SSID_2G
    if [ -z "$SSID_2G" ]; then
        echo "[ERROR] SSID 不能为空"
        exit 1
    fi
fi

if [ -n "$WIFI_5G_IFACE" ]; then
    printf "请输入 5G WiFi 名称 (SSID): "
    read -r SSID_5G
    if [ -z "$SSID_5G" ]; then
        echo "[ERROR] SSID 不能为空"
        exit 1
    fi
fi

# ---------- 输入密码 ----------
printf "请输入 WiFi 密码 (8-63位, 留空则不加密): "
read -r WIFI_KEY

if [ -n "$WIFI_KEY" ]; then
    KEY_LEN=${#WIFI_KEY}
    if [ "$KEY_LEN" -lt 8 ] || [ "$KEY_LEN" -gt 63 ]; then
        echo "[ERROR] 密码长度需 8-63 位, 当前 $KEY_LEN 位"
        exit 1
    fi
    ENCRYPTION="psk2"
    echo "✅ 密码有效, 加密方式: WPA2-PSK"
else
    ENCRYPTION="none"
    echo "⚠️  未设密码, WiFi 将为开放网络"
fi

# ---------- 确认 ----------
echo "=============================================="
echo " 即将应用以下配置:"
if [ -n "$WIFI_2G_IFACE" ]; then
    echo "  2.4G: $SSID_2G ($ENCRYPTION, 信道: auto)"
fi
if [ -n "$WIFI_5G_IFACE" ]; then
    echo "  5G:   $SSID_5G ($ENCRYPTION, 信道: auto)"
fi
echo "=============================================="
printf "确认修改? [y/N]: "
read -r ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
esac

# ---------- 备份当前配置 ----------
uci -q commit wireless
uci -q export wireless > "/tmp/wireless_backup_$(date +%Y%m%d%H%M%S).uci"

# ---------- 应用 2.4G ----------
if [ -n "$WIFI_2G_IFACE" ]; then
    uci set wireless.$WIFI_2G_IFACE.ssid="$SSID_2G"
    uci set wireless.$WIFI_2G_IFACE.encryption="$ENCRYPTION"
    if [ "$ENCRYPTION" = "psk2" ]; then
        uci set wireless.$WIFI_2G_IFACE.key="$WIFI_KEY"
    else
        uci -q delete wireless.$WIFI_2G_IFACE.key
    fi
    # 取消禁用 (如有 disabled=1)
    DEV_2G=$(uci -q get wireless.$WIFI_2G_IFACE.device)
    [ -n "$DEV_2G" ] && uci -q delete wireless.$DEV_2G.disabled
    # 信道设为 auto (自动选择最优信道)
    [ -n "$DEV_2G" ] && uci set wireless.$DEV_2G.channel='auto'
    echo "[ok] 2.4G → $SSID_2G (信道: auto)"
fi

# ---------- 应用 5G ----------
if [ -n "$WIFI_5G_IFACE" ]; then
    uci set wireless.$WIFI_5G_IFACE.ssid="$SSID_5G"
    uci set wireless.$WIFI_5G_IFACE.encryption="$ENCRYPTION"
    if [ "$ENCRYPTION" = "psk2" ]; then
        uci set wireless.$WIFI_5G_IFACE.key="$WIFI_KEY"
    else
        uci -q delete wireless.$WIFI_5G_IFACE.key
    fi
    DEV_5G=$(uci -q get wireless.$WIFI_5G_IFACE.device)
    [ -n "$DEV_5G" ] && uci -q delete wireless.$DEV_5G.disabled
    # 信道设为 auto (自动选择最优信道)
    [ -n "$DEV_5G" ] && uci set wireless.$DEV_5G.channel='auto'
    echo "[ok] 5G → $SSID_5G (信道: auto)"
fi

uci commit wireless

echo "正在重载 WiFi..."
wifi reload 2>/dev/null

echo "=============================================="
echo "✅ WiFi 配置已更新"
if [ -n "$WIFI_2G_IFACE" ]; then
    echo "  2.4G: $SSID_2G ($ENCRYPTION, 信道: auto)"
fi
if [ -n "$WIFI_5G_IFACE" ]; then
    echo "  5G:   $SSID_5G ($ENCRYPTION, 信道: auto)"
fi
echo "⚠️  如通过 WiFi 连接 SSH, 请用新 SSID/密码重连"
echo "=============================================="
