#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  iceLLM — Turn your Android phone into an OpenAI-compatible local AI server
#  iceLLM — 一行命令，把安卓手机变成 OpenAI 兼容的本地 AI 服务器
#
#  Install: curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
#  Usage:   ice-llm <start|stop|restart|status|logs|models|model|url|test|autostart>
#
#  Deps:  Termux + llama-cpp (auto-installed)
#  Model: downloaded from ModelScope (fast in mainland China), default MiniCPM5-1B-Q4_K_M
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

# ---- Model catalog: key => "filename|URL" -----------------------------------
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

# ---- Environment checks -------------------------------------------------------
check_termux() {
  if [ ! -d "$PREFIX" ] 2>/dev/null || ! command -v pkg >/dev/null 2>&1; then
    die "iceLLM runs inside Termux only. Install Termux (F-Droid / GitHub Releases), then re-run. (iceLLM 只能在 Termux 里运行)"
  fi
}

ensure_llama() {
  if command -v llama-server >/dev/null 2>&1; then
    ok "llama-cpp installed: $(llama-server --version 2>/dev/null | head -1 || echo llama-server)"
    return
  fi
  info "Installing llama-cpp (official Termux repo)..."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y llama-cpp || die "llama-cpp install failed, check your network and retry"
  command -v llama-server >/dev/null 2>&1 || die "llama-server still not found after install"
  ok "llama-cpp installed"
}

# ---- Model management ---------------------------------------------------------
free_space_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}'; }

find_local_model() {
  # $1 = filename; prefer ~/ice-llm/models, then any .gguf already in $HOME
  if [ -f "$MODELS_DIR/$1" ]; then echo "$MODELS_DIR/$1"; return; fi
  if [ -f "$HOME/$1" ]; then echo "$HOME/$1"; return; fi
}

pick_default_model() {
  # newest .gguf (models dir first)
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
      line=$(MODEL_CATALOG | grep "^$name|" | head -1) || die "Unknown model '$name'. Keys: $(MODEL_CATALOG | cut -d'|' -f1 | tr '\n' ' '), or pass a full GGUF URL"
      file=$(echo "$line" | cut -d'|' -f2)
      url=$(echo "$line" | cut -d'|' -f3)
      ;;
  esac

  local existing
  existing=$(find_local_model "$file")
  if [ -n "$existing" ]; then
    ok "Model already downloaded, skipping: $existing"
    return
  fi

  mkdir -p "$MODELS_DIR"
  local need_kb
  need_kb=$(echo "$url" | grep -qi '135m' && echo 300000 || echo 1200000)
  local free_kb
  free_kb=$(free_space_kb)
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((need_kb / 2)) ]; then
    die "Not enough free space (need ~$((need_kb / 1024 / 100))GB, have $((free_kb / 1024 / 1024))GB)"
  fi
  info "Downloading $file (resumable — re-run this command if it breaks)..."
  curl -fL -C - --retry 3 --retry-delay 2 -o "$MODELS_DIR/$file" "$url" || die "Download failed: $url"
  ok "Downloaded: $MODELS_DIR/$file"
}

cmd_models() {
  echo "Downloaded models:"
  ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null | awk '{print "  " $9 "  (" $5 ")"}'
  ls -lh "$HOME"/*.gguf 2>/dev/null | grep -v '^.*ice-llm' | awk '{print "  (home) " $9 "  (" $5 ")"}'
  echo
  echo "Available to download (ice-llm model <key>):"
  MODEL_CATALOG | while IFS='|' read -r k f _; do echo "  $k  ->  $f"; done
}

# ---- Server control ------------------------------------------------------------
is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

get_ip() {
  # Android 15 toybox ifconfig doesn't accept a NIC name argument, and `ip` is
  # stripped from PATH — parse plain `ifconfig` output instead.
  local ip
  ip=$(ifconfig 2>/dev/null | awk '
    /^(wlan0|ap0|eth0|rndis0|dummy0):/ { f=1; next }
    /^[a-zA-Z0-9-]+:/                  { f=0 }
    f && /inet /                       { print $2; exit }')
  echo "${ip:-<your-ip>}"
}

wait_health() {
  local i h
  for i in $(seq 1 90); do
    h=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)
    case "$h" in *'"ok"'*) echo "$h"; return 0 ;; esac
    # fail fast if the process died
    is_running || { tail -3 "$LOG" 2>/dev/null; return 1; }
    sleep 1
  done
  return 1
}

show_urls() {
  local ip
  ip=$(get_ip)
  echo
  echo "  +-------------------------------------------------"
  echo "  | WebUI:      $(c_cyan "http://$ip:$PORT")"
  echo "  | OpenAI API: $(c_cyan "http://$ip:$PORT/v1/chat/completions")"
  echo "  | Health:     http://$ip:$PORT/health"
  echo "  +-------------------------------------------------"
  echo
  echo "  Quick local test:"
  echo "    curl http://127.0.0.1:$PORT/v1/chat/completions \\"
  echo "      -H 'Content-Type: application/json' \\"
  echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
  echo
  echo "  Any device on your LAN (PC / tablet / another phone): open the WebUI"
  echo "  in a browser, or point any OpenAI client at base_url http://$ip:$PORT"
  echo "  (Cherry Studio / Open WebUI / your own code)."
}

cmd_start() {
  ensure_llama
  if is_running; then
    ok "Already running (PID $(cat "$PIDFILE")), port $PORT"
    show_urls
    return
  fi

  local model
  model=$(pick_default_model)
  if [ -z "$model" ]; then
    download_model "$DEFAULT_MODEL"
    model=$(pick_default_model)
    [ -z "$model" ] && die "No model available"
  fi

  info "Starting llama-server: $(basename "$model")  (ctx=$CTX threads=$THREADS port=$PORT)"
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true
  nohup llama-server -m "$model" --host 0.0.0.0 --port "$PORT" \
    -c "$CTX" -ngl 99 -t "$THREADS" -np 2 > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"

  local h
  if h=$(wait_health); then
    ok "Server ready: $h"
    show_urls
  else
    die "Startup timed out, check logs: ice-llm logs"
  fi
}

cmd_stop() {
  if is_running; then
    kill "$(cat "$PIDFILE")" 2>/dev/null
    sleep 1
    is_running && kill -9 "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    ok "Stopped"
  else
    pkill -f "llama-server.*--port $PORT" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "Not running"
  fi
}

cmd_status() {
  if is_running; then
    local pid h
    pid=$(cat "$PIDFILE")
    h=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "no response")
    echo "Status: $(c_green 'running')  PID=$pid  health=$h"
    show_urls
  else
    echo "Status: $(c_red 'stopped')   (start with: ice-llm start)"
  fi
}

cmd_test() {
  if ! is_running; then echo "$(c_red 'Server not running — run ice-llm start first')"; return 1; fi
  info "Sending a self-test request (on-device CPU inference, may take 1-3 minutes)..."
  local t0 t1 code
  t0=$(date +%s)
  code=$(curl -sS --max-time 420 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"local","messages":[{"role":"user","content":"1+1=? answer with the number only"}],"max_tokens":20,"temperature":0,"reasoning_effort":"none"}' \
    -o "$BASE/test_last.json" -w '%{http_code}' 2>/dev/null)
  t1=$(date +%s)
  if [ "$code" = "200" ]; then
    ok "Self-test passed ($(($t1-$t0))s)"
    grep -o '"content":"[^"]*"' "$BASE/test_last.json" | head -1
  else
    die "Self-test failed (http=$code), see: ice-llm logs"
  fi
}

cmd_autostart() {
  local want="${1:-on}"
  local marker="# >>> iceLLM autostart >>>"
  local line="$marker $HOME/ice-llm/ice-llm.sh start >/dev/null 2>&1 || true"
  local profile="$HOME/.profile"
  [ "$want" = "off" ] && {
    grep -v "$marker" "$profile" 2>/dev/null > "$profile.tmp" && mv "$profile.tmp" "$profile"
    ok "Autostart disabled"
    return
  }
  if ! grep -q "$marker" "$profile" 2>/dev/null; then
    echo "$line" >> "$profile"
    ok "Added to ~/.profile (auto-starts when Termux launches)"
  else
    echo "Already configured"
  fi
}

# ---- Entry point ---------------------------------------------------------------
cmd="${1:-install}"
check_termux
mkdir -p "$MODELS_DIR"
# make sure the script itself lives at a fixed path (only after install)
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
  logs)     [ -f "$LOG" ] && tail -n 40 "$LOG" || echo "No log yet: $LOG" ;;
  model)    shift; download_model "${1:?Usage: ice-llm model <key|URL>}"; cmd_start ;;
  models)   cmd_models ;;
  url)      show_urls ;;
  test)     cmd_test ;;
  autostart) cmd_autostart "${2:-on}" ;;
  version)  echo "iceLLM v$VERSION" ;;
  *)        echo "iceLLM v$VERSION — turn your Android phone into an OpenAI-compatible local AI server"
            echo "                     把安卓手机变成 OpenAI 兼容的本地 AI 服务器"
            echo "Usage:   ice-llm <install|start|stop|restart|status|logs|models|model|url|test|autostart|version>"
            echo "No args = install & start (default model: minicpm5, ~688MB)"
            ;;
esac
