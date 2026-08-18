#!/bin/sh
# ============================================================
# X1Pro NPC 客户端配置脚本  (NPC 已内置于固件, 仅配置)
# ------------------------------------------------------------
# 用法:   sh /root/config-npc.sh [host] [vkey] [port]
#   不带参数则进入交互模式, 依次输入 host / port / vkey
#   host 不含端口; port 不填默认 8024
#
# 本脚本执行:
#   1. 检查固件内 NPC (npc 二进制 + uci 配置节)
#   2. 交互输入 host (不带端口) / port (默认 8024) / vkey
#   3. 写入 uci: server_addr=host, server_port=port, vkey, enable=1
#   4. 启动服务 + 开机自启
#   5. 验证连接 (进程 + 与服务端 TCP ESTABLISHED, 最多等 15 秒)
#      首次失败 → 自动停止并重启 npc 重试一次
#      重试仍失败 → 输出排错指引 (进程/端口连通性/vkey/日志)
#
# 重复运行可随时更新服务端信息。
# ============================================================

log(){ echo "  $*"; }

HOST="${1:-}"
VKEY="${2:-}"
PORT_ARG="${3:-}"

echo "========================================="
echo "  NPC 客户端配置 for X1Pro (免安装)"
echo "========================================="
echo ""

# ---------- 1. 检查 NPC ----------
echo "[1/4] 检查固件内 NPC..."
if ! command -v npc >/dev/null 2>&1; then
  echo "  [ERROR] 未找到 npc 二进制, 当前固件未内置 NPC"
  echo "          请使用 NPC客户端安装/install-npc.sh 安装"
  exit 1
fi
log "[ok] npc: $(command -v npc)"

# 确保 uci 配置节存在
if ! uci -q get npc.@npc[0] >/dev/null 2>&1; then
  echo "config npc" > /etc/config/npc
  uci add npc npc >/dev/null 2>&1 || true
  uci set npc.@npc[0].enable='0'
  uci set npc.@npc[0].server_addr=''
  uci set npc.@npc[0].vkey=''
  uci commit npc
  log "[ok] 已初始化 /etc/config/npc"
else
  log "[ok] 配置节 npc.@npc[0] 已存在"
fi

# 显示当前配置
CUR_SERVER=$(uci -q get npc.@npc[0].server_addr)
CUR_PORT=$(uci -q get npc.@npc[0].server_port)
CUR_VKEY=$(uci -q get npc.@npc[0].vkey)
CUR_ENABLE=$(uci -q get npc.@npc[0].enable)
echo ""
echo "  当前配置:"
echo "    enable:      ${CUR_ENABLE:-0}"
echo "    server_addr: ${CUR_SERVER:-<未设置>}"
echo "    server_port: ${CUR_PORT:-<未设置>}"
echo "    vkey:        ${CUR_VKEY:+已设置 (回车保留)}"
if [ -n "$CUR_SERVER" ] && echo "$CUR_SERVER" | grep -q ':'; then
  echo "    [提示] server_addr 含 ':' — 这是旧配置的拼接格式,"
  echo "           本脚本将自动修正为 server_addr=host, server_port=port"
fi
echo ""

# ---------- 2. 交互输入 ----------
echo "[2/4] 输入配置信息..."
echo "  说明: 服务端地址 = host (不带端口), 端口 = 单独填写"
echo "        (因 /etc/init.d/npc 会拼接 server_addr + server_port,"
echo "         host:port 形式会导致端口被重复添加)"

# HOST (不带端口)
while :; do
  if [ -n "$HOST" ]; then
    echo "  服务端地址: $HOST (来自参数)"
    break
  fi
  printf "  服务端地址 (域名或 IP, 不带端口, 如 x.656866.xyz): "
  read -r HOST
  [ -n "$HOST" ] || { echo "    [!] 不能为空"; continue; }
  # 若误带了端口, 提醒并剥离
  case "$HOST" in
    *:*)
      echo "    [!] 检测到 ':', 端口不应写在这里"
      echo "        剥离后的地址: ${HOST%%:*}"
      HOST="${HOST%%:*}"
      ;;
  esac
  break
done

# PORT (端口, 默认 8024)
DEFAULT_PORT=8024
if [ -n "$PORT_ARG" ]; then
  PORT="$PORT_ARG"
  echo "  端口: $PORT (来自参数)"
else
  printf "  服务端端口 [回车默认 %s]: " "$DEFAULT_PORT"
  read -r PORT
  PORT="${PORT:-$DEFAULT_PORT}"
fi

# 端口范围校验
case "$PORT" in
  ''|*[!0-9]*)
    echo "    [!] 端口无效, 使用默认 $DEFAULT_PORT"; PORT="$DEFAULT_PORT" ;;
  *)
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "    [!] 端口超出 1-65535, 使用默认"; PORT="$DEFAULT_PORT"; } ;;
esac

# vkey
if [ -z "$VKEY" ]; then
  while :; do
    printf "  客户端密钥 vkey (服务端新建客户端后获得): "
    read -r VKEY
    [ -n "$VKEY" ] || echo "    [!] 不能为空"
    [ -n "$VKEY" ] && break
  done
fi

# 确认
echo ""
echo "  即将写入:"
echo "    server_addr: $HOST   (不带端口)"
echo "    server_port: $PORT"
echo "    vkey:        $VKEY"
if [ -t 0 ]; then
  printf "  确认写入并启动 NPC? [y/N]: "
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

# ---------- 3. 写入配置 ----------
echo "[3/4] 写入配置并启动..."
uci set npc.@npc[0].enable='1'
uci set npc.@npc[0].server_addr="$HOST"
uci set npc.@npc[0].server_port="$PORT"
uci set npc.@npc[0].vkey="$VKEY"
uci commit npc
log "[ok] 配置已写入"

# 写入配置后延迟 2 秒, 再开启 npc
log "  等待 2 秒后启动 NPC..."
sleep 2

/etc/init.d/npc enable >/dev/null 2>&1
/etc/init.d/npc restart >/dev/null 2>&1
log "[ok] NPC 已启动并设为开机自启"

# 开启 npc 后延迟 2 秒, 再开始连接检测程序
log "  等待 2 秒后开始连接检测..."
sleep 2

# ---------- 4. 连接验证 ----------
echo "[4/4] 验证连接..."

# 等待连接建立的轮询 (最多 15 秒)
# 注: 进程检测用 pidof — busybox pgrep -x 以完整命令名(/usr/bin/npc)
#     做精确匹配会恒失败, 不能用
wait_conn(){
  i=1
  while [ $i -le 5 ]; do
    if pidof npc >/dev/null 2>&1 && \
       netstat -tn 2>/dev/null | grep -E ":$PORT([^0-9]|$)" | grep -qi estab; then
      return 0
    fi
    sleep 3
    i=$((i+1))
  done
  return 1
}

conn_ok=0
wait_conn && conn_ok=1

# 首次失败 → 停止 npc 再重新启动, 尝试第二次连接
if [ "$conn_ok" != "1" ]; then
  echo "  [!] 首次连接失败, 停止 npc 并重新启动重试..."
  /etc/init.d/npc stop >/dev/null 2>&1
  killall npc 2>/dev/null
  sleep 2
  /etc/init.d/npc start >/dev/null 2>&1
  sleep 2
  wait_conn && conn_ok=1
fi

if [ "$conn_ok" = "1" ]; then
  log "[ok] npc 进程运行中 (PID: $(pidof npc | tr ' ' ' '))"
  log "[ok] 已与服务端 $HOST:$PORT 建立连接 (ESTABLISHED)"
  log "[ok] 验证通过, NPC 工作正常"
else
  echo ""
  echo "  ============================================"
  echo "   [FAIL] 重启重试后仍未检测到与服务端的活跃连接"
  echo "  ============================================"
  echo ""
  echo "   请按以下步骤排错:"
  echo ""
  echo "   1. 检查 npc 进程是否存活:"
  echo "        pidof npc"
  echo "      进程不存在 → 启动失败, 看日志找报错:"
  echo "        logread | grep -i npc"
  echo ""
  echo "   2. 测试服务端端口连通性 (busybox nc 无 -z 选项, 用此形式):"
  echo "        nc -w 5 $HOST $PORT < /dev/null"
  echo "        echo \$?   (返回 0=连通, 1=失败)"
  echo "      或用 wget 测试 (TCP over HTTP):"
  echo "        wget --spider --timeout=5 http://$HOST:$PORT/ 2>&1"
  echo "      不通 → 检查: 服务端 nps 是否运行 / 防火墙是否放行 /"
  echo "             端口号是否正确 / 服务端地址解析 (nslookup $HOST)"
  echo ""
  echo "   3. 核对 vkey 是否有效:"
  echo "      在服务端 nps Web 界面 → 客户端管理 核对密钥,"
  echo "      无效 vkey 会导致注册失败并不断重连"
  echo ""
  echo "   4. 观察实时日志定位问题:"
  echo "        logread -f | grep -i npc"
  echo ""
  echo "   排错后可重新运行本脚本: sh $0"
  echo "  ============================================"
fi

echo ""
echo "========================================="
echo "  配置完成!"
echo "  管理页面: LuCI → 服务 → NPC"
echo "  查看日志: logread | grep -i npc"
echo "========================================="
