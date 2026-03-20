#!/usr/bin/env bash
# [IN]  resolve-openclaw-config.sh (and transitively _utils.sh) for config discovery
# [OUT] Function: resolve_openclaw_workspace_context — prints JSON workspace context
# [POS] Unix equivalent of resolve-openclaw-workspace.ps1. On native Unix there is no
#       WSL path conversion — workspace paths are used directly.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-config.sh
source "$SCRIPT_DIR/resolve-openclaw-config.sh"

# Resolve the OpenClaw workspace context.
# Accepts an optional config path as $1.
# Prints a JSON object to stdout with keys:
#   ok, error, config_path, config_source, workspace_raw, workspace_path, runtime_platform
resolve_openclaw_workspace_context() {
  local config_path="${1:-}"

  if [ -z "$config_path" ]; then
    config_path="$(resolve_openclaw_config)" || {
      jq -n '{ok:false, error:"OpenClaw config file was not found.", config_path:"", config_source:"", workspace_raw:"", workspace_path:"", runtime_platform:""}'
      return 1
    }
  fi

  if [ ! -f "$config_path" ]; then
    jq -n --arg p "$config_path" '{ok:false, error:("OpenClaw config not found: " + $p), config_path:$p, config_source:"manual", workspace_raw:"", workspace_path:"", runtime_platform:""}'
    return 1
  fi

  local workspace_raw
  workspace_raw="$(jq -r '.agents.defaults.workspace // empty' < "$config_path" 2>/dev/null)" || true

  if [ -z "$workspace_raw" ]; then
    jq -n --arg p "$config_path" '{ok:false, error:"OpenClaw config is missing agents.defaults.workspace.", config_path:$p, config_source:"native", workspace_raw:"", workspace_path:"", runtime_platform:""}'
    return 1
  fi

  jq -n \
    --arg cp "$config_path" \
    --arg wr "$workspace_raw" \
    '{ok:true, error:"", config_path:$cp, config_source:"native", workspace_raw:$wr, workspace_path:$wr, runtime_platform:"native"}'
}
