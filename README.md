# openclaw-capability-hub-vibe-kanban

This system turns a plain-language goal typed in chat into a set of tracked, assignable tasks that real executors (AI agents or humans) can pick up and work on.

It connects three components:

- **OpenClaw** — the chat interface where you type goals and receive results
- **Capability Hub** — a local bridge that receives your goal, breaks it into subtasks, routes each subtask to the right executor, and delivers results back to chat
- **vibe-kanban** — a task board that stores and displays every subtask so you can track progress visually

You type `/plan2vk <your goal>` in OpenClaw chat → Capability Hub decomposes it into subtasks and routes them → the tasks appear on your vibe-kanban board, ready for execution. This repository automates the setup of all three components with one command.

## How this system works

```
┌──────────┐    goal     ┌────────────────┐  subtasks  ┌─────────────┐
│ You      │ ──────────► │ OpenClaw       │ ─────────► │ Capability  │
│ (chat)   │             │ (chat gateway) │            │ Hub (bridge)│
└──────────┘             └────────────────┘            └──────┬──────┘
                                                              │
                                                    route & create tasks
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │ vibe-kanban │
                                                       │ (task board)│
                                                       └──────┬──────┘
                                                              │
                                                         assign tasks
                                                              │
                                                              ▼
                                                       ┌─────────────┐
                                                       │  Executors  │
                                                       │ (AI / human)│
                                                       └─────────────┘
```

1. **You** type a goal in OpenClaw chat (e.g. `/plan2vk build a login page`)
2. **OpenClaw** forwards the goal to Capability Hub via its gateway
3. **Capability Hub** decomposes the goal into subtasks, picks the best executor for each one, and creates them in vibe-kanban
4. **vibe-kanban** stores the tasks on a board where you (and executors) can track progress
5. **Executors** (Codex, Claude Code, or a human) pick up and complete the tasks

This repo bootstraps all three components locally so you can go from zero to a working pipeline in one command.

## What you can do with this repo

- bootstrap the local stack without hand-editing first-run config files
- let the script detect missing prerequisites and install supported Windows tools after one confirmation
- auto-install or update the managed `/plan2vk` skill in your OpenClaw workspace
- remember one vibe-kanban project/repository choice for later dispatches
- open the OpenClaw Control UI and the vibe-kanban dashboard and continue from chat

## First run

Run this command from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\run-openclaw-user-flow.ps1
```

On the first run, the script handles setup for you.

It will:

- check your OpenClaw workspace and local runtime state
- install Capability Hub dependencies inside `capability-hub\` when needed
- ask once before installing missing Windows tools such as Node.js LTS or OpenClaw
- install or update the managed `/plan2vk` skill in the detected OpenClaw workspace
- start or reuse OpenClaw, vibe-kanban, and Capability Hub
- auto-select the only available vibe-kanban project/repository, or ask once if there are multiple choices
- save that choice in `capability-hub/vk-bindings.local.json` so later runs can reuse it

## What the script may ask you once

The one-click flow is still intended to be low-touch, but it may pause in two cases:

- **Missing Windows tools**: it asks once before attempting to install Node.js LTS or OpenClaw
- **Multiple project/repository choices**: it asks once which vibe-kanban project/repository pair to remember

If there is only one valid project/repository pair, it does not ask and just saves it.

## After startup

When bootstrap and startup finish, the script:

- prints `Stack ready`
- shows the OpenClaw Control UI URL
- shows the vibe-kanban dashboard URL
- tells you the next chat action to send

Then send this in OpenClaw chat:

```text
/plan2vk <your goal>
```

## How to know it worked

The setup is healthy when all of the following are true:

- the output shows `Stack ready`
- the gateway is shown as `reachable`
- the vibe-kanban API is shown as `healthy`
- the script says which project/repository is being reused or was just selected
- the Control UI and dashboard open, or their URLs are printed

The end-to-end flow is healthy when:

- you send `/plan2vk <your goal>` in OpenClaw chat
- the chat returns dispatch information
- the new tasks appear in the vibe-kanban dashboard

## Reconfigure the remembered project or repository

If you want to choose a different vibe-kanban project/repository later, rerun the same command with `-Reconfigure`:

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\run-openclaw-user-flow.ps1 -Reconfigure
```

## If the script stops

The bootstrap is designed to fail with a specific next step instead of leaving you to guess.

Common stop points:

- **OpenClaw is installed but not configured yet**
  The script tells you to run `openclaw configure` once, then rerun the same command.

- **No supported Windows installer is available**
  The script tells you the exact tool that is missing and what to install manually.

- **vibe-kanban has no usable project/repository pair yet**
  Start the stack, create or link a project with at least one repository in vibe-kanban, then rerun the one-click command.

- **Gateway token mismatch / unauthorized**
  Open the tokenized Control UI URL printed by the script, or inspect the resolved token inputs with `.\capability-hub\scripts\openclaw-env.ps1`.

- **Fallback timeout**
  Increase `M5_DISPATCH_TIMEOUT_MS` or use a larger `--timeout-ms` value when testing the fallback client directly.

---

# For developers and contributors

Everything above this line is what you need to set up and use the system. The sections below cover advanced operation, verification, and engineering details.

## Advanced manual mode

Most users should stay on the one-click flow above.

Use the advanced starter only when you intentionally want to manage startup yourself:

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\start-openclaw-vk-stack.ps1 `
  -VkMode npx `
  -VkApiBaseUrl http://127.0.0.1:3001 `
  -GatewayUrl http://127.0.0.1:18789 `
  -Executors CODEX,CLAUDE_CODE
```

The advanced starter performs fail-fast preflight checks and stack startup, but it does **not** do the first-run bootstrap work that the one-click user-flow script now handles.

## How to confirm the flow works

Run the maintained checks from `capability-hub/`:

```powershell
cd capability-hub
npm run self-test
npm run verify:m5:skill
npm run verify:m5:tool
npm run verify:m5:e2e
```

## Further reading

- `PRODUCT_ARCHITECTURE_DEEP_DIVE.md` — engineering design and system model
- `capability-hub/README.md` — module-level runbook and bootstrap/startup details

## Recent changes

### P1: LLM-based task routing and structured dispatch tracing

The dispatch pipeline now supports two routing modes, configured in `capability-hub/config/m5-dispatch-policy.json`:

**LLM routing** (`routing_mode: "llm"`):
- Classifies all subtasks in a single LLM call using the Anthropic SDK
- Each executor has a semantic description; the model picks the best match per subtask
- Returns `route_type`, `confidence` (0.0–1.0), and `reasoning` for every subtask
- Supports `api_key` and `base_url` in the config file (for API proxies)
- Per-task fallback: if the LLM returns an unknown executor name, that subtask falls back to regex
- Global fallback: if the LLM call fails entirely (timeout, auth error, parse error), all subtasks fall back to regex

**Regex routing** (`routing_mode: "regex"`, default):
- Unchanged behavior from before; pattern-matches subtask titles against `routing_rules`

**Structured tracing**:
- Every dispatch produces a span tree written to `m5-dispatch-traces.jsonl`
- Spans cover: input validation, idempotency check, project validation, parent task creation, workspace resolution, routing decision, each subtask creation, and assist task creation
- Each span records `started_at`, `ended_at`, `duration_ms`, `status`, `input`, `output`, and `dotted_order`
- LLM routing spans additionally record `token_usage` (input/output tokens)
- The existing flat log (`m5-dispatch-log.jsonl`) gains three optional fields: `routing_mode`, `total_duration_ms`, `trace_file`
- Tracing is best-effort and never blocks the dispatch flow
