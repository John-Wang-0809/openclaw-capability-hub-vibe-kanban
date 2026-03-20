#!/usr/bin/env bash
# [IN]  _utils.sh for logging, process management, and JSON helpers
#       stack-processes.json for PID state
# [OUT] Stops running stack processes (vibe-kanban, Capability Hub, optionally gateway)
# [POS] Unix equivalent of stop-openclaw-vk-stack.ps1. Reads PIDs from state file,
#       falls back to pgrep for best-effort cleanup.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_utils.sh
source "$SCRIPT_DIR/_utils.sh"

main() {
  local state_path=""
  local stop_gateway=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --state-path)   state_path="$2"; shift 2 ;;
      --stop-gateway) stop_gateway=true; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  local hub_dir
  hub_dir="$(hub_dir)"

  if [ -z "$state_path" ]; then
    state_path="$hub_dir/stack-processes.json"
  fi

  if [ ! -f "$state_path" ]; then
    log_warn "State file not found: $state_path"
    log_info "Trying best-effort cleanup for capability hub process..."
    local pid
    pid="$(find_process "openclaw-capability-hub.js")"
    if [ -n "$pid" ]; then
      stop_if_alive "$pid" "capability-hub"
    else
      log_info "No capability hub process found."
    fi
    return
  fi

  local vk_pid hub_pid gateway_pid
  vk_pid="$(jq -r '.pids.vibe_kanban // empty' < "$state_path" 2>/dev/null)" || true
  hub_pid="$(jq -r '.pids.capability_hub // empty' < "$state_path" 2>/dev/null)" || true
  gateway_pid="$(jq -r '.pids.gateway // empty' < "$state_path" 2>/dev/null)" || true

  [ -n "$vk_pid" ] && stop_if_alive "$vk_pid" "vibe-kanban"
  [ -n "$hub_pid" ] && stop_if_alive "$hub_pid" "capability-hub"

  if [ "$stop_gateway" = true ]; then
    if [ -n "$gateway_pid" ]; then
      stop_if_alive "$gateway_pid" "openclaw-gateway"
    else
      if has_command openclaw; then
        openclaw gateway stop 2>/dev/null || log_warn "Failed to stop gateway via CLI"
      fi
    fi
  else
    log_info "Gateway left running (pass --stop-gateway to stop it)."
  fi

  log_info "Stop script done."
}

main "$@"
