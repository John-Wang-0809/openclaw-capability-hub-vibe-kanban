# Third-Party and Related Projects

This repository packages the **integration layer** and curated evidence for a local OpenClaw + Capability Hub + vibe-kanban workflow.

It does **not** vendor or mirror the full upstream projects. You must obtain and run those separately.

## Related projects

- **OpenClaw** — chat runtime, gateway, and workspace skill host
- **vibe-kanban** — task backend, dashboard, and executor router

## npm dependencies

The Capability Hub module depends on third-party npm packages recorded in `capability-hub/package-lock.json`.
Those packages remain under their own licenses.

## Public-repo boundary

Excluded from this public repository:

- upstream source mirrors
- zip archives
- internal research dumps
- machine-local configuration
- raw logs, caches, and transient state history

The public repo keeps only the integration code, runbooks, selected tests, and a sanitized evidence bundle.
