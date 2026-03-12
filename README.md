# openclaw-capability-hub-vibe-kanban

Public curated monorepo for the local integration layer between OpenClaw, Capability Hub, and vibe-kanban.

`README.md` is the operator runbook.
`PRODUCT_ARCHITECTURE_DEEP_DIVE.md` is the engineering theory/design document.

## Repository Boundary

This repository contains:

- the integration code in `capability-hub/`
- the public operator runbook and engineering deep dive
- a small manual test harness in `test/`
- a sanitized evidence bundle in `capability-hub/evidence/`

This repository does **not** contain:

- full upstream mirrors of OpenClaw or vibe-kanban
- local machine config snapshots
- tokenized dashboard URLs or runtime tokens
- raw runtime logs, caches, or transient state history
- bulk research notes and internal scratch material

If you need the upstream applications, install them separately and point this repo at your own local runtime.

## What Is Verified

- `cap.vk_plan_and_dispatch` dispatches already-decomposed subtasks into vibe-kanban.
- `/plan2vk <goal>` is treated as a workspace skill command in the verified chat path.
- The skill prefers the direct tool path and falls back to `write + exec -> scripts/m5-dispatch-client.js` when the dispatch tool is not visible.
- The fallback client ships with a `300000` ms default MCP timeout to avoid the old `60000` ms SDK boundary for larger batches.
- Public verification evidence is retained in `capability-hub/evidence/`.

## Documents

| Path | Purpose |
|------|---------|
| `README.md` | Public operator runbook |
| `PRODUCT_ARCHITECTURE_DEEP_DIVE.md` | Engineering architecture and formal system model |
| `capability-hub/README.md` | Module-level runbook for the Capability Hub |
| `capability-hub/evidence/README.md` | Explanation of the retained public evidence bundle |

## Repository Layout

| Path | Responsibility |
|------|----------------|
| `capability-hub/` | MCP bridge, dispatch runtime, startup scripts, verification scripts, and sanitized evidence |
| `test/` | Small manual test harness for direct multi-agent dispatch |

## Prerequisites

- Windows with PowerShell
- Node.js 18+
- OpenClaw CLI installed and configured
- A local OpenClaw workspace that contains the `/plan2vk` skill
- A reachable vibe-kanban backend

## Quick Start

### 1. Install Capability Hub dependencies

```powershell
cd capability-hub
npm install
```

### 2. Create your local bindings override

The tracked `capability-hub/vk-bindings.json` file is a template.
The runtime prefers `capability-hub/vk-bindings.local.json` when present.

```powershell
Copy-Item .\capability-hub\vk-bindings.json .\capability-hub\vk-bindings.local.json
```

Edit `capability-hub/vk-bindings.local.json` with your real values:

```json
{
  "vkUiBaseUrl": "http://127.0.0.1:3001",
  "defaultProjectId": "<your-project-id>",
  "repoBindings": [
    {
      "targetBranch": "main",
      "workspacePath": "C:\\path\\to\\your\\workspace",
      "repoId": "<your-repo-id>"
    }
  ],
  "vkApiBaseUrl": "http://127.0.0.1:3001",
  "defaultExecutorProfileId": "CLAUDE_CODE"
}
```

### 3. Start the stack

One-click user flow:

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\run-openclaw-user-flow.ps1
```

Manual stack startup:

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\start-openclaw-vk-stack.ps1 `
  -VkMode npx `
  -VkApiBaseUrl http://127.0.0.1:3001 `
  -GatewayUrl http://127.0.0.1:18789 `
  -Executors CODEX,CLAUDE_CODE
```

Use comma-delimited executor values when calling the PowerShell entry script through `powershell -File`.

### 4. Run the product flow

In OpenClaw chat, send:

```text
/plan2vk <your goal>
```

Expected high-level flow:

```text
OpenClaw chat
  -> workspace skill /plan2vk
  -> primary tool path or fallback exec path
  -> Capability Hub
  -> vibe-kanban
  -> executor profiles
```

### 5. Stop the stack

```powershell
powershell -ExecutionPolicy Bypass -File .\capability-hub\scripts\stop-openclaw-vk-stack.ps1
```

## Direct Fallback Dispatch

If you want to test the fallback path directly:

```powershell
cd capability-hub
node .\scripts\m5-dispatch-client.js `
  --mode dispatch `
  --gateway-url http://127.0.0.1:18789 `
  --project-id <your-project-id> `
  --goal "Create two verification tasks" `
  --subtasks-file ..\test\subtasks.json `
  --timeout-ms 300000 `
  --json
```

## Verification

Run the module checks from `capability-hub/`:

```powershell
cd capability-hub
npm run self-test
npm run verify:m5:skill
npm run verify:m5:tool
npm run verify:m5:e2e
```

Selected public evidence:

- `capability-hub/evidence/m5-tool-verification.json`
- `capability-hub/evidence/m5-chat-verification.json`
- `capability-hub/evidence/m5-timeout-hardening.json`

## Troubleshooting

### `unknown variant CODEX,CLAUDE_CODE`

Use the PowerShell script exactly with comma-delimited executors:

```powershell
-Executors CODEX,CLAUDE_CODE
```

### `disconnected (1008): unauthorized`

- open the tokenized Control UI URL printed by the stack scripts
- or set the gateway token in the Control UI settings
- or re-run `.\capability-hub\scripts\openclaw-env.ps1` to inspect the resolved gateway token inputs

### `MCP error -32001: Request timed out`

- retry with `--timeout-ms <larger-value>`
- or set `M5_DISPATCH_TIMEOUT_MS`
- verify that the dispatch tool is reachable and that vibe-kanban is healthy

## Public Evidence Policy

This public repository keeps a sanitized evidence bundle only.
Generated local reports such as raw JSONL streams, transient state snapshots, and token-bearing logs are intentionally excluded from git history.
