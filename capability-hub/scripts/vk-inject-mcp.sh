#!/usr/bin/env bash
# [IN]  _utils.sh for HTTP helpers, JSON, and config resolution
#       resolve-openclaw-config.sh for gateway token discovery
#       A reachable vibe-kanban MCP config API
# [OUT] Updates vibe-kanban MCP server configuration for each requested executor
# [POS] Unix equivalent of vk-inject-mcp.ps1. Adapts Capability Hub into vibe-kanban
#       MCP configuration. Does not start processes.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-config.sh
source "$SCRIPT_DIR/resolve-openclaw-config.sh"

main() {
  local vk_api_base_url="" executors="" mode="merge"
  local gateway_url="http://127.0.0.1:18789" gateway_token="" hub_key="openclaw_capability_hub"

  while [ $# -gt 0 ]; do
    case "$1" in
      --vk-api-base-url) vk_api_base_url="$2"; shift 2 ;;
      --executors)       executors="$2"; shift 2 ;;
      --mode)            mode="$2"; shift 2 ;;
      --gateway-url)     gateway_url="$2"; shift 2 ;;
      --gateway-token)   gateway_token="$2"; shift 2 ;;
      --hub-key)         hub_key="$2"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [ -n "$vk_api_base_url" ] || die "--vk-api-base-url is required"
  [ -n "$executors" ] || die "--executors is required"
  vk_api_base_url="${vk_api_base_url%/}"

  # Resolve gateway token if not provided
  if [ -z "$gateway_token" ]; then
    gateway_token="$(get_openclaw_gateway_token 2>/dev/null)" || true
    if [ -n "$gateway_token" ]; then
      local suffix="${gateway_token: -6}"
      log_info "Gateway token loaded (***${suffix})"
    fi
  fi

  # Build hub server entry
  local hub_script
  hub_script="$(cd "$SCRIPT_DIR/.." && pwd)/src/openclaw-capability-hub.js"

  local hub_env
  if [ -n "$gateway_token" ]; then
    hub_env="$(jq -n --arg url "$gateway_url" --arg tok "$gateway_token" \
      '{OPENCLAW_GATEWAY_URL:$url, OPENCLAW_GATEWAY_TOKEN:$tok}')"
  else
    hub_env="$(jq -n --arg url "$gateway_url" '{OPENCLAW_GATEWAY_URL:$url}')"
  fi

  local hub_server
  hub_server="$(jq -n --arg script "$hub_script" --argjson env "$hub_env" \
    '{command:"node", args:[$script], env:$env}')"

  # Process each executor
  local executor_list
  executor_list="$(normalize_executors "$executors")"

  while IFS= read -r executor; do
    [ -n "$executor" ] || continue

    local existing_servers="{}"
    if [ "$mode" = "merge" ]; then
      local get_response
      get_response="$(http_get "$vk_api_base_url/api/mcp-config?executor=$executor" 5)" || true
      if [ -n "$get_response" ]; then
        existing_servers="$(echo "$get_response" | jq '.data.mcp_config.servers // {}' 2>/dev/null)" || existing_servers="{}"
      fi
    fi

    local merged_servers
    merged_servers="$(echo "$existing_servers" | jq --arg key "$hub_key" --argjson srv "$hub_server" '. + {($key): $srv}')"

    local body
    body="$(jq -n --argjson servers "$merged_servers" '{servers:$servers}')"

    log_info "Applying MCP server '$hub_key' to executor=$executor (mode=$mode)..."
    local resp
    resp="$(http_post_json "$vk_api_base_url/api/mcp-config?executor=$executor" "$body")" || true

    if [ -n "$resp" ]; then
      local success
      success="$(echo "$resp" | jq -r '.success // false')"
      if [ "$success" = "true" ]; then
        log_info "OK"
      else
        local msg
        msg="$(echo "$resp" | jq -r '.message // "unknown error"')"
        log_error "ERROR: $msg"
      fi
    else
      log_error "ERROR: No response from vibe-kanban API"
    fi
  done <<< "$executor_list"
}

main "$@"
