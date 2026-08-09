#!/bin/bash
# ============================================================
# 部署 hotplug 脚本到 X1Pro (在线更新, 无需刷机)
# 用法:  ./deploy-hotplug.sh [X1Pro_IP]
# 默认:  192.168.7.1
# ============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOTPLUG_SRC="$SCRIPT_DIR/files/etc/hotplug.d/iface/99-fix-l2tp-route"
TARGET_IP="${1:-192.168.7.1}"
TARGET_PATH="/etc/hotplug.d/iface/99-fix-l2tp-route"
PASS="1"

[ -f "$HOTPLUG_SRC" ] || { echo "[ERROR] 找不到 $HOTPLUG_SRC"; exit 1; }

echo "=============================================="
echo " 部署 hotplug 脚本到 X1Pro"
echo " 来源: $HOTPLUG_SRC"
echo " 目标: root@$TARGET_IP:$TARGET_PATH"
echo "=============================================="

# --- 1. 上传 ---
echo "[1] 上传脚本 ..."
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
    "$HOTPLUG_SRC" "root@$TARGET_IP:$TARGET_PATH" 2>/dev/null || {
    echo "[1] sshpass 不可用, 改用 expect ..."
    expect -c "
set timeout 15
spawn scp -o StrictHostKeyChecking=no $HOTPLUG_SRC root@$TARGET_IP:$TARGET_PATH
expect \"password:\"
send \"$PASS\r\"
expect eof
"
}

# --- 2. 设置权限 ---
echo "[2] 设置权限 ..."
expect -c "
set timeout 10
spawn ssh -o StrictHostKeyChecking=no root@$TARGET_IP
expect \"password:\"
send \"$PASS\r\"
expect \"# \"
send \"chmod 755 /etc/hotplug.d/iface/99-fix-l2tp-route && echo 'CHMOD_OK'\r\"
expect \"# \"
send \"exit\r\"
expect eof
" 2>&1 | grep -v "password:\|spawn\|^$\|BusyBox\|ImmortalWrt\|PadavanOnly\|▪\|█\|▐\|▀\|▄\|▌"

# --- 3. 验证 ---
echo "[3] 验证部署 ..."
expect -c "
set timeout 10
spawn ssh -o StrictHostKeyChecking=no root@$TARGET_IP
expect \"password:\"
send \"$PASS\r\"
expect \"# \"
send \"echo '=== 文件检查 ===' && ls -la /etc/hotplug.d/iface/99-fix-l2tp-route\r\"
expect \"# \"
send \"echo '' && echo '=== 内容前5行 ===' && head -5 /etc/hotplug.d/iface/99-fix-l2tp-route\r\"
expect \"# \"
send \"echo '' && echo '=== 检测 L2TP 接口 ===' && uci show network 2>/dev/null | grep proto=l2tp || echo '无 L2TP 接口(正常, 首次配置后自动触发)'\r\"
expect \"# \"
send \"exit\r\"
expect eof
" 2>&1 | grep -v "password:\|spawn\|^$\|BusyBox\|ImmortalWrt\|PadavanOnly\|▪\|█\|▐\|▀\|▄\|▌"

echo ""
echo "=============================================="
echo " 部署完成"
echo " hotplug 已在 /etc/hotplug.d/iface/99-fix-l2tp-route"
echo " 任意 L2TP 接口 UP 后 10 秒自动修复路由"
echo "=============================================="
