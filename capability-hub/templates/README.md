# Templates

- This directory stores repo-managed bootstrap templates for files that are installed into the user’s OpenClaw workspace.
- Templates here must stay machine-neutral; runtime-specific paths and URLs are injected by installer scripts.
- They support first-run bootstrap only and do not replace the live runtime scripts.
- If files are added or removed in this directory, or core responsibilities change, you must immediately update this file list.

## File List & Responsibilities

| Path | Responsibility |
|------|----------------|
| `plan2vk/SKILL.md.template` | Managed `/plan2vk` workspace skill template rendered with local paths and gateway URL |
| `plan2vk/AGENTS.block.template.md` | Managed fallback/operator block inserted into workspace `AGENTS.md` |
