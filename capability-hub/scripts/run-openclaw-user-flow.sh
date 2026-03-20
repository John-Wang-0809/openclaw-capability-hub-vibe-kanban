#!/usr/bin/env bash
# [IN]  resolve-openclaw-workspace.sh, start-openclaw-vk-stack.sh, ensure-plan2vk-skill.sh,
#       ensure-vk-bindings.sh, and local tool availability (node, npm, openclaw, jq)
# [OUT] Performs first-run bootstrap, starts the local stack, opens browser UIs,
#       and prints the next user action
# [POS] Unix equivalent of run-openclaw-user-flow.ps1. Public one-command entrypoint
#       for first-run and repeat-run user onboarding on macOS and Linux.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-workspace.sh
source "$SCRIPT_DIR/resolve-openclaw-workspace.sh"

# ============================================================
# Defaults
# ============================================================
VK_MODE="npx"
VK_API_BASE_URL="http://127.0.0.1:3001"
GATEWAY_URL="http://127.0.0.1:18789"
EXECUTORS="CODEX,CLAUDE_CODE"
NO_OPEN=false
SKIP_CONTROL_UI=false
SKIP_VIBE_DASHBOARD=false
RECONFIGURE=false
STATE_PATH=""

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --vk-mode)              VK_MODE="$2"; shift 2 ;;
      --vk-api-base-url)      VK_API_BASE_URL="$2"; shift 2 ;;
      --gateway-url)          GATEWAY_URL="$2"; shift 2 ;;
      --executors)            EXECUTORS="$2"; shift 2 ;;
      --no-open)              NO_OPEN=true; shift ;;
      --skip-control-ui)      SKIP_CONTROL_UI=true; shift ;;
      --skip-vibe-dashboard)  SKIP_VIBE_DASHBOARD=true; shift ;;
      --reconfigure)          RECONFIGURE=true; shift ;;
      --state-path)           STATE_PATH="$2"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  local hub_d
  hub_d="$(hub_dir)"
  [ -n "$STATE_PATH" ] || STATE_PATH="$hub_d/stack-processes.json"
}

# ============================================================
# Platform-specific tool installers
# ============================================================
install_node() {
  local os
  os="$(detect_os)"
  case "$os" in
    macos)
      if has_command brew; then
        log_info "Installing Node.js via Homebrew..."
        brew install node
      else
        die "Node.js is required. Install it from https://nodejs.org/ or install Homebrew first: https://brew.sh"
      fi
      ;;
    linux)
      if has_command apt-get; then
        log_info "Installing Node.js via apt..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
        sudo apt-get install -y nodejs
      elif has_command dnf; then
        log_info "Installing Node.js via dnf..."
        sudo dnf install -y nodejs
      else
        die "Node.js is required. Install it from https://nodejs.org/"
      fi
      ;;
    *) die "Node.js is required. Install it from https://nodejs.org/" ;;
  esac
}

install_openclaw() {
  log_info "Installing OpenClaw via official installer..."
  curl -fsSL https://openclaw.ai/install.sh | bash
}

install_jq() {
  local os
  os="$(detect_os)"
  case "$os" in
    macos)
      if has_command brew; then
        log_info "Installing jq via Homebrew..."
        brew install jq
      else
        die "jq is required. Install it: brew install jq (install Homebrew first: https://brew.sh)"
      fi
      ;;
    linux)
      if has_command apt-get; then
        log_info "Installing jq via apt..."
        sudo apt-get install -y jq
      elif has_command dnf; then
        log_info "Installing jq via dnf..."
        sudo dnf install -y jq
      else
        die "jq is required. Install it from https://jqlang.github.io/jq/download/"
      fi
      ;;
    *) die "jq is required. Install it from https://jqlang.github.io/jq/download/" ;;
  esac
}

ensure_tool() {
  local name="$1" check_cmd="$2" install_label="$3" install_fn="$4"

  if has_command "$check_cmd"; then return 0; fi

  log_warn "$name is not installed."
  if ! confirm_action "Install $install_label now? [y/N]"; then
    die "$name is required. Install it manually and rerun."
  fi

  "$install_fn"

  # Verify installation
  if ! has_command "$check_cmd"; then
    die "$name installation did not make '$check_cmd' available. Reopen your shell and rerun."
  fi
  log_info "$name is now available."
}

# ============================================================
# Bootstrap helpers
# ============================================================
ensure_external_tools() {
  ensure_tool "jq" "jq" "jq JSON processor" install_jq
  ensure_tool "Node.js" "node" "Node.js LTS" install_node
  ensure_tool "OpenClaw" "openclaw" "OpenClaw via official installer" install_openclaw
}

ensure_hub_dependencies() {
  local hub_d
  hub_d="$(hub_dir)"
  local node_modules="$hub_d/node_modules"

  if [ -d "$node_modules" ]; then
    log_info "Capability Hub dependencies already exist; reusing them."
    return
  fi

  require_command npm "npm is required but not found. Install Node.js 22+."
  log_info "Installing Capability Hub dependencies..."
  (cd "$hub_d" && npm install --no-fund --no-audit)
}

# ============================================================
# Main flow
# ============================================================
main() {
  parse_args "$@"

  local hub_d
  hub_d="$(hub_dir)"

  log_info "Bootstrapping the local user flow..."

  # Step 1: Resolve workspace context (may fail if not configured yet)
  local workspace_context
  workspace_context="$(resolve_openclaw_workspace_context 2>/dev/null)" || workspace_context='{"ok":false}'

  # Step 2: Ensure external tools
  ensure_external_tools

  # Step 3: Re-resolve workspace if initial attempt failed (openclaw may have just been installed)
  local ws_ok
  ws_ok="$(echo "$workspace_context" | jq -r '.ok // false')"
  if [ "$ws_ok" != "true" ]; then
    workspace_context="$(resolve_openclaw_workspace_context)" || true
    ws_ok="$(echo "$workspace_context" | jq -r '.ok // false')"
    if [ "$ws_ok" != "true" ]; then
      die "OpenClaw is installed, but its workspace is not configured yet. Run 'openclaw configure' once, then rerun this command."
    fi
  fi

  local config_path
  config_path="$(echo "$workspace_context" | jq -r '.config_path')"
  local workspace_path
  workspace_path="$(echo "$workspace_context" | jq -r '.workspace_path')"

  # Step 4: Ensure Capability Hub dependencies
  ensure_hub_dependencies

  # Step 5: Ensure managed /plan2vk skill
  log_info "Ensuring the managed /plan2vk skill is installed..."
  local skill_result
  skill_result="$(bash "$SCRIPT_DIR/ensure-plan2vk-skill.sh" \
    --config-path "$config_path" \
    --gateway-url "$GATEWAY_URL" \
    --capability-hub-dir "$hub_d")" || true

  local skill_ok
  skill_ok="$(echo "$skill_result" | jq -r '.ok // false' 2>/dev/null)" || skill_ok="false"
  if [ "$skill_ok" != "true" ]; then
    log_error "Skill installation output: $skill_result"
    die "Failed to install or verify the managed /plan2vk skill."
  fi

  local skill_wp
  skill_wp="$(echo "$skill_result" | jq -r '.workspace_path // ""')"
  log_info "/plan2vk workspace ready: $skill_wp"

  local skill_changed
  skill_changed="$(echo "$skill_result" | jq -r '.skill_changed // false')"
  local agents_changed
  agents_changed="$(echo "$skill_result" | jq -r '.agents_changed // false')"
  local skill_state="already up to date"
  [ "$skill_changed" = "true" ] && skill_state="installed or updated"
  [ "$agents_changed" = "true" ] && skill_state="$skill_state; AGENTS fallback block synchronized"
  log_info "Skill status: $skill_state"

  # Step 6: Start the local stack
  echo ""
  log_info "Running preflight and starting the local stack..."
  bash "$SCRIPT_DIR/start-openclaw-vk-stack.sh" \
    --vk-mode "$VK_MODE" \
    --vk-api-base-url "$VK_API_BASE_URL" \
    --gateway-url "$GATEWAY_URL" \
    --executors "$EXECUTORS" \
    --state-path "$STATE_PATH"

  # Step 7: Ensure vibe-kanban bindings
  echo ""
  log_info "Finalizing persisted vibe-kanban bindings..."
  local bindings_args=(
    --config-path "$config_path"
    --vk-api-base-url "$VK_API_BASE_URL"
    --vk-ui-base-url "$VK_API_BASE_URL"
  )
  [ "$RECONFIGURE" = true ] && bindings_args+=(--reconfigure)

  local bindings_result
  bindings_result="$(bash "$SCRIPT_DIR/ensure-vk-bindings.sh" "${bindings_args[@]}")" || true

  local bindings_ok
  bindings_ok="$(echo "$bindings_result" | jq -r '.ok // false' 2>/dev/null)" || bindings_ok="false"
  if [ "$bindings_ok" != "true" ]; then
    die "The local stack started, but binding setup did not complete. Create or link a project in vibe-kanban at $VK_API_BASE_URL, then rerun."
  fi

  local sel_project sel_repo
  sel_project="$(echo "$bindings_result" | jq -r '.selected_project_name // ""')"
  sel_repo="$(echo "$bindings_result" | jq -r '.selected_repo_name // ""')"
  log_info "Using vibe-kanban binding: $sel_project / $sel_repo"

  local was_reconfigured
  was_reconfigured="$(echo "$bindings_result" | jq -r '.reconfigured // false')"
  if [ "$was_reconfigured" = "true" ]; then
    log_info "Binding choice was refreshed during this run."
  else
    log_info "Binding choice is saved for later runs."
  fi

  # Step 8: Open browser UIs
  if [ -f "$STATE_PATH" ]; then
    local control_ui_url
    control_ui_url="$(jq -r '.control_ui_url // ""' < "$STATE_PATH")"
    local vibe_dashboard_url="${VK_API_BASE_URL%/}"

    echo ""
    log_info "Opening the user workflow surfaces..."
    if [ "$SKIP_CONTROL_UI" != true ] && [ -n "$control_ui_url" ]; then
      if [ "$NO_OPEN" = true ]; then
        log_info "- OpenClaw Control UI: $control_ui_url"
      else
        open_url "$control_ui_url"
        log_info "Opened OpenClaw Control UI: $control_ui_url"
      fi
    fi

    if [ "$SKIP_VIBE_DASHBOARD" != true ]; then
      if [ "$NO_OPEN" = true ]; then
        log_info "- vibe-kanban dashboard: $vibe_dashboard_url"
      else
        open_url "$vibe_dashboard_url"
        log_info "Opened vibe-kanban dashboard: $vibe_dashboard_url"
      fi
    fi
  fi

  # Step 9: Print next steps
  echo ""
  log_info "Next step:"
  log_info "- In the OpenClaw Control UI chat, send: /plan2vk <your goal>"
  log_info "- Re-pick the remembered project/repository later with: bash $0 --reconfigure"
  log_info "- Stop the local stack later with: bash $SCRIPT_DIR/stop-openclaw-vk-stack.sh"
}

main "$@"
