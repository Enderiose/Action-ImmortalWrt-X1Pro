#!/bin/sh
# ============================================================
# X1Pro L2TP/IPsec 移除脚本  (幂等)
# ------------------------------------------------------------
# 用法:   sh /root/l2tp-remove.sh [IFNAME]
#   IFNAME 可选。不指定则自动检测 (uci 中 proto=l2tp 的接口)
#   也可用 /root/l2tp-remove.conf 预填:  IFNAME=xxx
#
# 本脚本清理:
#   1. 停止 IPsec (charon/starter 进程)
#   2. 停止 L2TP 接口 (ifdown)
#   3. 删除静态路由 (network.vpn_route 或 interface=l2tp-*)
#   4. 删除防火墙 (VPN zone + lan↔VPN forwarding + Allow-IPsec/ESP rules)
#   5. 删除 network 接口
#   6. 删除 /etc/ipsec.conf /etc/ipsec.secrets
#   7. 禁用 ipsec 服务
#   8. 重启路由器 (10 秒倒计时, 可 Ctrl+C 中止)
#
# ⚠️ 若当前正通过 L2TP 访问路由器, 执行后将失去连接,
#    请先确认有其他连接方式 (局域网/公网IP/其他VPN)。
#
# 幂等: 已清理的项直接跳过, 可重复运行。
# ============================================================

CONF="/root/l2tp-remove.conf"
[ -f "$CONF" ] && . "$CONF"

IFNAME="${1:-$IFNAME}"

# 自动检测
if [ -z "$IFNAME" ]; then
  IFNAME=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)[.]proto='l2tp'$/\1/p" | head -1)
fi

if [ -z "$IFNAME" ]; then
  echo "[ERROR] 未找到 L2TP 接口 (network 中无 proto=l2tp)"
  echo "        请指定: sh $0 <IFNAME>"
  exit 1
fi

NET_DEV="l2tp-$IFNAME"
log(){ echo "  $*"; }

# ---------- 交互警告 + 确认 (仅在有终端时) ----------
if [ -t 0 ]; then
  echo "=============================================="
  echo " ⚠️  警 告"
  echo "=============================================="
  echo " 本脚本将完全移除 L2TP/IPsec 配置。"
  echo ""
  echo " 如果你当前正通过 L2TP 隧道访问此路由器，"
  echo " 执行后连接将立即断开且无法恢复。"
  echo ""
  echo " 请确认你还有其他方式连接到此路由器："
  echo "   • 局域网 (WiFi / 有线)"
  echo "   • 公网 IP / DDNS"
  echo "   • 其他 VPN 通道"
  echo ""
  echo " 目标: 移除 L2TP 接口 '$IFNAME' (dev $NET_DEV)"
  echo "=============================================="
  printf "我已确认有其他连接方式，继续移除? [输入 yes 确认]: "
  read -r ans
  case "$ans" in yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

echo "=============================================="
echo " 移除 L2TP/IPsec:"
echo "  if=$IFNAME (dev $NET_DEV)"
echo "=============================================="

# ---------- 1. 停止 IPsec ----------
echo "[1] 停止 IPsec..."
/etc/init.d/ipsec stop >/dev/null 2>&1
killall -9 charon starter 2>/dev/null
sleep 1
log "[ok] IPsec 已停止"

# ---------- 2. 停止 L2TP 接口 ----------
echo "[2] 停止 L2TP 接口..."
ifdown $IFNAME >/dev/null 2>&1
sleep 1
log "[ok] L2TP 接口已 down"

# ---------- 3. 删除静态路由 ----------
echo "[3] 删除静态路由..."
for r in $(uci show network 2>/dev/null | sed -n 's/^network\.\([^=]*\)=route/\1/p'); do
  case "$(uci -q get network.$r.interface)" in
    l2tp-*|$IFNAME)
      uci delete network.$r
      log "[del] route $r (interface=$(uci -q get network.$r.interface))"
      ;;
  esac
done
log "[ok] 静态路由已清理"

# ---------- 4. 删除防火墙 ----------
echo "[4] 删除防火墙 (VPN zone / forwardings / rules)..."
for z in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone/\1/p'); do
  if [ "$(uci -q get firewall.$z.name)" = "VPN" ]; then
    uci delete firewall.$z
    log "[del] zone VPN ($z)"
  fi
done
for f in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=forwarding/\1/p'); do
  s=$(uci -q get firewall.$f.src); d=$(uci -q get firewall.$f.dest)
  if { [ "$s" = "lan" ] && [ "$d" = "VPN" ]; } || { [ "$s" = "VPN" ] && [ "$d" = "lan" ]; }; then
    uci delete firewall.$f
    log "[del] forwarding $f (${s}->${d})"
  fi
done
for rul in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=rule/\1/p'); do
  n=$(uci -q get firewall.$rul.name)
  case "$n" in
    Allow-IPsec|Allow-ESP)
      uci delete firewall.$rul
      log "[del] rule $rul ($n)"
      ;;
  esac
done
log "[ok] 防火墙已清理"

# ---------- 5. 删除 network 接口 ----------
echo "[5] 删除 network 接口..."
if uci -q get network.$IFNAME >/dev/null 2>&1; then
  uci delete network.$IFNAME
  log "[del] network.$IFNAME"
else
  log "[skip] network.$IFNAME 不存在"
fi

# ---------- 6. 清理 IPsec 文件 ----------
echo "[6] 清理 IPsec 运行时文件..."
rm -f /etc/ipsec.conf /etc/ipsec.secrets
log "[del] /etc/ipsec.conf /etc/ipsec.secrets"

# ---------- 7. 提交 + 重启服务 ----------
echo "[7] 提交配置并重启服务..."
uci commit network
uci commit firewall
/etc/init.d/firewall restart >/dev/null 2>&1
/etc/init.d/ipsec disable >/dev/null 2>&1
# 网络重载 (去掉 l2tp 接口)
ubus call network reload 2>/dev/null || service network reload 2>/dev/null
log "[ok] 配置已提交"

echo "=============================================="
echo " 完成. L2TP/IPsec 已完全移除。"
echo " 如需重新配置, 运行: sh /tmp/l2tp-setup.sh"
echo "=============================================="

# ---------- 8. 重启路由器 ----------
echo ""
echo "[8] 路由器将在 1 秒后重启以使清理彻底生效..."
sleep 1
sync
log "[ok] 正在重启..."
reboot
