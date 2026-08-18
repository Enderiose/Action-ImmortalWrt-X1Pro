#!/bin/sh
# ============================================================
# X1Pro L2TP 远端网段 / 验证IP 修改脚本
# ------------------------------------------------------------
# 修改 network.<if>.dst_subnet / dst_target + 静态路由
# IPsec 不受影响 (transport 模式, 仅加密 1701, 与网段无关)
#
# 用法:  sh /root/config-l2tp-subnet.sh [IFNAME] [新网段] [新验证IP]
#   例:  sh /root/config-l2tp-subnet.sh 123 10.0.0.0/24 10.0.0.253
#   例:  sh /root/config-l2tp-subnet.sh            # 交互输入
#
# 配套脚本 (l2tp-setup.sh 等) 统一由 down-scripts.sh 一次性拉取, 本脚本不再自行下载。
# ============================================================

# ---------- 自动检测 L2TP 接口 ----------
auto_detect(){
  uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" | head -1
}
IFNAME="${1:-$(auto_detect)}"
[ -z "$IFNAME" ] && { echo "[ERROR] 未找到 L2TP 接口 (network 中无 proto=l2tp)"; exit 1; }

NET_DEV="l2tp-$IFNAME"
log(){ echo "  $*"; }

# ---------- 获取新网段 / 验证IP ----------
if [ -z "$2" ]; then
  printf "新远端网段 (如 10.0.0.0/24): "; read -r DST_SUBNET
else
  DST_SUBNET="$2"
fi
if [ -z "$3" ]; then
  printf "新验证IP (测试连通): "; read -r DST_TARGET
else
  DST_TARGET="$3"
fi
[ -z "$DST_SUBNET" ] && { echo "[ERROR] 网段不能为空"; exit 1; }
[ -z "$DST_TARGET" ] && { echo "[ERROR] 验证IP不能为空"; exit 1; }

# CIDR → target / netmask
NET_TARGET="${DST_SUBNET%/*}"
NET_PREFIX="${DST_SUBNET#*/}"
[ -z "$NET_PREFIX" ] && NET_PREFIX=24
mask_from_prefix(){
  # 逐字节构造 32 位掩码, 避免 shell 32 位算术对 0xFFFFFFFF<<N 的溢出(原实现 p=24 算成 0.0.0.0)
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
NET_MASK="$(mask_from_prefix "$NET_PREFIX")"

# 交互确认 (仅有终端时)
if [ -t 0 ]; then
  echo "=============================================="
  echo " 将修改 L2TP 远端配置:"
  echo "  if=$IFNAME  dev=$NET_DEV"
  echo "  subnet=$DST_SUBNET  target=$DST_TARGET"
  echo "=============================================="
  printf "确认修改? [y/N]: "; read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

echo "=============================================="
echo " 修改 L2TP 远端配置:"
echo "  if=$IFNAME  dev=$NET_DEV"
echo "  subnet=$DST_SUBNET  target=$DST_TARGET"
echo "=============================================="

# 捕获旧网段 (用于清理旧路由)
OLD_SUBNET=$(uci -q get network.$IFNAME.dst_subnet)

# 1. 更新 UCI (持久化)
uci set network.$IFNAME.dst_subnet="$DST_SUBNET"
uci set network.$IFNAME.dst_target="$DST_TARGET"
uci set network.vpn_route=route
uci set network.vpn_route.interface="$IFNAME"
uci set network.vpn_route.target="$NET_TARGET"
uci set network.vpn_route.netmask="$NET_MASK"
uci commit network
log "[ok] UCI 已更新 (dst_subnet/dst_target/vpn_route)"

# 2. 修复内核路由: 删旧网段路由 + 加新网段路由
if [ -n "$OLD_SUBNET" ] && [ "$OLD_SUBNET" != "$DST_SUBNET" ]; then
  ip route del "$OLD_SUBNET" dev "$NET_DEV" 2>/dev/null \
    && log "[ok] 已删除旧路由: $OLD_SUBNET dev $NET_DEV" \
    || log "[!] 旧路由 $OLD_SUBNET 不存在或已清理"
fi
ip route replace "$DST_SUBNET" dev "$NET_DEV"
log "[ok] 内核路由已更新: $DST_SUBNET dev $NET_DEV"

# 3. 验证
echo "=============================================="
echo " 验证:"
echo "  VPN 路由: $(ip route show $DST_SUBNET)"
echo "  默认路由: $(ip route show default)"
if ping -c 3 -W 2 "$DST_TARGET" >/dev/null 2>&1; then
  echo "  ping $DST_TARGET: 通"
else
  echo "  ping $DST_TARGET: 不通 (对端常禁 ICMP, 看 curl)"
fi
CODE=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://$DST_TARGET/" 2>/dev/null)
[ -n "$CODE" ] && echo "  curl http://$DST_TARGET/ -> HTTP $CODE"
echo "=============================================="
echo " 完成. 新网段 $DST_SUBNET 走 $NET_DEV"
