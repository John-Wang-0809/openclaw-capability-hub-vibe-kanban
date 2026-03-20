#!/usr/bin/env bash
# [IN]  None (self-contained utility library)
# [OUT] Shell functions: logging, platform detection, HTTP helpers, JSON helpers,
#       process management, config resolution, sed portability, confirm prompt
# [POS] Shared foundation sourced by all cross-platform bash scripts in this directory.
#       Does not execute anything when sourced — only defines functions.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

# Guard: skip if already sourced
[ -n "${_UTILS_SH_LOADED:-}" ] && return 0
_UTILS_SH_LOADED=1

set -euo pipefail

# ============================================================
# Logging
# ============================================================
log_info()  { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

# ============================================================
# Platform detection
# ============================================================
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unknown" ;;
  esac
}

open_url() {
  local url="$1"
  case "$(detect_os)" in
    macos) open "$url" 2>/dev/null || log_info "Open manually: $url" ;;
    linux) xdg-open "$url" 2>/dev/null || log_info "Open manually: $url" ;;
    *)     log_info "Open manually: $url" ;;
  esac
}

# ============================================================
# Command detection
# ============================================================
has_command() { command -v "$1" >/dev/null 2>&1; }

require_command() {
  local name="$1" hint="${2:-}"
  has_command "$name" || die "'$name' is required but not found.${hint:+ $hint}"
}

# ============================================================
# HTTP helpers (curl-based)
# ============================================================
http_get() {
  local url="$1" timeout="${2:-10}"
  curl -sf --max-time "$timeout" "$url" 2>/dev/null
}

http_post_json() {
  local url="$1" body="$2"
  curl -sf -X POST -H 'Content-Type: application/json' -d "$body" "$url" 2>/dev/null
}

test_http() {
  local url="$1" timeout="${2:-2}"
  curl -sf --max-time "$timeout" -o /dev/null "$url" 2>/dev/null
}

wait_for_health() {
  local url="$1" timeout_sec="${2:-30}" label="${3:-service}"
  local deadline=$((SECONDS + timeout_sec))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if test_http "$url"; then
      return 0
    fi
    sleep 1
  done
  die "$label did not become healthy at $url within ${timeout_sec}s"
}

# ============================================================
# JSON helpers (jq-based)
# ============================================================
json_get() {
  local file="$1" path="$2"
  jq -r "$path" < "$file"
}

json_get_or() {
  local file="$1" path="$2" fallback="$3"
  local val
  val="$(jq -r "$path // empty" < "$file" 2>/dev/null)" || true
  echo "${val:-$fallback}"
}

# ============================================================
# Process management
# ============================================================
start_background() {
  local log_dir="$1" name="$2"
  shift 2
  mkdir -p "$log_dir"
  local stdout="$log_dir/${name}.out.log"
  local stderr="$log_dir/${name}.err.log"
  nohup "$@" > "$stdout" 2> "$stderr" &
  echo $!
}

stop_if_alive() {
  local pid="$1" name="$2"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null && log_info "Stopped $name pid=$pid" || true
  else
    log_info "Skip $name pid=$pid (not running)"
  fi
}

find_process() {
  local pattern="$1"
  pgrep -f "$pattern" 2>/dev/null | head -1 || true
}

# ============================================================
# OpenClaw config resolution (Unix-only: no WSL complexity)
# ============================================================
resolve_config() {
  local config="$HOME/.openclaw/openclaw.json"
  [ -f "$config" ] || die "OpenClaw config not found: $config
Install OpenClaw and run: openclaw configure"
  echo "$config"
}

get_gateway_token() {
  local config
  config="$(resolve_config)"
  jq -r '.gateway.auth.token // empty' < "$config"
}

get_control_ui_url() {
  local base_url="$1" token="$2"
  base_url="${base_url%/}"
  if [ -z "$token" ]; then
    echo "$base_url/"
  else
    echo "$base_url/?token=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$token'))" 2>/dev/null || echo "$token")"
  fi
}

# ============================================================
# sed portability (BSD vs GNU)
# ============================================================
sed_inplace() {
  if [ "$(detect_os)" = "macos" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ============================================================
# Interactive prompt
# ============================================================
confirm_action() {
  local prompt="$1"
  printf '%s ' "$prompt"
  read -r answer
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================
# Path helpers
# ============================================================
script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd
}

repo_root() {
  local sdir
  sdir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
  # scripts/ → capability-hub/ → repo root
  dirname "$(dirname "$sdir")"
}

hub_dir() {
  local sdir
  sdir="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"
  # scripts/ → capability-hub/
  dirname "$sdir"
}

# ============================================================
# Executor list normalization
# ============================================================
normalize_executors() {
  local input="$1"
  # Split on comma, trim whitespace, filter empty
  echo "$input" | tr ',' '\n' | while IFS= read -r item; do
    local trimmed
    trimmed="$(echo "$item" | tr -d '[:space:]')"
    [ -n "$trimmed" ] && echo "$trimmed"
  done
}
