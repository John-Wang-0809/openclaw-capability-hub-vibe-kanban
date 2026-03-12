# Capability Hub Runbook

- This module exposes the MCP bridge between OpenClaw and vibe-kanban for the current verified integration stack.
- It owns tool proxying, reverse dispatch, startup/verification scripts, and the sanitized public evidence bundle.
- It does not replace the OpenClaw gateway or the vibe-kanban backend.
- If files are added or removed in this directory, or core responsibilities change, you must immediately update this file list.

## Module Boundaries

### What this module does

- exposes `cap.*` tools through `src/openclaw-capability-hub.js`
- bridges supported tool calls into the OpenClaw gateway
- dispatches vibe-kanban tasks through `cap.vk_plan_and_dispatch`
- provides startup, environment, injection, and verification scripts
- keeps a small public evidence bundle for the verified product claims

### What this module does not do

- it does not replace OpenClaw itself
- it does not replace the vibe-kanban backend or dashboard
- it does not own upstream source mirrors
- it does not publish machine-local tokens, raw logs, or transient state snapshots

## File List & Responsibilities

| Path | Responsibility |
|------|----------------|
| `src/` | Hub runtime source: MCP server entrypoint, gateway bridge, and vibe-kanban client |
| `scripts/` | Curated public scripts for startup, environment resolution, MCP injection, fallback dispatch, and verification |
| `config/` | Dispatch and approval policies used by the runtime |
| `evidence/` | Sanitized selected verification snapshots retained in the public repo |
| `package.json` | npm entrypoints for startup, self-test, and M5 verification |
| `package-lock.json` | Node dependency lockfile |
| `vk-bindings.json` | Tracked template config for project/repo bindings |
| `vk-bindings.local.json` | Ignored local override preferred by the runtime when present |

## Current Tool Surface

| Tool | Purpose |
|------|---------|
| `cap.web_search` | Web search proxy |
| `cap.memory_search` | Memory / knowledge search |
| `cap.web_snapshot` | Web snapshot capture |
| `cap.fetch_doc` | Local document fetch |
| `cap.ask_user` | Human approval / operator interaction |
| `cap.vk_plan_and_dispatch` | Reverse dispatch into vibe-kanban |

## Local Config Model

`vk-bindings.json` is the tracked template.
Create `vk-bindings.local.json` for your real local values. The runtime prefers the local override when it exists.

```powershell
Copy-Item .\vk-bindings.json .\vk-bindings.local.json
```

Template shape:

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

## Key Scripts

| Path | Responsibility |
|------|----------------|
| `scripts/openclaw-env.ps1` | Resolve and print effective OpenClaw gateway environment variables |
| `scripts/resolve-openclaw-config.ps1` | Discover OpenClaw config and token sources across Windows and WSL |
| `scripts/start-openclaw-vk-stack.ps1` | Start or reuse the gateway, vibe-kanban, and Capability Hub |
| `scripts/stop-openclaw-vk-stack.ps1` | Stop the local stack |
| `scripts/run-openclaw-user-flow.ps1` | One-command operator path that starts the stack and opens the main surfaces |
| `scripts/vk-inject-mcp.ps1` | Inject the Capability Hub MCP server into vibe-kanban |
| `scripts/check-m5-openclaw-contract.ps1` | Validate `/plan2vk` skill readiness and fallback visibility |
| `scripts/m5-dispatch-client.js` | Thin fallback MCP client for `cap.vk_plan_and_dispatch` |
| `scripts/verify-m5-dispatch.ps1` | Verify the M5 tool path or chat path |
| `scripts/self-test.js` | Lightweight hub connectivity self-test |

## Quick Start

### 1. Install dependencies

```powershell
cd capability-hub
npm install
```

### 2. Prepare local bindings

```powershell
Copy-Item .\vk-bindings.json .\vk-bindings.local.json
```

Fill your real project, repository, and workspace values in `vk-bindings.local.json`.

### 3. Start the hub only

```powershell
cd capability-hub
npm run start
```

If the gateway requires token auth, inspect the resolved values first:

```powershell
cd capability-hub
.\scripts\openclaw-env.ps1
```

### 4. Start the full local stack

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-openclaw-vk-stack.ps1 `
  -VkMode npx `
  -VkApiBaseUrl http://127.0.0.1:3001 `
  -GatewayUrl http://127.0.0.1:18789 `
  -Executors CODEX,CLAUDE_CODE
```

### 5. Run the product flow

Send `/plan2vk <goal>` from OpenClaw chat.

### 6. Stop the stack

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-openclaw-vk-stack.ps1
```

## Verification

Run the maintained checks from this directory:

```powershell
npm run self-test
npm run verify:m5:skill
npm run verify:m5:tool
npm run verify:m5:e2e
```

The generated raw verification outputs are local-only and not committed.
The public repo keeps sanitized selected snapshots in `evidence/`.

## Evidence Bundle

| Path | Meaning |
|------|---------|
| `evidence/m5-tool-verification.json` | Sanitized selected snapshot for the direct tool path |
| `evidence/m5-chat-verification.json` | Sanitized selected snapshot for the chat path via `/plan2vk` |
| `evidence/m5-timeout-hardening.json` | Sanitized selected snapshot for the hardened fallback timeout behavior |
| `evidence/README.md` | Scope, curation, and redaction rules for the public evidence set |

## Troubleshooting

### Gateway token mismatch

- use the tokenized Control UI URL printed by `start-openclaw-vk-stack.ps1`
- or inspect the resolved token inputs with `.\scripts\openclaw-env.ps1`

### Executor injection error

Use comma-delimited executors with `powershell -File` entrypoints:

```powershell
-Executors CODEX,CLAUDE_CODE
```

### Fallback timeout

If the fallback path is slow in your environment, increase the timeout:

```powershell
node .\scripts\m5-dispatch-client.js --mode dispatch --timeout-ms 300000
```

or set `M5_DISPATCH_TIMEOUT_MS`.

## Public Boundary Notes

This public repo intentionally excludes:

- `node_modules/`
- generated logs and JSONL streams
- transient state files
- token-bearing config snapshots
- internal milestone history outside the selected evidence bundle
