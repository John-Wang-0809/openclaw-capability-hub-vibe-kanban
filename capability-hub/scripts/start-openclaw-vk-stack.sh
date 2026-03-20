#!/usr/bin/env bash
# [IN]  _utils.sh, resolve-openclaw-config.sh, vk-inject-mcp.sh
#       Local openclaw, node, npx runtime availability
# [OUT] Starts or reuses OpenClaw gateway, vibe-kanban, and Capability Hub processes
#       Injects MCP config and writes stack state to stack-processes.json
# [POS] Unix equivalent of start-openclaw-vk-stack.ps1. Orchestrates local stack startup
#       with fail-fast preflight checks and health monitoring.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-config.sh
source "$SCRIPT_DIR/resolve-openclaw-config.sh"

# ============================================================
# Defaults
# ============================================================
VK_MODE="npx"
VK_API_BASE_URL="http://127.0.0.1:3001"
VK_NPX_VERSION="0.1.7"
GATEWAY_URL="http://127.0.0.1:18789"
GATEWAY_PORT=18789
SKIP_GATEWAY=false
SKIP_CAPABILITY_HUB=false
SKIP_MCP=false
EXECUTORS="CODEX"
STATE_PATH=""
LOG_DIR=""

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --vk-mode)          VK_MODE="$2"; shift 2 ;;
      --vk-api-base-url)  VK_API_BASE_URL="$2"; shift 2 ;;
      --vk-npx-version)   VK_NPX_VERSION="$2"; shift 2 ;;
      --gateway-url)      GATEWAY_URL="$2"; shift 2 ;;
      --gateway-port)     GATEWAY_PORT="$2"; shift 2 ;;
      --skip-gateway)     SKIP_GATEWAY=true; shift ;;
      --skip-capability-hub) SKIP_CAPABILITY_HUB=true; shift ;;
      --skip-mcp)         SKIP_MCP=true; shift ;;
      --executors)        EXECUTORS="$2"; shift 2 ;;
      --state-path)       STATE_PATH="$2"; shift 2 ;;
      --log-dir)          LOG_DIR="$2"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  VK_API_BASE_URL="${VK_API_BASE_URL%/}"
  GATEWAY_URL="${GATEWAY_URL%/}"

  local hub_d
  hub_d="$(hub_dir)"

  [ -n "$LOG_DIR" ] || LOG_DIR="$hub_d/logs"
  [ -n "$STATE_PATH" ] || STATE_PATH="$hub_d/stack-processes.json"

  # Validate executors
  local count
  count="$(normalize_executors "$EXECUTORS" | wc -l | tr -d '[:space:]')"
  [ "$count" -gt 0 ] || die "At least one executor must be provided (e.g. --executors CODEX,CLAUDE_CODE)"
}

# ============================================================
# Health checks
# ============================================================
test_gateway_reachable() {
  test_http "$GATEWAY_URL/health" 2
}

test_vk_health() {
  test_http "$VK_API_BASE_URL/api/health" 2
}

test_hub_running() {
  local pid
  pid="$(find_process "openclaw-capability-hub.js")"
  [ -n "$pid" ]
}

# ============================================================
# Preflight checks
# ============================================================
run_preflight() {
  local issues=0

  log_info ""
  log_info "Preflight checks:"

  # Gateway
  if [ "$SKIP_GATEWAY" = true ]; then
    log_info "- OpenClaw gateway startup is skipped by parameter."
  elif test_gateway_reachable; then
    log_info "- OpenClaw gateway is already reachable."
  elif has_command openclaw; then
    log_info "- OpenClaw CLI is available."
  else
    log_error "- OpenClaw CLI not found. Install OpenClaw: curl -fsSL https://openclaw.ai/install.sh | bash"
    issues=$((issues + 1))
  fi

  # vibe-kanban
  if test_vk_health; then
    log_info "- vibe-kanban API is already reachable."
  elif [ "$VK_MODE" = "npx" ]; then
    if has_command node; then
      log_info "- Node.js runtime is available for npx startup."
    else
      log_error "- Node.js not found. Install Node.js 22+ and rerun."
      issues=$((issues + 1))
    fi
    if has_command npx; then
      log_info "- npx is available for vibe-kanban startup."
    else
      log_error "- npx not found. Install Node.js 22+ so 'npx' is on PATH."
      issues=$((issues + 1))
    fi
  fi

  # Capability Hub
  if [ "$SKIP_CAPABILITY_HUB" = true ]; then
    log_info "- Capability Hub startup is skipped by parameter."
  elif test_hub_running; then
    log_info "- Capability Hub is already running."
  elif has_command node; then
    log_info "- Node.js runtime is available for Capability Hub."
  else
    log_error "- Node.js not found. Install Node.js 22+ to start Capability Hub."
    issues=$((issues + 1))
  fi

  if [ "$issues" -gt 0 ]; then
    die "Startup preflight failed. Fix the $issues issue(s) above and rerun."
  fi

  log_info "- Result: all required prerequisites are available."
}

# ============================================================
# Start services
# ============================================================
start_gateway() {
  local gateway_pid=""
  local gateway_location=""

  if [ "$SKIP_GATEWAY" = true ]; then
    echo ""
    return
  fi

  if test_gateway_reachable; then
    gateway_location="already-running"
    echo ""
    return
  fi

  if ! has_command openclaw; then
    die "OpenClaw CLI is not available. Install OpenClaw and rerun."
  fi

  mkdir -p "$LOG_DIR"
  gateway_pid="$(start_background "$LOG_DIR" "openclaw-gateway" openclaw gateway --port "$GATEWAY_PORT" --verbose)"
  wait_for_health "$GATEWAY_URL/health" 30 "OpenClaw gateway"
  gateway_location="native"
  echo "$gateway_pid"
}

start_vibe_kanban() {
  if test_vk_health; then
    echo ""
    return
  fi

  require_command npx "Install Node.js 22+ so 'npx' is on PATH."
  mkdir -p "$LOG_DIR"

  local vk_port
  vk_port="$(echo "$VK_API_BASE_URL" | grep -oE ':[0-9]+' | tr -d ':' || echo "3001")"
  [ -n "$vk_port" ] || vk_port="3001"

  local vk_pid
  vk_pid="$(PORT=$vk_port start_background "$LOG_DIR" "vibe-kanban" npx -y "vibe-kanban@$VK_NPX_VERSION")"
  wait_for_health "$VK_API_BASE_URL/api/health" 120 "vibe-kanban"
  echo "$vk_pid"
}

start_capability_hub() {
  if [ "$SKIP_CAPABILITY_HUB" = true ]; then
    echo ""
    return
  fi

  local existing_pid
  existing_pid="$(find_process "openclaw-capability-hub.js")"
  if [ -n "$existing_pid" ]; then
    echo "$existing_pid"
    return
  fi

  local hub_d
  hub_d="$(hub_dir)"
  local hub_script="$hub_d/src/openclaw-capability-hub.js"
  [ -f "$hub_script" ] || die "Hub script not found: $hub_script"
  require_command node "Install Node.js 22+ to start Capability Hub."

  mkdir -p "$LOG_DIR"

  local token
  token="$(get_openclaw_gateway_token 2>/dev/null)" || true

  local hub_pid
  hub_pid="$(
    export OPENCLAW_GATEWAY_URL="$GATEWAY_URL"
    [ -n "$token" ] && export OPENCLAW_GATEWAY_TOKEN="$token"
    start_background "$LOG_DIR" "capability-hub" node "$hub_script"
  )"
  # Give the hub a moment to initialize
  sleep 2
  echo "$hub_pid"
}

inject_mcp() {
  if [ "$SKIP_MCP" = true ]; then return; fi

  local inject_script="$SCRIPT_DIR/vk-inject-mcp.sh"
  if [ ! -f "$inject_script" ]; then
    log_warn "Skip MCP injection: script not found: $inject_script"
    return
  fi

  if ! test_vk_health; then
    log_warn "Skip MCP injection: vibe-kanban API not reachable"
    return
  fi

  bash "$inject_script" \
    --vk-api-base-url "$VK_API_BASE_URL" \
    --executors "$EXECUTORS" \
    --mode merge \
    --gateway-url "$GATEWAY_URL"
}

# ============================================================
# Main
# ============================================================
main() {
  parse_args "$@"
  mkdir -p "$LOG_DIR"

  run_preflight

  local gateway_pid vk_pid hub_pid
  gateway_pid="$(start_gateway)"
  local token
  token="$(get_openclaw_gateway_token 2>/dev/null)" || true
  if [ -n "$token" ]; then
    local suffix="${token: -6}"
    log_info "Gateway token loaded (***${suffix})"
  fi

  vk_pid="$(start_vibe_kanban)"
  hub_pid="$(start_capability_hub)"
  inject_mcp

  local control_ui_url
  control_ui_url="$(get_control_ui_url "$GATEWAY_URL" "$token")"

  # Write state JSON
  jq -n \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg vm "$VK_MODE" \
    --arg gu "$GATEWAY_URL" \
    --arg cu "$control_ui_url" \
    --arg vk "$VK_API_BASE_URL" \
    --arg gp "$gateway_pid" \
    --arg vp "$vk_pid" \
    --arg hp "$hub_pid" \
    '{
      timestamp: $ts,
      vk_mode: $vm,
      gateway_url: $gu,
      control_ui_url: $cu,
      vk_api_base_url: $vk,
      pids: {
        gateway: (if $gp == "" then null else ($gp | tonumber) end),
        vibe_kanban: (if $vp == "" then null else ($vp | tonumber) end),
        capability_hub: (if $hp == "" then null else ($hp | tonumber) end)
      }
    }' > "$STATE_PATH"

  # Print summary
  echo ""
  log_info "Stack ready:"
  local gw_status="unreachable"
  test_gateway_reachable && gw_status="reachable"
  log_info "- Gateway: $GATEWAY_URL ($gw_status)"
  log_info "- Control UI: $control_ui_url"

  local vk_status="unhealthy"
  test_vk_health && vk_status="healthy"
  log_info "- vibe-kanban API: $VK_API_BASE_URL ($vk_status)"

  if [ -n "$hub_pid" ]; then
    log_info "- Capability Hub: pid=$hub_pid"
  else
    log_info "- Capability Hub: already running or disabled"
  fi

  log_info "- MCP inject executors: $EXECUTORS"
  log_info "- State file: $STATE_PATH"
}

main "$@"
