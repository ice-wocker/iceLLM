#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  iceLLM v2 — Turn your Android phone into an OpenAI-compatible local AI server
#  iceLLM v2 — 一行命令，把安卓手机变成 OpenAI 兼容的本地 AI 服务器
#
#  Install:
#    curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
#    # raw.githubusercontent.com 不通时用 jsDelivr 镜像：
#    curl -fsSL https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh | bash
#
#  Usage:   ice-llm help
#  Docs:    https://github.com/ice-wocker/iceLLM
#
#  Requirements: Termux (F-Droid / GitHub Releases). Everything else
#  (llama-cpp, curl) is installed automatically from the official Termux repo.
# =============================================================================

set -u

VERSION="2.0.0"
UPDATE_URL="${ICE_LLM_UPDATE_URL:-https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh}"
UPDATE_URL_CN="https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh"

# ---- Paths -------------------------------------------------------------------
BASE="${ICE_LLM_HOME:-$HOME/ice-llm}"
MODELS_DIR="$BASE/models"
LOG="$BASE/ice-llm.log"
PIDFILE="$BASE/ice-llm.pid"
CONFIG_FILE="$BASE/config"
CURRENT_FILE="$BASE/current-model"
SELF="$BASE/ice-llm.sh"

AUTOSTART_BEGIN="# >>> iceLLM autostart >>>"
AUTOSTART_END="# <<< iceLLM autostart <<<"

CONFIG_KEYS="host port ctx threads ngl parallel api_key model extra_args health_timeout log_max_kb keep_logs jinja flash_attn"
DEFAULT_MODEL="minicpm5"

# ---- Built-in defaults (config file overrides; ICE_LLM_* env overrides both) --
HOST="0.0.0.0"
PORT="8080"
CTX="8192"
THREADS="$(nproc 2>/dev/null)"
[ -n "$THREADS" ] || THREADS="4"
NGL="99"
PARALLEL="2"
API_KEY=""
MODEL=""
EXTRA_ARGS=""
HEALTH_TIMEOUT="180"
LOG_MAX_KB="2048"
KEEP_LOGS="3"
JINJA="on"
FLASH_ATTN="off"
TEST_TIMEOUT="${ICE_LLM_TEST_TIMEOUT:-420}"

# ---- Colors / logging (logs go to stderr so functions can return values) -----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

c_green() { printf '%s%s%s' "$C_GREEN" "$1" "$C_RESET"; }
c_red()   { printf '%s%s%s' "$C_RED"   "$1" "$C_RESET"; }
ok()      { printf '%s[ok]%s %s\n' "$C_GREEN"  "$C_RESET" "$1" >&2; }
info()    { printf '%s[*]%s %s\n'  "$C_CYAN"   "$C_RESET" "$1" >&2; }
warn()    { printf '%s[!]%s %s\n'  "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()     { printf '%s[x]%s %s\n'  "$C_RED"    "$C_RESET" "$1" >&2; exit 1; }

# ---- Config file handling ----------------------------------------------------
set_config_var() {
  local key="$1" val="$2"
  case "$key" in
    host)           [ -n "${ICE_LLM_HOST+x}" ]           && return 0; HOST="$val" ;;
    port)           [ -n "${ICE_LLM_PORT+x}" ]           && return 0; PORT="$val" ;;
    ctx)            [ -n "${ICE_LLM_CTX+x}" ]            && return 0; CTX="$val" ;;
    threads)        [ -n "${ICE_LLM_THREADS+x}" ]        && return 0; THREADS="$val" ;;
    ngl)            [ -n "${ICE_LLM_NGL+x}" ]            && return 0; NGL="$val" ;;
    parallel)       [ -n "${ICE_LLM_PARALLEL+x}" ]       && return 0; PARALLEL="$val" ;;
    api_key)        [ -n "${ICE_LLM_API_KEY+x}" ]        && return 0; API_KEY="$val" ;;
    model)          [ -n "${ICE_LLM_MODEL+x}" ]          && return 0; MODEL="$val" ;;
    extra_args)     [ -n "${ICE_LLM_EXTRA_ARGS+x}" ]     && return 0; EXTRA_ARGS="$val" ;;
    health_timeout) [ -n "${ICE_LLM_HEALTH_TIMEOUT+x}" ] && return 0; HEALTH_TIMEOUT="$val" ;;
    log_max_kb)     [ -n "${ICE_LLM_LOG_MAX_KB+x}" ]     && return 0; LOG_MAX_KB="$val" ;;
    keep_logs)      [ -n "${ICE_LLM_KEEP_LOGS+x}" ]      && return 0; KEEP_LOGS="$val" ;;
    jinja)          [ -n "${ICE_LLM_JINJA+x}" ]          && return 0; JINJA="$val" ;;
    flash_attn)     [ -n "${ICE_LLM_FLASH_ATTN+x}" ]     && return 0; FLASH_ATTN="$val" ;;
    *) return 0 ;;
  esac
}

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    [ -n "$key" ] && set_config_var "$key" "$val"
  done < "$CONFIG_FILE"
}

load_config
# Environment variables win over the config file
HOST="${ICE_LLM_HOST:-$HOST}"
PORT="${ICE_LLM_PORT:-$PORT}"
CTX="${ICE_LLM_CTX:-$CTX}"
THREADS="${ICE_LLM_THREADS:-$THREADS}"
NGL="${ICE_LLM_NGL:-$NGL}"
PARALLEL="${ICE_LLM_PARALLEL:-$PARALLEL}"
API_KEY="${ICE_LLM_API_KEY:-$API_KEY}"
MODEL="${ICE_LLM_MODEL:-$MODEL}"
EXTRA_ARGS="${ICE_LLM_EXTRA_ARGS:-$EXTRA_ARGS}"
HEALTH_TIMEOUT="${ICE_LLM_HEALTH_TIMEOUT:-$HEALTH_TIMEOUT}"
LOG_MAX_KB="${ICE_LLM_LOG_MAX_KB:-$LOG_MAX_KB}"
KEEP_LOGS="${ICE_LLM_KEEP_LOGS:-$KEEP_LOGS}"
JINJA="${ICE_LLM_JINJA:-$JINJA}"
FLASH_ATTN="${ICE_LLM_FLASH_ATTN:-$FLASH_ATTN}"

# =============================================================================
#  Model catalog
#  key|filename|size_bytes|sha256|URL|note
#  All entries are verified ModelScope repos (mainland-China direct download).
# =============================================================================
MODEL_CATALOG() {
  cat <<'EOF'
minicpm5|MiniCPM5-1B-Q4_K_M.gguf|688065920|81b64d05a23b17b34c475f42b3e72fbde62d4b92cc34541f7a8031d0752deafa|https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF/resolve/master/MiniCPM5-1B-Q4_K_M.gguf|default - strong Chinese, thinking mode
minicpm5q8|MiniCPM5-1B-Q8_0.gguf|1153529216|0dc7638539067268774c275a14a6ec9c7e01f7eeb2cff606c8590361fa527e4c|https://modelscope.cn/models/OpenBMB/MiniCPM5-1B-GGUF/resolve/master/MiniCPM5-1B-Q8_0.gguf|MiniCPM5, higher precision
qwen05|qwen2.5-0.5b-instruct-q4_k_m.gguf|491400032|74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db|https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf|smallest / fastest
qwen15|qwen2.5-1.5b-instruct-q4_k_m.gguf|1117320736|6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e|https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf|balanced, good instruction following
qwencoder|qwen2.5-coder-1.5b-instruct-q4_k_m.gguf|1117320768|cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046|https://modelscope.cn/models/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/master/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf|code completion
qwen3-0.6b|Qwen3-0.6B-Q8_0.gguf|639446688|9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031|https://modelscope.cn/models/Qwen/Qwen3-0.6B-GGUF/resolve/master/Qwen3-0.6B-Q8_0.gguf|Qwen3 small, thinking capable
qwen3-1.7b|Qwen3-1.7B-Q8_0.gguf|1834426016|061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a|https://modelscope.cn/models/Qwen/Qwen3-1.7B-GGUF/resolve/master/Qwen3-1.7B-Q8_0.gguf|Qwen3 medium, strongest here
EOF
}

catalog_line() { MODEL_CATALOG | awk -F'|' -v k="$1" '$1==k {print; exit}'; }

# =============================================================================
#  Small helpers
# =============================================================================
human_size() {
  local b="${1:-0}"
  case "$b" in ''|*[!0-9]*) printf '%sB' "${b:-0}"; return ;; esac
  if   [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.2fGB", b/1073741824}'
  elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.0fMB", b/1048576}'
  elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.0fKB", b/1024}'
  else printf '%sB' "$b"; fi
}

file_size() { stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0; }
free_space_kb() { df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}'; }
free_disk_human() { local k; k="$(free_space_kb)"; [ -n "$k" ] && human_size $((k * 1024)) || echo '?'; }
ram_total() { awk '/^MemTotal:/ {printf "%.1fGB", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?'; }
ram_total_mb() { awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; return; fi
  if command -v sha256 >/dev/null 2>&1; then sha256 -q "$1"; return; fi
  if command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; return; fi
  echo ""
}

# =============================================================================
#  Environment / dependencies
# =============================================================================
check_termux() {
  if [ ! -d "${PREFIX:-/nonexistent}" ] || ! command -v pkg >/dev/null 2>&1; then
    die "iceLLM runs inside Termux only. Install Termux (F-Droid / GitHub Releases), then re-run. (iceLLM 只能在 Termux 里运行)"
  fi
}

ensure_curl() {
  command -v curl >/dev/null 2>&1 && return 0
  info "Installing curl..."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y curl || die "Failed to install curl"
}

ensure_llama() {
  command -v llama-server >/dev/null 2>&1 && return 0
  info "Installing llama-cpp (official Termux repo)..."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y llama-cpp || die "llama-cpp install failed — check your network and retry"
  command -v llama-server >/dev/null 2>&1 || die "llama-server still missing after install"
}

ensure_deps() { ensure_curl; ensure_llama; }

install_self() {
  mkdir -p "$BASE" 2>/dev/null || true
  local self
  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  if [ -f "$self" ] && [ "$self" != "$SELF" ]; then
    cp -f "$self" "$SELF" 2>/dev/null && chmod +x "$SELF" 2>/dev/null
    return 0
  fi
  if [ ! -f "$SELF" ] && command -v curl >/dev/null 2>&1; then
    info "Installing iceLLM to $SELF ..."
    if curl -fsSL "$UPDATE_URL" -o "$SELF" 2>/dev/null || curl -fsSL "$UPDATE_URL_CN" -o "$SELF" 2>/dev/null; then
      chmod +x "$SELF" 2>/dev/null
    else
      warn "Could not fetch a canonical copy (network blocked?) — autostart needs $SELF"
    fi
  fi
}

# =============================================================================
#  Process management
# =============================================================================
read_pid() { [ -f "$PIDFILE" ] && cat "$PIDFILE" 2>/dev/null; }
pid_alive() { local p="${1:-}"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

pid_is_llama() {
  local p="${1:-}" cl
  cl="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
  case "$cl" in *llama-server*) return 0 ;; esac
  [ -z "$cl" ] && return 0   # /proc unreadable -> assume it is ours
  return 1
}

is_running() { local p; p="$(read_pid)"; [ -n "$p" ] && pid_alive "$p" && pid_is_llama "$p"; }
clean_stale_pid() { [ -f "$PIDFILE" ] && ! is_running && rm -f "$PIDFILE"; return 0; }

port_busy() {
  local p="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then exec 3>&- 3<&- 2>/dev/null; return 0; fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 0
  fi
  return 1
}

health_ok() {
  curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q '"ok"'
}

# Our own managed process, or any healthy llama-server already on the port
server_up() { is_running || health_ok; }

get_ip() {
  local ip
  ip="$(ifconfig 2>/dev/null | awk '
    /^(wlan0|wlan1|ap0|eth0|rndis0|tun0):/ { f=1; next }
    /^[a-zA-Z0-9._-]+:/                  { f=0 }
    f && /inet /                          { print $2; exit }')"
  [ -z "$ip" ] && ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ { print $2; exit }')"
  echo "${ip:-<your-ip>}"
}

uptime_of() {
  local p="$1" et s
  et="$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')"
  if [ -n "$et" ]; then echo "$et"; return; fi
  s="$(stat -c %Y "$PIDFILE" 2>/dev/null)"
  if [ -n "$s" ]; then echo "$(( $(date +%s) - s ))s"; else echo "?"; fi
}

rotate_log() {
  [ -f "$LOG" ] || return 0
  local kb=$(( $(file_size "$LOG") / 1024 ))
  [ "$kb" -lt "${LOG_MAX_KB:-2048}" ] && return 0
  local i="${KEEP_LOGS:-3}"
  while [ "$i" -gt 1 ]; do
    [ -f "$LOG.$((i - 1))" ] && mv -f "$LOG.$((i - 1))" "$LOG.$i"
    i=$((i - 1))
  done
  mv -f "$LOG" "$LOG.1"
}

log_has_arg_error() {
  tail -n 40 "$LOG" 2>/dev/null | grep -qiE "unknown argument|unrecognized|invalid argument|invalid option|did you mean"
}

# =============================================================================
#  Model download / verification
# =============================================================================
RES_FILE=""; RES_URL=""; RES_SHA=""; RES_SIZE=""

# Resolve a user reference into RES_* (catalog key | owner/repo/file.gguf | URL | path | filename)
resolve_ref() {
  local ref="${1:-}" sh line
  RES_FILE=""; RES_URL=""; RES_SHA=""; RES_SIZE=""
  [ -n "$ref" ] || return 1

  case "$ref" in
    http://*|https://*) RES_URL="$ref"; RES_FILE="$(basename "${ref%%\?*}")"; return 0 ;;
  esac

  sh="$ref"; case "$sh" in ms:*) sh="${sh#ms:}" ;; esac
  case "$sh" in
    */*/*.gguf|*/*/*.GGUF)
      RES_FILE="$(basename "$sh")"
      RES_URL="https://modelscope.cn/models/${sh%/*}/resolve/master/$RES_FILE"
      return 0 ;;
  esac

  line="$(catalog_line "$ref")"
  if [ -n "$line" ]; then
    RES_FILE="$(printf '%s' "$line" | cut -d'|' -f2)"
    RES_SIZE="$(printf '%s' "$line" | cut -d'|' -f3)"
    RES_SHA="$(printf '%s' "$line" | cut -d'|' -f4)"
    RES_URL="$(printf '%s' "$line" | cut -d'|' -f5)"
    return 0
  fi

  [ -f "$ref" ]              && { RES_FILE="$ref"; return 0; }
  [ -f "$MODELS_DIR/$ref" ]  && { RES_FILE="$MODELS_DIR/$ref"; return 0; }
  [ -f "$HOME/$ref" ]        && { RES_FILE="$HOME/$ref"; return 0; }
  return 1
}

space_guard() {
  local need="${1:-0}" free_kb free_bytes
  case "$need" in ''|*[!0-9]*) return 0 ;; esac
  [ "$need" -le 0 ] && return 0
  free_kb="$(free_space_kb)"
  [ -z "$free_kb" ] && return 0
  free_bytes=$((free_kb * 1024))
  if [ "$free_bytes" -lt $((need + need / 20)) ]; then
    die "Not enough space in \$HOME: need ~$(human_size "$need"), free $(human_size "$free_bytes")"
  fi
}

verify_model() {
  local f="$1" want="${2:-0}" sha="${3:-}" have got
  have="$(file_size "$f")"
  if [ "$want" -gt 0 ] && [ "$have" != "$want" ]; then
    rm -f "$f"
    die "Size mismatch for $(basename "$f"): got $(human_size "$have"), expected $(human_size "$want"). File removed — please retry."
  fi
  if [ "$(head -c 4 "$f" 2>/dev/null | tr -d '\000')" != "GGUF" ]; then
    rm -f "$f"
    die "$(basename "$f") is not a valid GGUF file (bad magic). File removed — please retry."
  fi
  if [ -n "$sha" ] && [ "${ICE_LLM_SKIP_SHA:-0}" != "1" ]; then
    info "Verifying SHA256..."
    got="$(sha256_of "$f")"
    if [ -z "$got" ]; then
      warn "No sha256 tool available — skipping checksum verification"
    elif [ "$got" != "$sha" ]; then
      rm -f "$f"
      die "SHA256 mismatch — the file is corrupt and was removed. Please retry."
    else
      ok "SHA256 verified"
    fi
  fi
}

CURL_OPTS=(-fL --retry 5 --retry-delay 2 --retry-connrefused --connect-timeout 20)

# Download a model. Sets global DL_PATH (stdout is kept clean on purpose).
DL_PATH=""
download_model() {
  local ref="${1:-}" file dest partial want have remaining
  DL_PATH=""
  resolve_ref "$ref" || die "Unknown model '$ref'. See 'ice-llm models', or pass owner/repo/file.gguf, a GGUF URL, or a local path."

  if [ -z "$RES_URL" ]; then
    [ -f "$RES_FILE" ] || die "Model not found: $ref"
    DL_PATH="$RES_FILE"
    ok "Using local model: $RES_FILE"
    return 0
  fi

  file="$(basename "$RES_FILE")"
  dest="$MODELS_DIR/$file"
  partial="$dest.part"
  want="${RES_SIZE:-0}"

  if [ -f "$dest" ]; then
    have="$(file_size "$dest")"
    if [ "$want" -gt 0 ] && [ "$have" != "$want" ]; then
      warn "Existing $file has the wrong size — re-downloading"
      rm -f "$dest"
    else
      ok "Already downloaded: $file ($(human_size "$have"))"
      DL_PATH="$dest"
      return 0
    fi
  fi

  remaining="$want"
  if [ -f "$partial" ] && [ "$want" -gt 0 ]; then
    remaining=$(( want - $(file_size "$partial") ))
    [ "$remaining" -lt 0 ] && remaining=0
  fi
  space_guard "$remaining"

  mkdir -p "$MODELS_DIR"
  info "Downloading $file ($(human_size "$want")) — resumable, re-run if it breaks..."
  if [ -s "$partial" ]; then
    if ! curl "${CURL_OPTS[@]}" -C - -o "$partial" "$RES_URL"; then
      warn "Could not resume (server may not support byte ranges) — restarting from scratch..."
      rm -f "$partial"
      curl "${CURL_OPTS[@]}" -o "$partial" "$RES_URL" || {
        warn "Download interrupted — re-run the same command to resume."
        return 1
      }
    fi
  else
    curl "${CURL_OPTS[@]}" -o "$partial" "$RES_URL" || {
      warn "Download interrupted — re-run the same command to resume."
      return 1
    }
  fi
  mv -f "$partial" "$dest"
  verify_model "$dest" "$want" "$RES_SHA" || return 1
  ok "Downloaded: $dest"
  DL_PATH="$dest"
  return 0
}

find_local() {
  local n="$1"
  [ -f "$MODELS_DIR/$n" ] && { echo "$MODELS_DIR/$n"; return; }
  [ -f "$HOME/$n" ]       && { echo "$HOME/$n"; }
}

pick_newest_gguf() {
  local f
  f="$(ls -1t "$MODELS_DIR"/*.gguf 2>/dev/null | head -n1)"
  [ -n "$f" ] && { echo "$f"; return; }
  ls -1t "$HOME"/*.gguf 2>/dev/null | head -n1
}

pick_default_model() {
  local p
  if [ -n "$MODEL" ] && resolve_ref "$MODEL"; then
    if [ -n "$RES_URL" ]; then
      p="$MODELS_DIR/$(basename "$RES_FILE")"
      [ -f "$p" ] || p="$(find_local "$(basename "$RES_FILE")")"
    else
      p="$RES_FILE"
    fi
    [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return; }
  fi
  if [ -f "$CURRENT_FILE" ]; then
    p="$(cat "$CURRENT_FILE" 2>/dev/null)"
    [ -n "$p" ] && [ -f "$p" ] && { echo "$p"; return; }
  fi
  pick_newest_gguf
}

# =============================================================================
#  Server control
# =============================================================================
wait_health() {
  local start now h
  start="$(date +%s)"
  while :; do
    pid_alive "$(read_pid)" || return 2
    h="$(curl -s --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null)"
    case "$h" in *'"ok"'*) printf '%s' "$h"; return 0 ;; esac
    now="$(date +%s)"
    [ $((now - start)) -ge "$HEALTH_TIMEOUT" ] && return 1
    sleep 1
  done
}

SERVER_ARGS=()
build_server_args() {
  SERVER_ARGS=(llama-server -m "$1" --host "$HOST" --port "$PORT" -c "$CTX" -t "$THREADS" -np "$PARALLEL")
  [ "${NGL:-99}" != "0" ] && SERVER_ARGS+=(-ngl "$NGL")
  [ "$JINJA" = "on" ]      && SERVER_ARGS+=(--jinja)
  [ "$FLASH_ATTN" = "on" ] && SERVER_ARGS+=(--flash-attn)
  [ -n "$API_KEY" ]        && SERVER_ARGS+=(--api-key "$API_KEY")
  if [ -n "$EXTRA_ARGS" ]; then
    # Intentional word-splitting: extra_args is a raw argument list.
    # shellcheck disable=SC2206
    SERVER_ARGS+=($EXTRA_ARGS)
  fi
}

HEALTH_OUT=""
# start_server <model> ; returns 0=ready 1=timeout 2=died
start_server() {
  local model="$1" h rc
  build_server_args "$model"
  {
    echo
    echo "=== iceLLM start $(date '+%F %T') | $(basename "$model") | ctx=$CTX t=$THREADS np=$PARALLEL port=$PORT ==="
  } >> "$LOG" 2>/dev/null
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null || true
  nohup "${SERVER_ARGS[@]}" >> "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  h="$(wait_health)"; rc=$?
  HEALTH_OUT="$h"
  return "$rc"
}

show_urls() {
  local ip; ip="$(get_ip)"
  echo
  echo "  +-------------------------------------------------------------"
  echo "  | WebUI       http://$ip:$PORT"
  echo "  | OpenAI API  http://$ip:$PORT/v1"
  echo "  | Health      http://$ip:$PORT/health"
  [ -n "$API_KEY" ] && echo "  | API key     $API_KEY"
  echo "  +-------------------------------------------------------------"
  echo
  echo "  Test it locally:"
  if [ -n "$API_KEY" ]; then
    echo "    curl http://127.0.0.1:$PORT/v1/chat/completions \\"
    echo "      -H 'Authorization: Bearer $API_KEY' -H 'Content-Type: application/json' \\"
    echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
  else
    echo "    curl http://127.0.0.1:$PORT/v1/chat/completions \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
  fi
  echo
  echo "  Point any OpenAI client at base_url http://$ip:$PORT/v1"
  echo "  (Cherry Studio / Open WebUI / your own code). LAN-only by default."
}

cmd_start() {
  mkdir -p "$BASE" "$MODELS_DIR"
  ensure_deps
  clean_stale_pid

  if is_running; then
    ok "Already running (PID $(read_pid)), port $PORT"
    show_urls
    return 0
  fi

  if port_busy "$PORT"; then
    if health_ok; then
      ok "A server is already listening on port $PORT (not tracked by iceLLM's PID file)"
      show_urls
      return 0
    fi
    die "Port $PORT is already in use. Run 'ice-llm stop', or change it: ice-llm config set port 9000"
  fi

  local model
  model="$(pick_default_model)"
  if [ -z "$model" ]; then
    info "No local GGUF found — downloading the default model ('$DEFAULT_MODEL')..."
    download_model "$DEFAULT_MODEL" || die "Failed to download the default model"
    model="$DL_PATH"
  fi
  [ -n "$model" ] && [ -f "$model" ] || die "Model file not found: ${model:-<none>}"

  rotate_log

  local rc
  start_server "$model"; rc=$?
  if [ "$rc" != 0 ] && [ "$JINJA" = "on" ] && log_has_arg_error; then
    warn "This llama.cpp build rejected a flag (likely --jinja) — retrying without it"
    JINJA="off"
    rm -f "$PIDFILE"
    start_server "$model"; rc=$?
  fi

  case "$rc" in
    0)
      echo "$model" > "$CURRENT_FILE"
      ok "Server ready: $HEALTH_OUT"
      show_urls
      ;;
    2)
      warn "Server exited during startup. Last log lines:"
      tail -n 20 "$LOG" 2>/dev/null
      die "Startup failed — inspect with: ice-llm logs"
      ;;
    *)
      warn "Startup timed out after ${HEALTH_TIMEOUT}s. Last log lines:"
      tail -n 20 "$LOG" 2>/dev/null
      die "Startup timed out — inspect with: ice-llm logs"
      ;;
  esac
}

cmd_stop() {
  local pid; pid="$(read_pid)"
  if is_running; then
    kill "$pid" 2>/dev/null
    local i=0
    while [ "$i" -lt 20 ] && pid_alive "$pid"; do sleep 1; i=$((i + 1)); done
    if pid_alive "$pid"; then
      warn "Still alive after 20s — sending SIGKILL"
      kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    ok "Stopped (PID $pid)"
  else
    clean_stale_pid
    if pkill -f "llama-server .*--port $PORT" 2>/dev/null; then
      ok "Stopped a stray llama-server on port $PORT"
    else
      echo "Not running"
    fi
  fi
  command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true
}

cmd_status() {
  if is_running; then
    local pid h m
    pid="$(read_pid)"
    h="$(curl -s --max-time 3 "http://127.0.0.1:$PORT/health" 2>/dev/null)"
    [ -z "$h" ] && h="(no response)"
    m=""; [ -f "$CURRENT_FILE" ] && m="$(cat "$CURRENT_FILE" 2>/dev/null)"
    echo "Status : $(c_green running)   PID $pid   uptime $(uptime_of "$pid")"
    echo "Model  : ${m:-unknown}"
    echo "Health : $h"
    echo "Server : port=$PORT ctx=$CTX threads=$THREADS parallel=$PARALLEL ngl=$NGL"
    show_urls
  elif health_ok; then
    echo "Status : $(c_green running)   (external server on port $PORT — not tracked by iceLLM)"
    echo "  Stop it with: ice-llm stop"
    show_urls
  else
    clean_stale_pid
    echo "Status : $(c_red stopped)"
    echo "  Start with: ice-llm start"
  fi
}

cmd_logs() {
  local n=50 follow=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      -n)          n="${2:-50}"; shift 2 ;;
      *[!0-9]*)    shift ;;
      *)           n="$1"; shift ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) n=50 ;; esac
  if [ ! -f "$LOG" ]; then echo "No log yet: $LOG"; return 0; fi
  if [ "$follow" = 1 ]; then tail -n "$n" -f "$LOG"; else tail -n "$n" "$LOG"; fi
}

# =============================================================================
#  Test / benchmark
# =============================================================================
auth_hdr() { [ -n "$API_KEY" ] && printf 'Authorization: Bearer %s' "$API_KEY"; }

cmd_test() {
  server_up || die "Server is not running — run: ice-llm start"
  info "Sending a real inference request (on-device CPU; a 1B model can take 1-3 min)..."
  local body="$BASE/last-test.json" url code t0 t1 ans
  local hdr=(-H 'Content-Type: application/json')
  [ -n "$API_KEY" ] && hdr+=(-H "$(auth_hdr)")
  url="http://127.0.0.1:$PORT/v1/chat/completions"
  t0="$(date +%s)"
  code="$(curl -sS --max-time "$TEST_TIMEOUT" "$url" "${hdr[@]}" \
    -d '{"messages":[{"role":"user","content":"1+1=? Answer with the number only."}],"max_tokens":32,"temperature":0,"reasoning_effort":"none"}' \
    -o "$body" -w '%{http_code}' 2>/dev/null)"
  t1="$(date +%s)"
  if [ "$code" != "200" ]; then
    warn "HTTP $code; response:"
    head -c 500 "$body" 2>/dev/null; echo
    die "Self-test failed — check: ice-llm logs"
  fi
  ok "Self-test passed in $((t1 - t0))s"
  ans="$(grep -o '"content":[[:space:]]*"[^"]*"' "$body" 2>/dev/null | tail -n1 | sed 's/^"content":[[:space:]]*"//; s/"$//')"
  [ -n "$ans" ] && echo "  reply: $ans"
}

cmd_bench() {
  server_up || die "Server is not running — run: ice-llm start"
  local n="${1:-64}" body t0 t1
  case "$n" in ''|*[!0-9]*) n=64 ;; esac
  body="$BASE/last-bench.json"
  local url="http://127.0.0.1:$PORT/v1/chat/completions"
  local hdr=(-H 'Content-Type: application/json')
  [ -n "$API_KEY" ] && hdr+=(-H "$(auth_hdr)")

  info "Warm-up run..."
  curl -sS --max-time "$TEST_TIMEOUT" "$url" "${hdr[@]}" \
    -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":8,"temperature":0,"reasoning_effort":"none"}' \
    -o /dev/null 2>/dev/null || true

  info "Measuring (up to $n tokens)..."
  t0="$(date +%s)"
  if ! curl -sS --max-time "$TEST_TIMEOUT" "$url" "${hdr[@]}" \
        -d "{\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 100.\"}],\"max_tokens\":$n,\"temperature\":0,\"reasoning_effort\":\"none\"}" \
        -o "$body" 2>/dev/null; then
    die "Benchmark request failed — check: ice-llm logs"
  fi
  t1="$(date +%s)"

  local gen_tps prompt_tps gen_n
  gen_tps="$(grep -o '"predicted_per_second":[[:space:]]*[0-9.]*' "$body" 2>/dev/null | head -n1 | grep -o '[0-9.]*$')"
  prompt_tps="$(grep -o '"prompt_per_second":[[:space:]]*[0-9.]*' "$body" 2>/dev/null | head -n1 | grep -o '[0-9.]*$')"
  gen_n="$(grep -o '"predicted_n":[[:space:]]*[0-9]*' "$body" 2>/dev/null | head -n1 | grep -o '[0-9]*$')"

  echo "  Wall time   : $((t1 - t0))s"
  if [ -n "$gen_tps" ]; then
    printf '  Generation  : %s tok/s  (%s tokens)\n' "$gen_tps" "${gen_n:-?}"
  else
    printf '  Generation  : %s tokens in %ss\n' "${gen_n:-?}" "$((t1 - t0))"
  fi
  [ -n "$prompt_tps" ] && printf '  Prompt eval : %s tok/s\n' "$prompt_tps"
  printf '  Settings    : ctx=%s threads=%s parallel=%s ngl=%s\n' "$CTX" "$THREADS" "$PARALLEL" "$NGL"
  echo "  (numbers reported by llama.cpp itself)"
}

# =============================================================================
#  Models / config / doctor
# =============================================================================
cmd_models() {
  local active=""; [ -f "$CURRENT_FILE" ] && active="$(cat "$CURRENT_FILE" 2>/dev/null)"
  local found=0 f
  echo "${C_BOLD}Downloaded:${C_RESET}"
  for f in "$MODELS_DIR"/*.gguf "$HOME"/*.gguf; do
    [ -f "$f" ] || continue
    found=1
    if [ "$f" = "$active" ]; then echo "  * $(human_size "$(file_size "$f")")  $f"
    else                           echo "    $(human_size "$(file_size "$f")")  $f"; fi
  done
  [ "$found" = 0 ] && echo "  (none yet)"
  echo
  echo "${C_BOLD}Available to download (ice-llm model <key>):${C_RESET}"
  MODEL_CATALOG | while IFS='|' read -r k fn sz sha url note; do
    printf '  %-12s %-42s %8s  %s\n' "$k" "$fn" "$(human_size "$sz")" "$note"
  done
  echo
  echo "  * = active model"
  echo "  Any GGUF works too:        ice-llm model https://.../x.gguf"
  echo "  ModelScope repo shorthand: ice-llm model owner/repo/file.gguf"
}

cmd_model() {
  local ref="${1:-}" no_start="${2:-}"
  [ -n "$ref" ] || die "Usage: ice-llm model <key|owner/repo/file.gguf|URL|path> [--no-start]  (see: ice-llm models)"
  ensure_curl
  download_model "$ref" || die "Failed to prepare model: $ref"
  [ -n "$DL_PATH" ] || die "Could not resolve model: $ref"
  echo "$DL_PATH" > "$CURRENT_FILE"
  ok "Active model: $(basename "$DL_PATH")"
  if [ "$no_start" = "--no-start" ]; then return 0; fi
  cmd_stop >/dev/null 2>&1 || true
  sleep 1
  cmd_start
}

config_validate() {
  local key="$1" val="$2"
  case " $CONFIG_KEYS " in *" $key "*) ;; *) die "Unknown config key '$key'. Keys: $CONFIG_KEYS" ;; esac
  case "$key" in
    port|ctx|threads|ngl|parallel|health_timeout|log_max_kb|keep_logs)
      case "$val" in ''|*[!0-9]*) die "$key must be a positive integer" ;; esac ;;
    jinja|flash_attn)
      case "$val" in on|off) ;; *) die "$key must be 'on' or 'off'" ;; esac ;;
  esac
}

config_get() {
  case "$1" in
    host) echo "$HOST" ;;  port) echo "$PORT" ;;  ctx) echo "$CTX" ;;
    threads) echo "$THREADS" ;;  ngl) echo "$NGL" ;;  parallel) echo "$PARALLEL" ;;
    jinja) echo "$JINJA" ;;  flash_attn) echo "$FLASH_ATTN" ;;  model) echo "$MODEL" ;;
    health_timeout) echo "$HEALTH_TIMEOUT" ;;  log_max_kb) echo "$LOG_MAX_KB" ;;
    keep_logs) echo "$KEEP_LOGS" ;;  api_key) echo "$API_KEY" ;;  extra_args) echo "$EXTRA_ARGS" ;;
    *) die "Unknown config key '$1'. Keys: $CONFIG_KEYS" ;;
  esac
}

print_config_effective() {
  printf '  %-16s %s\n' host "$HOST"
  printf '  %-16s %s\n' port "$PORT"
  printf '  %-16s %s\n' ctx "$CTX"
  printf '  %-16s %s\n' threads "$THREADS"
  printf '  %-16s %s\n' ngl "$NGL"
  printf '  %-16s %s\n' parallel "$PARALLEL"
  printf '  %-16s %s\n' jinja "$JINJA"
  printf '  %-16s %s\n' flash_attn "$FLASH_ATTN"
  printf '  %-16s %s\n' model "${MODEL:-(auto)}"
  printf '  %-16s %s\n' health_timeout "$HEALTH_TIMEOUT"
  printf '  %-16s %s\n' log_max_kb "$LOG_MAX_KB"
  printf '  %-16s %s\n' keep_logs "$KEEP_LOGS"
  printf '  %-16s %s\n' api_key "${API_KEY:+<set>}"
  printf '  %-16s %s\n' extra_args "$EXTRA_ARGS"
}

cmd_config() {
  local sub="${1:-show}"
  case "$sub" in
    show|list|"")
      echo "Config file: $CONFIG_FILE"
      if [ -f "$CONFIG_FILE" ]; then echo; cat "$CONFIG_FILE"; else echo "(not created yet — using built-in defaults)"; fi
      echo
      echo "Effective values (ICE_LLM_* env vars override the file):"
      print_config_effective
      ;;
    path) echo "$CONFIG_FILE" ;;
    get)  [ -n "${2:-}" ] || die "Usage: ice-llm config get <key>"; config_get "$2" ;;
    set)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "Usage: ice-llm config set <key> <value>"
      config_validate "$2" "$3"
      mkdir -p "$BASE"; touch "$CONFIG_FILE"
      if grep -qE "^[[:space:]]*$2=" "$CONFIG_FILE"; then
        local tmp="$CONFIG_FILE.tmp"
        sed "s|^[[:space:]]*$2=.*|$2=$3|" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      else
        if [ -s "$CONFIG_FILE" ] && [ -n "$(tail -c1 "$CONFIG_FILE" 2>/dev/null)" ]; then echo >> "$CONFIG_FILE"; fi
        printf '%s=%s\n' "$2" "$3" >> "$CONFIG_FILE"
      fi
      ok "Set $2=$3  (apply with: ice-llm restart)"
      ;;
    unset)
      [ -n "${2:-}" ] || die "Usage: ice-llm config unset <key>"
      [ -f "$CONFIG_FILE" ] || { echo "No config file"; return 0; }
      local tmp="$CONFIG_FILE.tmp"
      grep -vE "^[[:space:]]*$2=" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
      ok "Unset $2  (apply with: ice-llm restart)"
      ;;
    *) die "Usage: ice-llm config [show|path|get <key>|set <key> <value>|unset <key>]" ;;
  esac
}

cmd_doctor() {
  local issues=0 ram_mb lv
  line() { printf '  %-20s %s\n' "$1" "$2"; }
  echo "iceLLM doctor — v$VERSION"
  echo

  if [ -d "${PREFIX:-/nonexistent}" ] && command -v pkg >/dev/null 2>&1; then
    line "environment" "Termux OK (${PREFIX})"
  else
    line "environment" "NOT Termux — iceLLM needs Termux"; issues=$((issues + 1))
  fi
  line "arch" "$(uname -m 2>/dev/null || echo '?')"
  line "cpu cores" "$(nproc 2>/dev/null || echo '?')"
  line "RAM" "$(ram_total)"
  line "free space (\$HOME)" "$(free_disk_human)"

  if command -v llama-server >/dev/null 2>&1; then
    line "llama-server" "$(command -v llama-server)"
    if command -v timeout >/dev/null 2>&1; then
      lv="$(timeout 5 llama-server --version 2>&1 | head -n1)"
    else
      lv="$(llama-server --version 2>&1 | head -n1)"
    fi
    line "llama version" "${lv:-unknown}"
  else
    line "llama-server" "MISSING (fix: pkg install llama-cpp)"; issues=$((issues + 1))
  fi
  command -v curl >/dev/null 2>&1 && line "curl" "$(command -v curl)" \
    || { line "curl" "MISSING (fix: pkg install curl)"; issues=$((issues + 1)); }
  command -v termux-wake-lock >/dev/null 2>&1 \
    && line "wakelock" "termux-wake-lock available" \
    || line "wakelock" "not available (install termux-api for best reliability)"

  if is_running; then
    line "server" "running (PID $(read_pid), uptime $(uptime_of "$(read_pid)"))"
  else
    line "server" "stopped"
  fi
  if port_busy "$PORT"; then
    if health_ok; then
      line "port $PORT" "in use by a healthy server"
    else
      line "port $PORT" "in use by another process"; issues=$((issues + 1))
    fi
  else
    line "port $PORT" "free"
  fi

  local model; model="$(pick_default_model)"
  line "active model" "${model:-none (will download $DEFAULT_MODEL on start)}"

  ram_mb="$(ram_total_mb)"
  if [ -n "$ram_mb" ] && [ "$ram_mb" -lt 6000 ] && [ "$CTX" -gt 8192 ]; then
    line "hint" "only ${ram_mb}MB RAM; consider: ice-llm config set ctx 4096"
  fi
  if [ "$THREADS" -gt "$(nproc 2>/dev/null || echo "$THREADS")" ] 2>/dev/null; then
    line "hint" "threads=$THREADS exceeds cores; consider: ice-llm config set threads $(nproc 2>/dev/null)"
  fi

  echo
  if [ "$issues" = 0 ]; then ok "No problems detected"; else warn "$issues issue(s) found above"; fi
}

# =============================================================================
#  Autostart / update / uninstall
# =============================================================================
cmd_autostart() {
  local want="${1:-status}" prof="$HOME/.profile"
  case "$want" in
    on)
      install_self
      [ -f "$SELF" ] || die "Could not install $SELF (needed for autostart)"
      if grep -qF "$AUTOSTART_BEGIN" "$prof" 2>/dev/null; then
        ok "Autostart already enabled in $prof"
      else
        {
          [ -f "$prof" ] && [ -n "$(tail -c1 "$prof" 2>/dev/null)" ] && echo
          echo "$AUTOSTART_BEGIN"
          echo "# Auto-start iceLLM when Termux opens (disable: ice-llm autostart off)"
          echo "\"$SELF\" start >/dev/null 2>&1 || true"
          echo "$AUTOSTART_END"
        } >> "$prof"
        ok "Autostart enabled ($prof) — starts when Termux launches"
      fi
      echo "  Tip: enable 'Acquire wakelock' in Termux settings; install the termux-boot"
      echo "  add-on if you also want it to start when the phone boots."
      ;;
    off)
      if grep -qF "$AUTOSTART_BEGIN" "$prof" 2>/dev/null; then
        awk -v b="$AUTOSTART_BEGIN" -v e="$AUTOSTART_END" \
          '$0==b{f=1} !f{print} $0==e{f=0}' "$prof" > "$prof.tmp" && mv "$prof.tmp" "$prof"
        ok "Autostart disabled"
      else
        echo "Autostart was not enabled"
      fi
      ;;
    status)
      if grep -qF "$AUTOSTART_BEGIN" "$prof" 2>/dev/null; then
        echo "Autostart: $(c_green on)   ($prof -> $SELF)"
      else
        echo "Autostart: off"
      fi
      ;;
    *) die "Usage: ice-llm autostart <on|off|status>" ;;
  esac
}

cmd_update() {
  ensure_curl
  local tmp newv
  tmp="$(mktemp 2>/dev/null || echo "$BASE/.update.$$")"
  info "Checking for updates..."
  if ! curl -fsSL "$UPDATE_URL" -o "$tmp" 2>/dev/null; then
    warn "raw.githubusercontent.com unreachable — trying the jsDelivr mirror..."
    curl -fsSL "$UPDATE_URL_CN" -o "$tmp" || { rm -f "$tmp"; die "Update failed: cannot reach the update server"; }
  fi
  newv="$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)"
  if [ -z "$newv" ]; then rm -f "$tmp"; die "Downloaded file is not a valid iceLLM script"; fi
  if [ "$newv" = "$VERSION" ]; then rm -f "$tmp"; ok "Already up to date (v$VERSION)"; return 0; fi
  mkdir -p "$BASE"
  cp -f "$tmp" "$SELF" && chmod +x "$SELF"
  rm -f "$tmp"
  ok "Updated v$VERSION -> v$newv"
  echo "  Apply with: ice-llm restart"
}

cmd_uninstall() {
  cmd_stop >/dev/null 2>&1 || true
  cmd_autostart off >/dev/null 2>&1 || true
  ok "Stopped the server and removed autostart"
  if [ "${1:-}" = "--purge" ] || [ "${1:-}" = "--yes" ] || [ "${1:-}" = "-y" ]; then
    rm -rf "$BASE"
    ok "Removed $BASE (models, config and logs deleted)"
  else
    echo "  Kept your data at $BASE (models / config / logs)."
    echo "  Delete everything with: ice-llm uninstall --purge"
  fi
}

# =============================================================================
#  Entry point
# =============================================================================
usage() {
  cat <<EOF
iceLLM v$VERSION — a local OpenAI-compatible LLM server for Android / Termux
把安卓手机变成 OpenAI 兼容的本地 AI 服务器

Usage: ice-llm <command> [args]

  (none) | install | start   Install deps, fetch a model if needed, start server
  stop                       Stop the server
  restart                    Restart the server
  status                     Status, active model, uptime and URLs
  logs [-f] [-n N]           Show the server log (-f = follow)
  url                        Print access URLs again
  test                       Send one real inference request (smoke test)
  bench [N]                  Measure prompt / generation tokens per second
  models                     List downloaded + downloadable models (* = active)
  model <ref> [--no-start]   Download & switch model. <ref> can be:
                               catalog key | owner/repo/file.gguf | GGUF URL | path
  doctor                     Diagnose environment, deps, port, RAM, model
  config                     Show config file + effective values
  config get <key>           Print one value
  config set <key> <value>   Persist a value (apply: ice-llm restart)
  config unset <key>         Remove a key
  autostart <on|off|status>  Start automatically when Termux opens
  update                     Update iceLLM itself
  uninstall [--purge]        Stop + remove autostart (--purge deletes data)
  version | help             Version / this help

Config keys: $CONFIG_KEYS
Env overrides: ICE_LLM_PORT, ICE_LLM_CTX, ICE_LLM_THREADS, ICE_LLM_MODEL,
               ICE_LLM_API_KEY, ICE_LLM_HOST, ICE_LLM_EXTRA_ARGS, ...
Data dir: $BASE
Docs: https://github.com/ice-wocker/iceLLM
EOF
}

main() {
  [ $# -gt 0 ] || set -- install
  local cmd="$1"
  shift

  case "$cmd" in
    -h|--help|help)     usage; return 0 ;;
    -v|--version|version) echo "iceLLM v$VERSION"; return 0 ;;
    doctor)             cmd_doctor; return 0 ;;
  esac

  check_termux
  mkdir -p "$BASE" "$MODELS_DIR"

  case "$cmd" in
    install|start|model|autostart) install_self >/dev/null 2>&1 || true ;;
  esac

  case "$cmd" in
    install)   cmd_start ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_stop; sleep 1; cmd_start ;;
    status)    cmd_status ;;
    logs|log)  cmd_logs "$@" ;;
    models)    cmd_models ;;
    model)     cmd_model "$@" ;;
    url)       show_urls ;;
    test)      cmd_test ;;
    bench)     cmd_bench "$@" ;;
    doctor)    cmd_doctor ;;
    config)    cmd_config "$@" ;;
    autostart) cmd_autostart "$@" ;;
    update)    cmd_update ;;
    uninstall) cmd_uninstall "$@" ;;
    *)         warn "Unknown command: $cmd"; echo; usage; return 1 ;;
  esac
}

main "$@"
