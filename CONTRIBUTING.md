# Contributing

## Scope

- Keep this repository focused on the integration layer between OpenClaw, Capability Hub, and vibe-kanban.
- Do not add vendored mirrors, bulk research dumps, machine-local config snapshots, or runtime logs.
- Keep `README.md` as the operator runbook and `PRODUCT_ARCHITECTURE_DEEP_DIVE.md` as the engineering design document.

## Local setup

1. Install Node.js 18+.
2. Run `npm install` inside `capability-hub/`.
3. Copy `capability-hub/vk-bindings.json` to `capability-hub/vk-bindings.local.json`.
4. Fill the local project, repository, and workspace values in the local override file.

## Change policy

- Keep changes minimal and traceable.
- Update the relevant runbook or evidence file when behavior changes.
- Do not commit gateway tokens, tokenized dashboard URLs, raw logs, or local state snapshots.
- Preserve the current public interface names:
  - `/plan2vk <goal>`
  - `cap.vk_plan_and_dispatch(...)`
  - `scripts/m5-dispatch-client.js --mode dispatch ...`

## Verification

Run the most relevant checks before opening a pull request:

```powershell
cd capability-hub
npm run self-test
npm run verify:m5:skill
npm run verify:m5:tool
npm run verify:m5:e2e
```

If you change public documentation claims, make sure the retained evidence bundle still supports them.
