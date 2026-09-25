#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  iceLLM — 一行命令把安卓手机变成 OpenAI 兼容的本地 AI 服务器
#
#  安装:  curl -fsSL https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh | bash
#  用法:  ice-llm <start|stop|restart|status|logs|models|model|url|autostart>
#
#  依赖:  Termux + llama-cpp (自动安装)
#  模型:  ModelScope 下载 (国内直连), 默认 MiniCPM5-1B-Q4_K_M
# =============================================================================
set -u

VERSION="1.0.0"
BASE="$HOME/ice-llm"
MODELS_DIR="$BASE/models"
LOG="$BASE/ice-llm.log"
PIDFILE="$BASE/ice-llm.pid"
PORT="${ICE_LLM_PORT:-8080}"
CTX="${ICE_LLM_CTX:-8192}"
THREADS="$(nproc 2>/dev/null || echo 4)"
DEFAULT_MODEL="minicpm5"

# ---- 模型目录 (key => "文件名|URL") ------------------------------------------
MODEL_CATALOG() {
  cat <<'EOF'
minicpm5|MiniCPM5-1B-Q4_K_M.gguf|https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF/resolve/master/MiniCPM5-1B-Q4_K_M.gguf
qwen15|Qwen2.5-1.5B-Instruct-Q4_K_M.gguf|https://modelscope.cn/models/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
EOF
}

c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_cyan()  { printf '\033[36m%s\033[0m' "$1"; }
die() { echo "$(c_red "[x] $1")" >&2; exit 1; }
ok()  { echo "$(c_green "[ok] $1")"; }
info(){ echo "$(c_cyan "[*] $1")"; }

# ---- 环境检查 ----------------------------------------------------------------
check_termux() {
  if [ ! -d "$PREFIX" ] 2>/dev/null || ! command -v pkg >/dev/null 2>&1; then
    die "iceLLM 只在 Termux 里运行。先安装 Termux (F-Droid), 再重新执行本命令。"
  fi
}

ensure_llama() {
  if command -v llama-server >/dev/null 2>&1; then
    ok "llama-cpp 已安装: $(llama-server --version 2>/dev/null | head -1 || echo llama-server)"
    return
  fi
  info "安装 llama-cpp (Termux 官方源)..."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y llama-cpp || die "llama-cpp 安装失败, 请检查网络后重试"
  command -v llama-server >/dev/null 2>&1 || die "安装后仍找不到 llama-server"
  ok "llama-cpp 安装完成"
}

# ---- 模型管理 ----------------------------------------------------------------
free_space_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}'; }

find_local_model() {
  # $1 = 文件名; 优先 ice-llm/models, 其次 $HOME 下已有
  if [ -f "$MODELS_DIR/$1" ]; then echo "$MODELS_DIR/$1"; return; fi
  if [ -f "$HOME/$1" ]; then echo "$HOME/$1"; return; fi
}

pick_default_model() {
  # 最近修改的 .gguf (models 目录优先)
  local f
  f=$(ls -1t "$MODELS_DIR"/*.gguf 2>/dev/null | head -1)
  [ -n "$f" ] && { echo "$f"; return; }
  ls -1t "$HOME"/*.gguf 2>/dev/null | head -1
}

download_model() {
  local name="$1" file url
  case "$name" in
    http://*|https://*)
      url="$name"
      file=$(basename "$url")
      ;;
    *)
      local line
      line=$(MODEL_CATALOG | grep "^$name|" | head -1) || die "未知模型 '$name'。可选: $(MODEL_CATALOG | cut -d'|' -f1 | tr '\n' ' '), 或直接给完整 URL"
      file=$(echo "$line" | cut -d'|' -f2)
      url=$(echo "$line" | cut -d'|' -f3)
      ;;
  esac

  local existing
  existing=$(find_local_model "$file")
  if [ -n "$existing" ]; then
    ok "模型已存在, 跳过下载: $existing"
    return
  fi

  mkdir -p "$MODELS_DIR"
  local need_kb
  need_kb=$(echo "$url" | grep -qi '135m' && echo 300000 || echo 1200000)
  local free_kb
  free_kb=$(free_space_kb)
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((need_kb / 2)) ]; then
    die "剩余空间不足 (需约 $((need_kb / 1024 / 100))GB, 现有 $((free_kb / 1024 / 1024))GB)"
  fi
  info "下载模型 $file (支持断点续传, 中途断了重跑即可)..."
  curl -fL -C - --retry 3 --retry-delay 2 -o "$MODELS_DIR/$file" "$url" || die "下载失败: $url"
  ok "下载完成: $MODELS_DIR/$file"
}

cmd_models() {
  echo "已下载的模型:"
  ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null | awk '{print "  " $9 "  (" $5 ")"}'
  ls -lh "$HOME"/*.gguf 2>/dev/null | grep -v '^.*ice-llm' | awk '{print "  (home) " $9 "  (" $5 ")"}'
  echo
  echo "可下载 (ice-llm model <名称>):"
  MODEL_CATALOG | while IFS='|' read -r k f _; do echo "  $k  ->  $f"; done
}

# ---- 服务控制 ----------------------------------------------------------------
is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

get_ip() {
  # Android 15 的 toybox ifconfig 不支持指定网卡名, ip 命令也被禁
  # 只能解析不带参数的 ifconfig 输出
  local ip
  ip=$(ifconfig 2>/dev/null | awk '
    /^(wlan0|ap0|eth0|rndis0|dummy0):/ { f=1; next }
    /^[a-zA-Z0-9-]+:/                  { f=0 }
    f && /inet /                       { print $2; exit }')
  echo "${ip:-<本机IP>}"
}

wait_health() {
  local i h
  for i in $(seq 1 90); do
    h=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)
    case "$h" in *'"ok"'*) echo "$h"; return 0 ;; esac
    # 进程死了就直接失败
    is_running || { tail -3 "$LOG" 2>/dev/null; return 1; }
    sleep 1
  done
  return 1
}

show_urls() {
  local ip
  ip=$(get_ip)
  echo
  echo "  ┌─────────────────────────────────────────────────"
  echo "  │ WebUI:      $(c_cyan "http://$ip:$PORT")"
  echo "  │ OpenAI API: $(c_cyan "http://$ip:$PORT/v1/chat/completions")"
  echo "  │ Health:     http://$ip:$PORT/health"
  echo "  └─────────────────────────────────────────────────"
  echo
  echo "  本机快速测试:"
  echo "    curl http://127.0.0.1:$PORT/v1/chat/completions \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}]}'"
  echo
  echo "  局域网内其他设备 (电脑/平板) 用 Cherry Studio / Open WebUI / 任意"
  echo "  OpenAI 客户端接入, base_url 填 http://$ip:$PORT 即可。"
}

cmd_start() {
  ensure_llama
  if is_running; then
    ok "已在运行 (PID $(cat "$PIDFILE")), 端口 $PORT"
    show_urls
    return
  fi

  local model
  model=$(pick_default_model)
  if [ -z "$model" ]; then
    download_model "$DEFAULT_MODEL"
    model=$(pick_default_model)
    [ -z "$model" ] && die "没有可用模型"
  fi

  info "启动 llama-server: $(basename "$model")  (ctx=$CTX threads=$THREADS port=$PORT)"
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true
  nohup llama-server -m "$model" --host 0.0.0.0 --port "$PORT" \
    -c "$CTX" -ngl 99 -t "$THREADS" -np 2 > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"

  local h
  if h=$(wait_health); then
    ok "服务已就绪: $h"
    show_urls
  else
    die "启动超时, 查看日志: ice-llm logs"
  fi
}

cmd_stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 1
    is_running && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    ok "已停止"
  else
    pkill -f "llama-server.*--port $PORT" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "未在运行"
  fi
}

cmd_status() {
  if is_running; then
    local pid h
    pid=$(cat "$PIDFILE")
    h=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "无响应")
    echo "状态: $(c_green '运行中')  PID=$pid  health=$h"
    show_urls
  else
    echo "状态: $(c_red '未运行')   (ice-llm start 启动)"
  fi
}

cmd_autostart() {
  local want="${1:-on}"
  local marker="# >>> iceLLM autostart >>>"
  local line="$marker $HOME/ice-llm/ice-llm.sh start >/dev/null 2>&1 || true"
  local profile="$HOME/.profile"
  [ "$want" = "off" ] && {
    grep -v "$marker" "$profile" 2>/dev/null > "$profile.tmp" && mv "$profile.tmp" "$profile"
    ok "已关闭开机自启"
    return
  }
  if ! grep -q "$marker" "$profile" 2>/dev/null; then
    echo "$line" >> "$profile"
    ok "已加入 ~/.profile 开机自启 (Termux 启动时自动拉起)"
  else
    echo "已存在, 无需重复添加"
  fi
}

# ---- 入口 --------------------------------------------------------------------
cmd="${1:-install}"
check_termux
mkdir -p "$MODELS_DIR"
# 保证脚本自身在固定位置 (install 后才有固定路径)
if [ "$cmd" = "install" ] && [ "$(realpath "$0" 2>/dev/null)" != "$BASE/ice-llm.sh" ]; then
  cp "$0" "$BASE/ice-llm.sh" 2>/dev/null || true
fi
chmod +x "$BASE/ice-llm.sh" 2>/dev/null || true

case "$cmd" in
  install)  cmd_start ;;
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  restart)  cmd_stop; sleep 1; cmd_start ;;
  status)   cmd_status ;;
  logs)     [ -f "$LOG" ] && tail -n 40 "$LOG" || echo "暂无日志: $LOG" ;;
  model)    shift; download_model "${1:?用法: ice-llm model <名称|URL>}"; cmd_start ;;
  models)   cmd_models ;;
  url)      show_urls ;;
  autostart) cmd_autostart "${2:-on}" ;;
  version)  echo "iceLLM v$VERSION" ;;
  *)        echo "iceLLM v$VERSION — 安卓手机本地 AI 服务器"
            echo "用法: ice-llm <install|start|stop|restart|status|logs|models|model|url|autostart|version>"
            echo "  不带参数 = 安装并启动 (默认模型 minicpm5, 约 688MB)"
            ;;
esac
