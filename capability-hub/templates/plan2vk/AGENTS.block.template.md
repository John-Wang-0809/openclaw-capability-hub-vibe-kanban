{{AGENTS_BEGIN}}
## M5 Dispatch Contract (Fallback / operator note)

Primary `/plan2vk` handling now lives in the workspace skill command at `skills/plan2vk/SKILL.md`.

This section is **not** the primary implementation anymore. Keep it only as a best-effort fallback note for prototype environments where the `/plan2vk` skill command is missing, stale, or has not refreshed yet.

When a plain user message starts with `/plan2vk ` **and the skill command is unavailable**:

1. Extract goal text after the prefix.
2. Decompose the goal into 1..10 subtasks (each subtask must include `title`; optional `description`).
3. Dispatch immediately without extra clarification when goal is actionable.
4. Preferred fallback path: if tool `cap.vk_plan_and_dispatch` exists, call it exactly once with `goal`, `subtasks`, and optional routing fields.
5. Secondary fallback path (when `cap.vk_plan_and_dispatch` is not available):
   - Write subtasks JSON to `{{SUBTASKS_FILE}}`.
   - Run `exec` exactly once with:
     `node "{{CLIENT_SCRIPT}}" --mode dispatch --gateway-url {{GATEWAY_URL}} --goal "<goal>" --subtasks-file "{{SUBTASKS_FILE}}" --trace-id openclaw-plan2vk --idempotency-key openclaw-plan2vk-<unix_ts>`
6. Reply with a concise summary including created task IDs and links.

For non-`/plan2vk` messages:

- Do not dispatch tasks.
- Continue normal assistant behavior.

If dispatch fails:

- First provide an error summary.
- Then provide one concrete retry step.
{{AGENTS_END}}
