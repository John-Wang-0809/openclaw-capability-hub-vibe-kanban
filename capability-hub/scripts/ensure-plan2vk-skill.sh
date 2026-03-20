#!/usr/bin/env bash
# [IN]  resolve-openclaw-workspace.sh for workspace path resolution
#       Templates under capability-hub/templates/plan2vk/
#       check-m5-openclaw-contract.mjs for post-install verification
# [OUT] Installs/updates the managed skills/plan2vk/SKILL.md in the OpenClaw workspace
#       Updates AGENTS.md with the managed fallback block
#       Emits JSON summary to stdout
# [POS] Unix equivalent of ensure-plan2vk-skill.ps1. Bootstrap helper that turns the
#       repo-managed /plan2vk template into a workspace-local OpenClaw skill.
#
# Change warning: once you modify this file's logic, you must update this comment block,
# and check/update the module doc (README/CLAUDE) in the containing folder; update the root
# global map if necessary.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-openclaw-workspace.sh
source "$SCRIPT_DIR/resolve-openclaw-workspace.sh"

MANAGED_SKILL_MARKER="<!-- managed-by: openclaw-capability-hub-vibe-kanban /plan2vk -->"
MANAGED_AGENTS_BEGIN="<!-- BEGIN openclaw-capability-hub-vibe-kanban:plan2vk -->"
MANAGED_AGENTS_END="<!-- END openclaw-capability-hub-vibe-kanban:plan2vk -->"

main() {
  local config_path="" gateway_url="http://127.0.0.1:18789" capability_hub_dir="" output_path=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --config-path)        config_path="$2"; shift 2 ;;
      --gateway-url)        gateway_url="$2"; shift 2 ;;
      --capability-hub-dir) capability_hub_dir="$2"; shift 2 ;;
      --output-path)        output_path="$2"; shift 2 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [ -n "$capability_hub_dir" ] || capability_hub_dir="$(hub_dir)"
  local templates_dir="$capability_hub_dir/templates/plan2vk"
  local skill_template="$templates_dir/SKILL.md.template"
  local agents_template="$templates_dir/AGENTS.block.template.md"

  [ -f "$skill_template" ] || die "Managed skill template not found: $skill_template"
  [ -f "$agents_template" ] || die "Managed AGENTS template not found: $agents_template"

  # Resolve workspace
  local context_json
  context_json="$(resolve_openclaw_workspace_context "$config_path")"
  local ok
  ok="$(echo "$context_json" | jq -r '.ok')"
  [ "$ok" = "true" ] || die "$(echo "$context_json" | jq -r '.error')"

  local workspace_path
  workspace_path="$(echo "$context_json" | jq -r '.workspace_path')"
  local resolved_config_path
  resolved_config_path="$(echo "$context_json" | jq -r '.config_path')"

  # Compute runtime paths (no conversion needed on Unix)
  local hub_dir_abs
  hub_dir_abs="$(cd "$capability_hub_dir" && pwd)"
  local subtasks_file="$hub_dir_abs/plan2vk-subtasks.json"
  local client_script="$hub_dir_abs/scripts/m5-dispatch-client.js"

  # Render templates using sed substitution
  render_template() {
    local template_path="$1"
    local content
    content="$(cat "$template_path")"
    content="$(echo "$content" | sed \
      -e "s|{{MANAGED_MARKER}}|$MANAGED_SKILL_MARKER|g" \
      -e "s|{{HUB_DIR}}|$hub_dir_abs|g" \
      -e "s|{{GATEWAY_URL}}|$gateway_url|g" \
      -e "s|{{SUBTASKS_FILE}}|$subtasks_file|g" \
      -e "s|{{CLIENT_SCRIPT}}|$client_script|g" \
      -e "s|{{AGENTS_BEGIN}}|$MANAGED_AGENTS_BEGIN|g" \
      -e "s|{{AGENTS_END}}|$MANAGED_AGENTS_END|g")"
    echo "$content"
  }

  local rendered_skill rendered_agents_block
  rendered_skill="$(render_template "$skill_template")"
  rendered_agents_block="$(render_template "$agents_template")"

  # Determine target paths
  local skills_dir="$workspace_path/skills/plan2vk"
  local skill_path="$skills_dir/SKILL.md"
  local agents_path="$workspace_path/AGENTS.md"

  # Write skill file
  mkdir -p "$skills_dir"
  local skill_changed=false
  local existing_skill=""
  [ -f "$skill_path" ] && existing_skill="$(cat "$skill_path")"
  if [ "$existing_skill" != "$rendered_skill" ]; then
    # Backup if existing and not managed
    if [ -f "$skill_path" ] && ! grep -q "$MANAGED_SKILL_MARKER" "$skill_path" 2>/dev/null; then
      local timestamp
      timestamp="$(date +"%Y%m%d-%H%M%S")"
      cp "$skill_path" "$skill_path.backup.$timestamp"
    fi
    printf '%s' "$rendered_skill" > "$skill_path"
    skill_changed=true
  fi

  # Update AGENTS.md managed block
  local agents_changed=false
  local existing_agents=""
  [ -f "$agents_path" ] && existing_agents="$(cat "$agents_path")"

  local updated_agents
  if [ -z "$existing_agents" ]; then
    # No AGENTS.md — create one
    updated_agents="$(printf '# AGENTS.md - Workspace\n\n%s\n' "$rendered_agents_block")"
  elif echo "$existing_agents" | grep -q "$MANAGED_AGENTS_BEGIN"; then
    # Replace existing managed block using awk (more portable than multiline sed)
    updated_agents="$(echo "$existing_agents" | awk -v begin="$MANAGED_AGENTS_BEGIN" -v end="$MANAGED_AGENTS_END" -v block="$rendered_agents_block" '
      $0 == begin { printing=0; print block; next }
      $0 == end   { printing=1; next }
      printing!=0 { print }
      BEGIN { printing=1 }
    ')"
  else
    # Append managed block
    updated_agents="$(printf '%s\n\n%s\n' "$existing_agents" "$rendered_agents_block")"
  fi

  if [ "$existing_agents" != "$updated_agents" ]; then
    printf '%s' "$updated_agents" > "$agents_path"
    agents_changed=true
  fi

  # Verify contract (best effort)
  local contract_ok=true
  local contract_json='null'
  local contract_script="$SCRIPT_DIR/check-m5-openclaw-contract.mjs"
  if [ -f "$contract_script" ] && has_command node; then
    local attempts=5
    for i in $(seq 1 $attempts); do
      local result
      result="$(node "$contract_script" --config-path "$resolved_config_path" 2>/dev/null)" || true
      if [ -n "$result" ]; then
        local result_ok
        result_ok="$(echo "$result" | jq -r '.ok // false')" || true
        if [ "$result_ok" = "true" ]; then
          contract_json="$result"
          contract_ok=true
          break
        fi
        contract_json="$result"
        contract_ok=false
      fi
      [ "$i" -lt "$attempts" ] && sleep 1
    done
  fi

  # Emit result JSON
  local result_json
  result_json="$(jq -n \
    --argjson ok "$contract_ok" \
    --arg wp "$workspace_path" \
    --arg rp "native" \
    --arg sp "$skill_path" \
    --argjson sc "$skill_changed" \
    --arg ap "$agents_path" \
    --argjson ac "$agents_changed" \
    --argjson contract "$contract_json" \
    '{
      ok: $ok,
      workspace_path: $wp,
      runtime_platform: $rp,
      skill_path: $sp,
      skill_changed: $sc,
      agents_path: $ap,
      agents_changed: $ac,
      contract: $contract
    }')"

  if [ -n "$output_path" ]; then
    mkdir -p "$(dirname "$output_path")"
    echo "$result_json" > "$output_path"
  fi

  echo "$result_json"

  if [ "$contract_ok" != "true" ]; then
    exit 1
  fi
}

main "$@"
