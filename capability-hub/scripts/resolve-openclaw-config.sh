#!/usr/bin/env bash
# [IN]  _utils.sh for resolve_config helper
# [OUT] Functions: resolve_openclaw_config, get_openclaw_gateway_token
# [POS] Unix equivalent of resolve-openclaw-config.ps1. On native Unix there is no
#       WSL/UNC complexity — the config is always at $HOME/.openclaw/openclaw.json.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_utils.sh
source "$SCRIPT_DIR/_utils.sh"

# Resolve the OpenClaw config file path.
# Outputs the path on stdout. Dies if not found.
resolve_openclaw_config() {
  resolve_config  # from _utils.sh
}

# Read the gateway auth token from the resolved OpenClaw config.
# Outputs the token on stdout (may be empty).
get_openclaw_gateway_token() {
  get_gateway_token  # from _utils.sh
}
