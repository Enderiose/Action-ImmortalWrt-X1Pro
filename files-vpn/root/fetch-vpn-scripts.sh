#!/bin/sh
# ============================================================
# X1Pro VPN 脚本在线更新工具
# 从 Gitee 仓库下载最新脚本到 /root/
# 用法:  sh /root/fetch-vpn-scripts.sh
# 仓库:  https://gitee.com/vvvv/wrt-x1-pro
# ============================================================

REPO="https://gitee.com/vvvv/wrt-x1-pro/raw/master"
DEST_DIR="/root"
# 新增 change-lan-ip.sh，保持原有两个文件
FILES="change-lan-ip.sh l2tp-fixup.sh vpn-check.sh"

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
echo " X1Pro VPN 脚本更新"
echo " 仓库: gitee.com/vvvv/wrt-x1-pro"
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
  echo " 全部下载完成。建议按以下顺序执行："
  echo "  1. 修改 LAN:   sh $DEST_DIR/change-lan-ip.sh"
  echo "  2. 配置 VPN:   sh $DEST_DIR/l2tp-fixup.sh"
  echo "  3. 检修 VPN:   sh $DEST_DIR/vpn-check.sh"
else
  echo " 有 $fail 个文件下载失败, 请检查网络后重试"
  echo " (可再次运行: sh $DEST_DIR/fetch-vpn-scripts.sh)"
fi
echo "=============================================="

exit "$fail"