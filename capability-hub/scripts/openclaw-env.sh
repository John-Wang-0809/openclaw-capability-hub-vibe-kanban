#!/usr/bin/env bash
# [IN]  resolve-openclaw-config.sh for config discovery and gateway token extraction
# [OUT] Exports OPENCLAW_GATEWAY_URL and OPENCLAW_GATEWAY_TOKEN in the current shell
# [POS] Unix equivalent of openclaw-env.ps1. Bootstraps local shell environment for
#       Capability Hub and other Gateway clients. Does not start the Gateway.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-config.sh
source "$SCRIPT_DIR/resolve-openclaw-config.sh"

main() {
  local gateway_url="${1:-http://127.0.0.1:18789}"
  local config_path="${2:-}"

  if [ -z "$config_path" ]; then
    config_path="$(resolve_openclaw_config)"
    log_info "Config resolved from native: $config_path"
  else
    [ -f "$config_path" ] || die "OpenClaw config not found: $config_path"
  fi

  local token
  token="$(jq -r '.gateway.auth.token // empty' < "$config_path")"
  if [ -z "$token" ]; then
    die "Missing gateway.auth.token in $config_path (run: openclaw configure --section gateway)"
  fi

  export OPENCLAW_GATEWAY_URL="$gateway_url"
  export OPENCLAW_GATEWAY_TOKEN="$token"

  local suffix="${token: -6}"
  log_info "OPENCLAW env set: OPENCLAW_GATEWAY_URL=$gateway_url, OPENCLAW_GATEWAY_TOKEN=***${suffix}"

  local control_ui_url
  control_ui_url="$(get_control_ui_url "$gateway_url" "$token")"
  log_info "Control UI URL: $control_ui_url"
}

# Only run main when executed directly (not when sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
