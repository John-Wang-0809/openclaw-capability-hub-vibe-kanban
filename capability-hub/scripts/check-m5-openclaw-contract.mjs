/**
 * [IN] Dependencies/Inputs:
 *  - OpenClaw config file: `~/.openclaw/openclaw.json` (or --config-path override).
 *  - `agents.defaults.workspace` field from the parsed config.
 *  - File system: `<workspace>/skills/<skillName>/SKILL.md` and `<workspace>/AGENTS.md`.
 *  - Optional: `openclaw` CLI available on PATH (gracefully skipped if absent).
 *  - CLI args: --config-path, --runtime, --output-path, --marker, --skill-name.
 * [OUT] Outputs:
 *  - JSON result object to stdout with keys: ok, checks, workspace_path, config_path, errors.
 *  - Optional JSON written to --output-path file.
 *  - Exit code 0 when ok=true, exit code 1 when ok=false.
 * [POS] Position in the system:
 *  - Cross-platform ESM replacement for check-m5-openclaw-contract.ps1 (304 lines).
 *  - M5.4 guardrail: validates that the /plan2vk skill is correctly installed in the
 *    OpenClaw workspace. Does NOT modify any files; read-only contract verification.
 *  - Imported by verify-m5-dispatch.mjs as a module to avoid subprocess overhead.
 *
 * Change warning: if output schema or check keys change, update verify-m5-dispatch.mjs
 * (which imports this module) and the module doc in scripts/. Update package.json
 * verify:m5:skill if invocation flags change.
 */

import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const DEFAULT_SKILL_NAME = 'plan2vk';
const DEFAULT_MARKER = '<!-- BEGIN openclaw-capability-hub-vibe-kanban:plan2vk -->';

// ---------------------------------------------------------------------------
// Arg parsing (matches m5-dispatch-client.js convention)
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) {
      out[key] = next;
      i += 1;
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

function parseJsonSafe(raw) {
  if (typeof raw !== 'string') return null;
  const normalized = raw.replace(/^\uFEFF/, '').trim();
  if (!normalized) return null;
  try {
    return JSON.parse(normalized);
  } catch {
    return null;
  }
}

function outputJson(value) {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
}

// ---------------------------------------------------------------------------
// File helpers
// ---------------------------------------------------------------------------

async function fileExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readTextSafe(filePath) {
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    return raw.replace(/^\uFEFF/, '');
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// openclaw CLI probe (optional — graceful skip)
// ---------------------------------------------------------------------------

async function probeOpenClawSkillListed(skillName) {
  try {
    const { stdout } = await execFileAsync('openclaw', ['skills', 'list'], {
      timeout: 10_000,
      encoding: 'utf8',
    });
    const lines = stdout.split(/\r?\n/);
    return lines.some((line) => new RegExp(`\\b${skillName}\\b`, 'i').test(line));
  } catch {
    // openclaw not available or command failed — treat as unknown
    return null;
  }
}

// ---------------------------------------------------------------------------
// Core contract check (exported for use by verify-m5-dispatch.mjs)
// ---------------------------------------------------------------------------

/**
 * Run all contract checks and return the result object.
 *
 * @param {object} options
 * @param {string} [options.configPath]   Override config file path.
 * @param {string} [options.skillName]    Skill directory name (default: "plan2vk").
 * @param {string} [options.marker]       AGENTS.md block marker to look for.
 * @returns {Promise<{
 *   ok: boolean,
 *   checks: {
 *     config_found: boolean,
 *     workspace_found: boolean,
 *     skill_file_exists: boolean,
 *     agents_block_exists: boolean,
 *     skill_listed: boolean|null,
 *   },
 *   workspace_path: string,
 *   config_path: string,
 *   errors: string[],
 * }>}
 */
export async function runContractCheck(options = {}) {
  const skillName = options.skillName ?? DEFAULT_SKILL_NAME;
  const marker = options.marker ?? DEFAULT_MARKER;
  const errors = [];

  const checks = {
    config_found: false,
    workspace_found: false,
    skill_file_exists: false,
    agents_block_exists: false,
    skill_listed: null,
  };

  let configPath = options.configPath ?? path.join(os.homedir(), '.openclaw', 'openclaw.json');
  let workspacePath = '';

  // --- Step 1: resolve and parse config ---
  const configExists = await fileExists(configPath);
  if (!configExists) {
    errors.push(`OpenClaw config not found: ${configPath}`);
    return { ok: false, checks, workspace_path: workspacePath, config_path: configPath, errors };
  }
  checks.config_found = true;

  const configRaw = await readTextSafe(configPath);
  const config = parseJsonSafe(configRaw);
  if (!config) {
    errors.push(`Failed to parse OpenClaw config JSON: ${configPath}`);
    return { ok: false, checks, workspace_path: workspacePath, config_path: configPath, errors };
  }

  // --- Step 2: extract workspace ---
  const workspaceRaw =
    config?.agents?.defaults?.workspace ??
    config?.workspace ??
    '';

  if (!workspaceRaw || typeof workspaceRaw !== 'string' || workspaceRaw.trim() === '') {
    errors.push('agents.defaults.workspace is missing or empty in OpenClaw config.');
    return { ok: false, checks, workspace_path: workspacePath, config_path: configPath, errors };
  }

  workspacePath = workspaceRaw.trim();
  const workspaceExists = await fileExists(workspacePath);
  if (!workspaceExists) {
    errors.push(`Workspace directory not found: ${workspacePath}`);
    return { ok: false, checks, workspace_path: workspacePath, config_path: configPath, errors };
  }
  checks.workspace_found = true;

  // --- Step 3: check SKILL.md exists ---
  const skillFilePath = path.join(workspacePath, 'skills', skillName, 'SKILL.md');
  const skillFileExists = await fileExists(skillFilePath);
  checks.skill_file_exists = skillFileExists;
  if (!skillFileExists) {
    errors.push(`SKILL.md not found: ${skillFilePath}`);
  }

  // --- Step 4: check AGENTS.md contains managed block marker ---
  const agentsPath = path.join(workspacePath, 'AGENTS.md');
  const agentsContent = await readTextSafe(agentsPath);
  if (agentsContent === null) {
    errors.push(`AGENTS.md not found or unreadable: ${agentsPath}`);
    checks.agents_block_exists = false;
  } else {
    const hasMarker = agentsContent.includes(marker);
    checks.agents_block_exists = hasMarker;
    if (!hasMarker) {
      errors.push(`AGENTS.md is missing managed block marker: ${marker}`);
    }
  }

  // --- Step 5: optional CLI probe ---
  checks.skill_listed = await probeOpenClawSkillListed(skillName);

  // ok = all required checks pass (skill_listed is optional/informational)
  const ok =
    checks.config_found &&
    checks.workspace_found &&
    checks.skill_file_exists &&
    checks.agents_block_exists;

  return { ok, checks, workspace_path: workspacePath, config_path: configPath, errors };
}

// ---------------------------------------------------------------------------
// CLI entry point
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));

  const options = {
    configPath: args['config-path'] || undefined,
    skillName: args['skill-name'] || DEFAULT_SKILL_NAME,
    marker: args['marker'] || DEFAULT_MARKER,
    // --runtime auto|native is accepted but ignored on Unix (PS1 parity)
  };

  const result = await runContractCheck(options);

  if (args['output-path']) {
    try {
      const dir = path.dirname(args['output-path']);
      await fs.mkdir(dir, { recursive: true });
      await fs.writeFile(
        args['output-path'],
        JSON.stringify(result, null, 2) + '\n',
        'utf8',
      );
    } catch (err) {
      result.errors.push(`Failed to write output file: ${err.message}`);
    }
  }

  outputJson(result);
  process.exit(result.ok ? 0 : 1);
}

// Run only when invoked directly (not when imported as a module)
const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isMain) {
  main().catch((err) => {
    outputJson({
      ok: false,
      checks: {
        config_found: false,
        workspace_found: false,
        skill_file_exists: false,
        agents_block_exists: false,
        skill_listed: null,
      },
      workspace_path: '',
      config_path: '',
      errors: [err instanceof Error ? err.message : String(err)],
    });
    process.exit(1);
  });
}
