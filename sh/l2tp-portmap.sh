#!/bin/sh
# ============================================================
# X1Pro L2TP 端口映射脚本 (幂等)
# ------------------------------------------------------------
# 用途: 把 L2TP 隧道进来的流量 DNAT 到下级设备
# 用法: sh /tmp/l2tp-portmap.sh
# 配置: /tmp/l2tp-portmap.conf (可选, 预填变量)
#       支持的变量:
#         IFNAME   - L2TP 接口名 (默认从 l2tp-fixup.conf 读取)
#         TARGET   - 下级设备 IP
#         PORTS    - 端口映射列表, 空格分隔
#                    格式: 单端口 "80" = 隧道:80 → 下级:80
#                         映射  "8080:80" = 隧道:8080 → 下级:80
#                         范围  "8000-8100"
# ============================================================

CONF="/tmp/l2tp-portmap.conf"
[ -f "$CONF" ] && . "$CONF"

# 从 l2tp-fixup.conf 读取接口名
FIXUP_CONF="/tmp/l2tp-fixup.conf"
if [ -z "$IFNAME" ] && [ -f "$FIXUP_CONF" ]; then
  IFNAME=$(awk -F= '/^IFNAME=/{print $2}' "$FIXUP_CONF")
fi

# ── 交互输入 ──
[ -n "$TARGET" ] || read -p "下级设备 IP: " TARGET
[ -z "$TARGET" ] && { echo "[ERROR] 目标 IP 不能为空"; exit 1; }

[ -n "$PORTS" ] || read -p "端口映射 (如 80 或 8080:80 或 8000-8100, 空格分隔多个): " PORTS
[ -z "$PORTS" ] && { echo "[ERROR] 端口不能为空"; exit 1; }

NET_DEV="l2tp-$IFNAME"

echo ""
echo "=============================================="
echo " L2TP 端口映射"
echo "  隧道: $NET_DEV → 目标: $TARGET"
echo "  端口: $PORTS"
echo "=============================================="

# ── 1. 检查 L2TP 是否 UP ──
if ! ifstatus "$IFNAME" 2>/dev/null | grep -q '"up": true'; then
  echo "[!] L2TP 接口 $IFNAME 未 UP, 请先运行 l2tp-fixup.sh"
  exit 1
fi
echo "[ok] L2TP 接口 $IFNAME 已 UP"

# ── 2. 确保 ipset 可用 (幂等删旧 set) ──
IPSET_NAME="l2tp_dnat_$IFNAME"
ipset destroy "$IPSET_NAME" 2>/dev/null
ipset create "$IPSET_NAME" hash:ip -exist
echo "[ok] ipset $IPSET_NAME 已就绪"

# ── 3. 获取 L2TP 本地 IP, 加入 ipset ──
L2TP_IP=$(ifstatus "$IFNAME" 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
if [ -n "$L2TP_IP" ]; then
  ipset flush "$IPSET_NAME" 2>/dev/null
  ipset add "$IPSET_NAME" "$L2TP_IP" -exist
  echo "[ok] L2TP 本地 IP: $L2TP_IP → ipset"
else
  echo "[!] 未获取到 L2TP 本地 IP, 将匹配 $NET_DEV 所有入站流量"
fi

# ── 4. 清理旧 DNAT 规则 (幂等) ──
iptables -t nat -F L2TP_PORTMAP 2>/dev/null
iptables -t nat -D PREROUTING -j L2TP_PORTMAP 2>/dev/null
iptables -t nat -X L2TP_PORTMAP 2>/dev/null
iptables -t nat -N L2TP_PORTMAP

# ── 5. 添加 DNAT 规则 ──
for entry in $PORTS; do
  case "$entry" in
    *:*)
      # 映射端口: 隧道端口:下级端口
      src_port="${entry%%:*}"
      dst_port="${entry##*:}"
      ;;
    *-*)
      # 端口范围: start-end
      src_port="$entry"
      dst_port="$entry"
      ;;
    *)
      # 单端口: 隧道端口=下级端口
      src_port="$entry"
      dst_port="$entry"
      ;;
  esac

  if [ -n "$L2TP_IP" ]; then
    # 精确匹配 L2TP 本地 IP
    iptables -t nat -A L2TP_PORTMAP \
      -i "$NET_DEV" -d "$L2TP_IP" \
      -p tcp --dport "$src_port" \
      -j DNAT --to-destination "${TARGET}:${dst_port}"
    iptables -t nat -A L2TP_PORTMAP \
      -i "$NET_DEV" -d "$L2TP_IP" \
      -p udp --dport "$src_port" \
      -j DNAT --to-destination "${TARGET}:${dst_port}"
    echo "  [+] TCP/UDP ${NET_DEV}:${src_port} (dst ${L2TP_IP}) → ${TARGET}:${dst_port}"
  else
    # 无精确 IP, 匹配所有入站
    iptables -t nat -A L2TP_PORTMAP \
      -i "$NET_DEV" \
      -p tcp --dport "$src_port" \
      -j DNAT --to-destination "${TARGET}:${dst_port}"
    iptables -t nat -A L2TP_PORTMAP \
      -i "$NET_DEV" \
      -p udp --dport "$src_port" \
      -j DNAT --to-destination "${TARGET}:${dst_port}"
    echo "  [+] TCP/UDP ${NET_DEV}:${src_port} → ${TARGET}:${dst_port}"
  fi
done

# 挂到 PREROUTING
iptables -t nat -I PREROUTING -j L2TP_PORTMAP
echo "[ok] DNAT 规则已生效"

# ── 6. 确保 forward 链放行 (filter 表) ──
iptables -I FORWARD -i "$NET_DEV" -d "$TARGET" -j ACCEPT 2>/dev/null
iptables -I FORWARD -o "$NET_DEV" -s "$TARGET" -j ACCEPT 2>/dev/null
echo "[ok] FORWARD 链已放行 ${NET_DEV} ↔ ${TARGET}"

# ── 7. 保存到 /etc/firewall.user (重启后恢复) ──
FW_USER="/etc/firewall.user"
touch "$FW_USER"

# 移除旧的本脚本条目
sed -i '/^### l2tp-portmap ###/,/^### end l2tp-portmap ###/d' "$FW_USER"

{
  echo "### l2tp-portmap ###"
  echo "# 自动生成于 $(date)"
  echo "ipset destroy $IPSET_NAME 2>/dev/null"
  echo "ipset create $IPSET_NAME hash:ip -exist"
  echo "ipset flush $IPSET_NAME 2>/dev/null"
  echo "ipset add $IPSET_NAME $L2TP_IP -exist 2>/dev/null"
  echo "iptables -t nat -N L2TP_PORTMAP 2>/dev/null"
  for entry in $PORTS; do
    case "$entry" in
      *:*) src_port="${entry%%:*}"; dst_port="${entry##*:}" ;;
      *-*) src_port="$entry"; dst_port="$entry" ;;
      *)   src_port="$entry"; dst_port="$entry" ;;
    esac
    echo "iptables -t nat -A L2TP_PORTMAP -i $NET_DEV -p tcp --dport $src_port -j DNAT --to-destination ${TARGET}:${dst_port}"
    echo "iptables -t nat -A L2TP_PORTMAP -i $NET_DEV -p udp --dport $src_port -j DNAT --to-destination ${TARGET}:${dst_port}"
  done
  echo "iptables -t nat -I PREROUTING -j L2TP_PORTMAP"
  echo "iptables -I FORWARD -i $NET_DEV -d $TARGET -j ACCEPT"
  echo "iptables -I FORWARD -o $NET_DEV -s $TARGET -j ACCEPT"
  echo "### end l2tp-portmap ###"
} >> "$FW_USER"

echo "[ok] 已写入 $FW_USER (重启后自动恢复)"

# ── 8. 验证 ──
echo ""
echo "=============================================="
echo " 当前 DNAT 规则:"
iptables -t nat -L L2TP_PORTMAP -n --line-numbers 2>/dev/null
echo "=============================================="
echo " 测试: 从远端 ping ${TARGET} 或 curl ${L2TP_IP}:<端口>"
echo "=============================================="
