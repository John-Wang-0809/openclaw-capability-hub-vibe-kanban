#!/usr/bin/env bash
# [IN]  resolve-openclaw-workspace.sh for workspace path resolution
#       A reachable vibe-kanban API exposing /api/projects and /api/projects/{id}/repositories
#       Optional existing vk-bindings.local.json
# [OUT] Creates/updates vk-bindings.local.json with persisted project/repo bindings
#       Emits JSON summary to stdout
# [POS] Unix equivalent of ensure-vk-bindings.ps1. Bootstrap helper that discovers
#       vibe-kanban projects, prompts user if needed, and persists the binding choice.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-workspace.sh
source "$SCRIPT_DIR/resolve-openclaw-workspace.sh"

main() {
  local config_path="" bindings_path="" vk_api_base_url="http://127.0.0.1:3001"
  local vk_ui_base_url="http://127.0.0.1:3001" default_executor="CLAUDE_CODE"
  local reconfigure=false output_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config-path)         config_path="$2"; shift 2 ;;
      --bindings-path)       bindings_path="$2"; shift 2 ;;
      --vk-api-base-url)     vk_api_base_url="$2"; shift 2 ;;
      --vk-ui-base-url)      vk_ui_base_url="$2"; shift 2 ;;
      --default-executor)    default_executor="$2"; shift 2 ;;
      --reconfigure)         reconfigure=true; shift ;;
      --output-path)         output_path="$2"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  local hub_d
  hub_d="$(hub_dir)"
  vk_api_base_url="${vk_api_base_url%/}"
  vk_ui_base_url="${vk_ui_base_url%/}"
  [ -n "$bindings_path" ] || bindings_path="$hub_d/vk-bindings.local.json"

  # Resolve workspace
  local context_json
  context_json="$(resolve_openclaw_workspace_context "$config_path")"
  local ok
  ok="$(echo "$context_json" | jq -r '.ok')"
  [ "$ok" = "true" ] || die "$(echo "$context_json" | jq -r '.error')"

  local workspace_path
  workspace_path="$(echo "$context_json" | jq -r '.workspace_path')"

  # Load existing bindings
  local existing_bindings='{}'
  if [ -f "$bindings_path" ]; then
    existing_bindings="$(cat "$bindings_path" | sed 's/^\xEF\xBB\xBF//' 2>/dev/null)" || existing_bindings='{}'
  fi

  # Fetch project/repo pairs from vibe-kanban API
  local pairs='[]'
  local projects_response
  projects_response="$(http_get "$vk_api_base_url/api/projects" 20)" || die "Failed to reach vibe-kanban API at $vk_api_base_url/api/projects"

  local projects
  projects="$(echo "$projects_response" | jq -r '.data // [] | .[] | .id' 2>/dev/null)" || true

  local pair_list='[]'
  while IFS= read -r project_id; do
    [ -n "$project_id" ] || continue
    local project_name
    project_name="$(echo "$projects_response" | jq -r --arg id "$project_id" '.data[] | select(.id == $id) | .name // "unnamed"')"

    local repos_response
    repos_response="$(http_get "$vk_api_base_url/api/projects/$project_id/repositories" 20)" || continue

    local repo_entries
    repo_entries="$(echo "$repos_response" | jq -c '.data // [] | .[]' 2>/dev/null)" || continue

    while IFS= read -r repo_json; do
      [ -n "$repo_json" ] || continue
      local repo_id repo_name repo_path
      repo_id="$(echo "$repo_json" | jq -r '.id // empty')"
      repo_name="$(echo "$repo_json" | jq -r '.display_name // .name // .path // "unnamed"')"
      repo_path="$(echo "$repo_json" | jq -r '.path // ""')"
      [ -n "$repo_id" ] || continue

      pair_list="$(echo "$pair_list" | jq --arg pi "$project_id" --arg pn "$project_name" \
        --arg ri "$repo_id" --arg rn "$repo_name" --arg rp "$repo_path" \
        '. + [{project_id:$pi, project_name:$pn, repo_id:$ri, repo_name:$rn, repo_path:$rp}]')"
    done <<< "$repo_entries"
  done <<< "$projects"

  local pair_count
  pair_count="$(echo "$pair_list" | jq 'length')"
  [ "$pair_count" -gt 0 ] || die "No usable vibe-kanban project/repository pair at $vk_api_base_url. Create a project with at least one repository, then rerun."

  # Try to match existing binding
  local selected_json=""
  if [ "$reconfigure" != true ] && [ -f "$bindings_path" ]; then
    local saved_project_id saved_repo_id
    saved_project_id="$(echo "$existing_bindings" | jq -r '.defaultProjectId // empty')"
    saved_repo_id="$(echo "$existing_bindings" | jq -r '.repoBindings[0].repoId // empty')"

    if [ -n "$saved_project_id" ] && [ -n "$saved_repo_id" ]; then
      selected_json="$(echo "$pair_list" | jq --arg pi "$saved_project_id" --arg ri "$saved_repo_id" \
        '[.[] | select(.project_id == $pi and .repo_id == $ri)] | .[0] // empty' 2>/dev/null)" || true
      if [ -n "$selected_json" ] && [ "$selected_json" != "null" ]; then
        local sn
        sn="$(echo "$selected_json" | jq -r '.project_name')"
        local rn
        rn="$(echo "$selected_json" | jq -r '.repo_name')"
        log_info "Reusing saved project/repository: $sn / $rn"
      else
        selected_json=""
      fi
    fi
  fi

  # Auto-select or prompt
  if [ -z "$selected_json" ] || [ "$selected_json" = "null" ]; then
    if [ "$pair_count" -eq 1 ]; then
      selected_json="$(echo "$pair_list" | jq '.[0]')"
      local sn rn
      sn="$(echo "$selected_json" | jq -r '.project_name')"
      rn="$(echo "$selected_json" | jq -r '.repo_name')"
      log_info "Auto-selected the only available project/repository: $sn / $rn"
    else
      echo ""
      log_info "Choose the vibe-kanban project/repository to remember for /plan2vk:"
      local i=1
      echo "$pair_list" | jq -r '.[] | "\(.project_name) / \(.repo_name)"' | while IFS= read -r label; do
        echo "  [$i] $label"
        i=$((i + 1))
      done

      while true; do
        printf "Enter a number (1-%s): " "$pair_count"
        read -r selection
        if [ -n "$selection" ] && [ "$selection" -ge 1 ] 2>/dev/null && [ "$selection" -le "$pair_count" ] 2>/dev/null; then
          local idx=$((selection - 1))
          selected_json="$(echo "$pair_list" | jq ".[$idx]")"
          break
        fi
        log_warn "Invalid selection. Enter one of the listed numbers."
      done
    fi
  fi

  # Get current git branch
  local target_branch="main"
  if [ -d "$workspace_path" ] && has_command git; then
    local branch
    branch="$(git -C "$workspace_path" branch --show-current 2>/dev/null)" || true
    [ -n "$branch" ] && target_branch="$branch"
  fi

  # Preserve existing executor if set
  local executor
  executor="$(echo "$existing_bindings" | jq -r '.defaultExecutorProfileId // empty')" || true
  [ -n "$executor" ] || executor="$default_executor"

  # Extract selected fields
  local sel_project_id sel_project_name sel_repo_id sel_repo_name
  sel_project_id="$(echo "$selected_json" | jq -r '.project_id')"
  sel_project_name="$(echo "$selected_json" | jq -r '.project_name')"
  sel_repo_id="$(echo "$selected_json" | jq -r '.repo_id')"
  sel_repo_name="$(echo "$selected_json" | jq -r '.repo_name')"

  # Write bindings file
  local bindings_json
  bindings_json="$(jq -n \
    --arg vui "$vk_ui_base_url" \
    --arg dpi "$sel_project_id" \
    --arg tb "$target_branch" \
    --arg wp "$workspace_path" \
    --arg ri "$sel_repo_id" \
    --arg vai "$vk_api_base_url" \
    --arg dep "$executor" \
    '{
      vkUiBaseUrl: $vui,
      defaultProjectId: $dpi,
      repoBindings: [{targetBranch:$tb, workspacePath:$wp, repoId:$ri}],
      vkApiBaseUrl: $vai,
      defaultExecutorProfileId: $dep
    }')"

  mkdir -p "$(dirname "$bindings_path")"
  echo "$bindings_json" > "$bindings_path"

  # Emit result JSON
  local result_json
  result_json="$(jq -n \
    --arg bp "$bindings_path" \
    --arg spi "$sel_project_id" \
    --arg spn "$sel_project_name" \
    --arg sri "$sel_repo_id" \
    --arg srn "$sel_repo_name" \
    --arg tb "$target_branch" \
    --arg wp "$workspace_path" \
    --argjson rc "$reconfigure" \
    '{
      ok: true,
      bindings_path: $bp,
      selected_project_id: $spi,
      selected_project_name: $spn,
      selected_repo_id: $sri,
      selected_repo_name: $srn,
      target_branch: $tb,
      workspace_path: $wp,
      reconfigured: $rc
    }')"

  if [ -n "$output_path" ]; then
    mkdir -p "$(dirname "$output_path")"
    echo "$result_json" > "$output_path"
  fi

  echo "$result_json"
}

main "$@"
