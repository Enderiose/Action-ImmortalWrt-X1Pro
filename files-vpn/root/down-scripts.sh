#!/bin/sh
# ============================================================
# X1Pro 脚本在线更新工具
# 从 Gitee 仓库下载最新脚本到 /root/
# 用法:  sh /root/down-scripts.sh
# 仓库:  https://gitee.com/vvvv/wrt-x1-pro
# ============================================================

REPO="https://gitee.com/vvvv/wrt-x1-pro/raw/master"
DEST_DIR="/root"
# 全部脚本列表
FILES="config-lan-ip.sh config-wifi.sh config-dns.sh config-npc.sh l2tp-setup.sh l2tp-remove.sh check-vpn.sh check-l2tp.sh config-l2tp-subnet.sh"

log(){ echo "  $*"; }

fetch_one(){
  local name="$1"
  local url="$REPO/$name"
  local dest="$DEST_DIR/$name"
  local tmp="$dest.tmp"
  log "下载 $name ..."
  local i
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 15 -m 60 -o "$tmp" "$url" 2>/dev/null; then
      # 校验: 非空 + 首行是 shebang (有效 shell 脚本)
      if [ -s "$tmp" ] && head -1 "$tmp" 2>/dev/null | grep -q '^#!'; then
        mv "$tmp" "$dest"
        chmod +x "$dest"
        log "[ok] $name -> $dest ($(wc -c < "$dest") 字节)"
        return 0
      fi
    fi
    log "  [!] 第 $i 次下载失败/校验失败, 重试..."
    sleep 2
  done
  rm -f "$tmp"
  return 1
}

echo "=============================================="
echo " X1Pro 脚本拉取"
#echo " 仓库: gitee.com/vvvv/wrt-x1-pro"
echo "=============================================="

# 网络连通性预检
if ! curl -fsSL --connect-timeout 10 -m 15 -o /dev/null "https://gitee.com" 2>/dev/null; then
  echo "[ERROR] 无法连接 gitee.com, 请检查外网连通性"
  exit 1
fi

fail=0
for f in $FILES; do
  fetch_one "$f" || fail=$((fail + 1))
done

echo "=============================================="
if [ "$fail" -eq 0 ]; then
  echo " 全部下载完成。输入对应命令即可执行："
  echo "  1. 修改 LAN:   sh $DEST_DIR/config-lan-ip.sh"
  echo "  2. 修改 DNS:   sh $DEST_DIR/config-dns.sh"
  echo "  3. 配置 VPN:   sh $DEST_DIR/l2tp-setup.sh"
  echo "  4. 检修 VPN:   sh $DEST_DIR/check-vpn.sh"
  echo "  5. 移除 VPN:   sh $DEST_DIR/l2tp-remove.sh"
  echo "  6. 配置 NPC:   sh $DEST_DIR/config-npc.sh"
  echo "  7. 检修 L2TP:  sh $DEST_DIR/check-l2tp.sh"
  echo "  8. 修改 L2TP:  sh $DEST_DIR/config-l2tp-subnet.sh"
  echo "  9. 修改 WiFi:  sh $DEST_DIR/config-wifi.sh"
else
  echo " 有 $fail 个文件下载失败, 请检查网络后重试"
  echo " (可再次运行: sh $DEST_DIR/down-scripts.sh)"
fi
echo "=============================================="

exit "$fail"