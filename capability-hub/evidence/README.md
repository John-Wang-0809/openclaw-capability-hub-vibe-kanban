# Public Evidence Bundle

This directory contains the **selected public evidence** for the current verified system.

## Curation rules

- keep only the fields required to substantiate the public documentation claims
- redact local filesystem paths, task IDs, project IDs, repository IDs, session IDs, and dashboard links
- keep timestamps, decision paths, counts, warnings, and contract-level facts when they are needed
- do not store raw logs, JSONL event streams, or token-bearing state files here

## Files

| Path | Source | Purpose |
|------|--------|---------|
| `m5-tool-verification.json` | `m5-verify-report-tool.json` | Selected snapshot for the direct `cap.vk_plan_and_dispatch` tool path |
| `m5-chat-verification.json` | `m5-verify-report-e2e.json` | Selected snapshot for the `/plan2vk` chat path |
| `m5-timeout-hardening.json` | `m5-dispatch-log.jsonl`, `m5-dispatch-state.json`, `scripts/m5-dispatch-client.js` | Selected snapshot for the hardened fallback timeout contract and large-batch success case |

The raw local verification artifacts remain local-only and are intentionally excluded from the public repository.
