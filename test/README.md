# Test Harness: Multi-agent Dispatch

This directory contains a small public test harness for direct manual dispatch through the Capability Hub fallback client.

## Files

| Path | Responsibility |
|------|----------------|
| `subtasks.json` | Sample subtasks for manual dispatch tests |
| `multi-agent-dispatch.mjs` | Wrapper that resolves `capability-hub/scripts/m5-dispatch-client.js` relative to the repo root |

## Prerequisites

- Node.js available in your environment
- Capability Hub reachable through the OpenClaw gateway
- A valid vibe-kanban project ID
- A configured `capability-hub/vk-bindings.local.json` or equivalent runtime setup

## Usage

Run from the repository root:

```powershell
node .\test\multi-agent-dispatch.mjs `
  --project-id <your-project-id> `
  --goal "Multi-agent test dispatch" `
  --gateway-url http://127.0.0.1:18789 `
  --trace-id demo-multi-agent `
  --idempotency-key demo-multi-agent-1
```

The script forwards the request to `capability-hub/scripts/m5-dispatch-client.js` and prints the raw result to stdout.

## Notes

- executor routing is decided by the Capability Hub policy, not by this wrapper
- use a stable `--idempotency-key` if you want duplicate suppression for repeated tests
