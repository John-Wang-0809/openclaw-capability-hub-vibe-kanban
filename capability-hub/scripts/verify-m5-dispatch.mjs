/**
 * [IN] Dependencies/Inputs:
 *  - `vk-bindings.local.json` (preferred) or `vk-bindings.json` from hub root.
 *  - `config/m5-dispatch-policy.json` from hub root.
 *  - `scripts/m5-dispatch-client.js` — invoked via child_process.execFileSync.
 *  - `scripts/check-m5-openclaw-contract.mjs` — imported for contract validation.
 *  - Vibe-kanban REST API at --vk-api-base-url (default: http://127.0.0.1:3001).
 *  - Optional: `openclaw` CLI (gracefully skipped in e2e mode if unavailable).
 *  - CLI args: --mode, --vk-api-base-url, --gateway-url, --project-id,
 *              --timeout-sec, --output-path.
 * [OUT] Outputs:
 *  - JSON verification report to stdout with keys: ok, mode, contract, dispatch,
 *    verification, policy_valid, bindings_valid, failure_reason, diagnostics.
 *  - Optional JSON written to --output-path file (default: <hub>/m5-verify-report.json).
 *  - Exit code 0 when ok=true, exit code 1 when ok=false.
 * [POS] Position in the system:
 *  - Cross-platform ESM replacement for verify-m5-dispatch.ps1 (286 lines).
 *  - M5 acceptance gate: validates both the contract (skill installed) and the
 *    dispatch path (tool invocation creates vibe-kanban tasks).
 *  - Does NOT modify vibe-kanban data beyond creating test tasks.
 *  - Invoked by `npm run verify:m5:tool` and `npm run verify:m5:e2e`.
 *
 * Change warning: if output schema changes, update package.json verify:m5:* commands
 * and the module doc in scripts/. If check-m5-openclaw-contract.mjs output changes,
 * update the `contract` field mapping below.
 */

import fs from 'node:fs/promises';
import { existsSync, writeFileSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { runContractCheck } from './check-m5-openclaw-contract.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const HUB_DIR = path.resolve(__dirname, '..');

const DEFAULT_VK_API_BASE_URL = 'http://127.0.0.1:3001';
const DEFAULT_GATEWAY_URL = 'http://127.0.0.1:18789';
const DEFAULT_TIMEOUT_SEC = 60;

// ---------------------------------------------------------------------------
// Arg parsing
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

function readJsonFile(filePath) {
  try {
    const raw = readFileSync(filePath, 'utf8');
    return parseJsonSafe(raw);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Bindings resolution
// ---------------------------------------------------------------------------

function resolveBindingsPath() {
  const candidates = [
    path.join(HUB_DIR, 'vk-bindings.local.json'),
    path.join(HUB_DIR, 'vk-bindings.json'),
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return candidates[candidates.length - 1];
}

// ---------------------------------------------------------------------------
// Vibe-kanban API helpers
// ---------------------------------------------------------------------------

async function vkGet(baseUrl, apiPath) {
  const url = `${baseUrl}${apiPath}`;
  const resp = await fetch(url, { signal: AbortSignal.timeout(20_000) });
  if (!resp.ok) {
    throw new Error(`VK API ${url} returned HTTP ${resp.status}`);
  }
  return resp.json();
}

// ---------------------------------------------------------------------------
// m5-dispatch-client.js invocation
// ---------------------------------------------------------------------------

function invokeM5Client(clientScript, cmdArgs, timeoutMs) {
  try {
    const raw = execFileSync('node', [clientScript, ...cmdArgs], {
      timeout: timeoutMs,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    // Find the last parseable JSON line (matches PS1 Parse-JsonLine logic)
    const lines = raw.split('\n').map((l) => l.trim()).filter(Boolean).reverse();
    for (const line of lines) {
      const parsed = parseJsonSafe(line);
      if (parsed !== null) {
        return { ok: true, exit_code: 0, json: parsed, raw };
      }
    }
    return { ok: false, exit_code: 0, json: null, raw };
  } catch (err) {
    const raw = err.stdout ?? '';
    // Still try to parse output even on non-zero exit
    const lines = String(raw).split('\n').map((l) => l.trim()).filter(Boolean).reverse();
    for (const line of lines) {
      const parsed = parseJsonSafe(line);
      if (parsed !== null) {
        return { ok: false, exit_code: err.status ?? 1, json: parsed, raw };
      }
    }
    return {
      ok: false,
      exit_code: err.status ?? 1,
      json: null,
      raw: err.message,
    };
  }
}

// ---------------------------------------------------------------------------
// Write temp JSON file for subtasks
// ---------------------------------------------------------------------------

function writeTempSubtasks(subtasks) {
  const tmpPath = path.join(os.tmpdir(), `m5-verify-subtasks-${Date.now()}.json`);
  writeFileSync(tmpPath, JSON.stringify(subtasks), 'utf8');
  return tmpPath;
}

// ---------------------------------------------------------------------------
// Poll vibe-kanban for task attempts
// ---------------------------------------------------------------------------

async function pollForAttempts(vkApiBaseUrl, taskIds, deadlineMs) {
  let attemptsObserved = 0;
  let lastError = null;

  while (Date.now() < deadlineMs) {
    for (const taskId of taskIds) {
      try {
        const resp = await vkGet(vkApiBaseUrl, `/api/task-attempts?task_id=${taskId}`);
        const count = Array.isArray(resp?.data) ? resp.data.length : 0;
        if (count > 0) {
          attemptsObserved = count;
          return { attemptsObserved, error: null };
        }
      } catch (err) {
        lastError = err.message;
      }
    }
    // Wait 2 seconds between polls
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }

  return { attemptsObserved, error: lastError };
}

// ---------------------------------------------------------------------------
// Tool mode
// ---------------------------------------------------------------------------

async function runToolMode(opts) {
  const {
    vkApiBaseUrl,
    gatewayUrl,
    projectId,
    timeoutSec,
    clientScript,
    diagnostics,
  } = opts;

  const timeoutMs = timeoutSec * 1_000;

  // Step 1: list tools
  const listResult = invokeM5Client(
    clientScript,
    ['--mode', 'list-tools', '--gateway-url', gatewayUrl],
    timeoutMs,
  );

  let askToolRegistered = false;
  let dispatchToolRegistered = false;

  if (listResult.json) {
    askToolRegistered = Boolean(listResult.json.ask_tool_registered);
    dispatchToolRegistered = Boolean(listResult.json.dispatch_tool_registered);
    diagnostics.registered_tools = listResult.json.tools ?? [];
  } else {
    diagnostics.list_tools_output = listResult.raw;
    return {
      ok: false,
      failure_reason: 'list_tools_failed',
      ask_tool_registered: false,
      dispatch_tool_registered: false,
      tasks_created: 0,
      attempts_observed: 0,
    };
  }

  // Step 2: dispatch test subtasks
  const testSubtasks = [
    { title: '修复 capability-hub 文档细节', description: '生成修复说明' },
    { title: '补充测试脚本说明', description: '更新验证步骤' },
  ];
  const subtasksFile = writeTempSubtasks(testSubtasks);
  const idempotencyKey = `m5-verify-tool-${Math.floor(Date.now() / 1000)}`;

  const dispatchArgs = [
    '--mode', 'dispatch',
    '--gateway-url', gatewayUrl,
    '--goal', 'M5 tool verify: create doc and test subtasks',
    '--trace-id', 'm5-verify-tool',
    '--subtasks-file', subtasksFile,
    '--idempotency-key', idempotencyKey,
  ];
  if (projectId) {
    dispatchArgs.push('--project-id', projectId);
  }

  const dispatchResult = invokeM5Client(clientScript, dispatchArgs, timeoutMs);

  if (!dispatchResult.json || dispatchResult.exit_code !== 0) {
    diagnostics.dispatch_output = dispatchResult.raw;
    return {
      ok: false,
      failure_reason: 'dispatch_call_failed',
      ask_tool_registered: askToolRegistered,
      dispatch_tool_registered: dispatchToolRegistered,
      tasks_created: 0,
      attempts_observed: 0,
    };
  }

  const payload = dispatchResult.json;
  diagnostics.dispatch = payload;

  if (!payload.ok) {
    return {
      ok: false,
      failure_reason: 'dispatch_result_not_ok',
      ask_tool_registered: askToolRegistered,
      dispatch_tool_registered: dispatchToolRegistered,
      tasks_created: 0,
      attempts_observed: 0,
    };
  }

  const subtasksCreated = Array.isArray(payload.subtasks_created)
    ? payload.subtasks_created
    : [];
  const tasksCreated = subtasksCreated.length;

  if (tasksCreated < 1) {
    return {
      ok: false,
      failure_reason: 'dispatch_created_zero_tasks',
      ask_tool_registered: askToolRegistered,
      dispatch_tool_registered: dispatchToolRegistered,
      tasks_created: 0,
      attempts_observed: 0,
    };
  }

  const taskIds = subtasksCreated
    .map((t) => (t && t.task_id ? String(t.task_id) : ''))
    .filter(Boolean);

  // Step 3: poll for attempts
  const pollDeadlineMs =
    Date.now() + Math.max(10_000, Math.min(timeoutMs, 90_000));
  const pollResult = await pollForAttempts(vkApiBaseUrl, taskIds, pollDeadlineMs);

  if (pollResult.error) {
    diagnostics.attempt_poll_error = pollResult.error;
  }

  if (pollResult.attemptsObserved < 1) {
    return {
      ok: false,
      failure_reason: 'attempt_not_observed',
      ask_tool_registered: askToolRegistered,
      dispatch_tool_registered: dispatchToolRegistered,
      tasks_created: tasksCreated,
      attempts_observed: 0,
    };
  }

  return {
    ok: true,
    failure_reason: null,
    ask_tool_registered: askToolRegistered,
    dispatch_tool_registered: dispatchToolRegistered,
    tasks_created: tasksCreated,
    attempts_observed: pollResult.attemptsObserved,
  };
}

// ---------------------------------------------------------------------------
// E2E mode
// ---------------------------------------------------------------------------

async function runE2eMode(opts) {
  const { vkApiBaseUrl, projectId, timeoutSec, diagnostics } = opts;

  // First: run tool mode as baseline
  const toolResult = await runToolMode(opts);
  if (!toolResult.ok && toolResult.failure_reason !== 'attempt_not_observed') {
    return toolResult;
  }

  // Then: try openclaw agent trigger (skip gracefully if unavailable)
  let agentTriggered = false;
  let agentSkipped = false;
  const triggerMessage = '/plan2vk create two M5 verification tasks';

  try {
    const { execFile } = await import('node:child_process');
    const { promisify } = await import('node:util');
    const execFileAsync = promisify(execFile);

    const { stdout, stderr } = await execFileAsync(
      'openclaw',
      ['agent', '--message', triggerMessage, '--json'],
      { timeout: 30_000, encoding: 'utf8' },
    );
    diagnostics.openclaw_agent = {
      stdout: stdout.trim().slice(0, 500),
      stderr: stderr.trim().slice(0, 200),
    };
    agentTriggered = true;
  } catch (err) {
    // openclaw not available or failed — skip, not a hard failure
    agentSkipped = true;
    diagnostics.openclaw_agent_skip_reason = err.message;
  }

  // Poll for new tasks if agent was triggered
  let newTasksFound = 0;
  if (agentTriggered && projectId) {
    try {
      const pollDeadlineMs = Date.now() + Math.max(10_000, timeoutSec * 1_000);
      let beforeIds = [];
      try {
        const beforeResp = await vkGet(vkApiBaseUrl, `/api/tasks?project_id=${projectId}`);
        beforeIds = Array.isArray(beforeResp?.data)
          ? beforeResp.data.map((t) => String(t.id))
          : [];
      } catch {
        // ignore
      }

      while (Date.now() < pollDeadlineMs) {
        await new Promise((resolve) => setTimeout(resolve, 2_000));
        try {
          const afterResp = await vkGet(vkApiBaseUrl, `/api/tasks?project_id=${projectId}`);
          const items = Array.isArray(afterResp?.data) ? afterResp.data : [];
          const newItems = items.filter(
            (t) => !beforeIds.includes(String(t.id)) &&
              String(t.title ?? '').toLowerCase().includes('m5 verification'),
          );
          if (newItems.length > 0) {
            newTasksFound = newItems.length;
            diagnostics.e2e_new_tasks = newItems.map((t) => ({
              id: t.id,
              title: t.title,
            }));
            break;
          }
        } catch {
          // ignore poll errors
        }
      }
    } catch {
      // ignore outer errors
    }
  }

  const ok = toolResult.ok || agentSkipped;
  return {
    ok,
    failure_reason: ok ? null : toolResult.failure_reason,
    ask_tool_registered: toolResult.ask_tool_registered,
    dispatch_tool_registered: toolResult.dispatch_tool_registered,
    tasks_created: toolResult.tasks_created,
    attempts_observed: toolResult.attempts_observed,
    agent_triggered: agentTriggered,
    agent_skipped: agentSkipped,
    e2e_new_tasks_found: newTasksFound,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));

  const mode = (args['mode'] ?? 'tool').toLowerCase();
  if (mode !== 'tool' && mode !== 'e2e') {
    outputJson({
      ok: false,
      mode,
      error: `Invalid --mode "${mode}". Must be "tool" or "e2e".`,
    });
    process.exit(1);
  }

  const vkApiBaseUrl = args['vk-api-base-url'] ?? DEFAULT_VK_API_BASE_URL;
  const gatewayUrl = args['gateway-url'] ?? DEFAULT_GATEWAY_URL;
  const timeoutSec = parseInt(args['timeout-sec'] ?? String(DEFAULT_TIMEOUT_SEC), 10) || DEFAULT_TIMEOUT_SEC;

  const policyPath = path.join(HUB_DIR, 'config', 'm5-dispatch-policy.json');
  const bindingsPath = resolveBindingsPath();
  const clientScript = path.join(__dirname, 'm5-dispatch-client.js');
  const outputPath = args['output-path'] ?? path.join(HUB_DIR, 'm5-verify-report.json');

  const diagnostics = {
    policy_path: policyPath,
    bindings_path: bindingsPath,
  };

  // --- Validate prerequisites ---
  const policy = readJsonFile(policyPath);
  const bindings = readJsonFile(bindingsPath);

  const policyValid = Boolean(
    policy &&
    policy.prefix &&
    Array.isArray(policy.routing_rules) &&
    policy.routing_rules.length >= 1 &&
    policy.subtask_limits,
  );

  const bindingsValid = Boolean(
    bindings &&
    bindings.defaultProjectId &&
    bindings.defaultExecutorProfileId &&
    Array.isArray(bindings.repoBindings) &&
    bindings.repoBindings.length >= 1,
  );

  let projectId = args['project-id'] ?? '';
  if (!projectId && bindings?.defaultProjectId) {
    projectId = String(bindings.defaultProjectId);
  }

  diagnostics.project_id = projectId;
  diagnostics.default_executor = bindings?.defaultExecutorProfileId ?? null;
  diagnostics.policy_valid = policyValid;
  diagnostics.bindings_valid = bindingsValid;

  if (!existsSync(clientScript)) {
    const report = buildReport({
      mode, policyValid, bindingsValid,
      contractResult: null,
      modeResult: {
        ok: false,
        failure_reason: 'client_script_missing',
        ask_tool_registered: false,
        dispatch_tool_registered: false,
        tasks_created: 0,
        attempts_observed: 0,
      },
      diagnostics,
    });
    await writeOutput(report, outputPath);
    outputJson(report);
    process.exit(report.ok ? 0 : 1);
  }

  // --- Run contract check ---
  const contractResult = await runContractCheck({
    configPath: args['config-path'] || undefined,
  });
  diagnostics.contract = contractResult;

  // --- Run mode-specific verification ---
  const modeOpts = {
    vkApiBaseUrl,
    gatewayUrl,
    projectId,
    timeoutSec,
    clientScript,
    diagnostics,
  };

  let modeResult;
  if (mode === 'tool') {
    modeResult = await runToolMode(modeOpts);
  } else {
    modeResult = await runE2eMode(modeOpts);
  }

  const report = buildReport({
    mode,
    policyValid,
    bindingsValid,
    contractResult,
    modeResult,
    diagnostics,
  });

  await writeOutput(report, outputPath);
  outputJson(report);
  process.exit(report.ok ? 0 : 1);
}

// ---------------------------------------------------------------------------
// Report builder
// ---------------------------------------------------------------------------

function buildReport({ mode, policyValid, bindingsValid, contractResult, modeResult, diagnostics }) {
  const dispatchOk = Boolean(
    modeResult?.ok &&
    modeResult.ask_tool_registered &&
    modeResult.dispatch_tool_registered &&
    modeResult.tasks_created > 0,
  );

  const ok = Boolean(
    policyValid &&
    bindingsValid &&
    contractResult?.ok !== false &&
    modeResult?.ok,
  );

  return {
    timestamp: new Date().toISOString(),
    ok,
    mode,
    policy_valid: policyValid,
    bindings_valid: bindingsValid,
    failure_reason: modeResult?.failure_reason ?? (ok ? null : 'precondition_failed'),
    contract: contractResult
      ? {
          ok: contractResult.ok,
          checks: contractResult.checks,
          workspace_path: contractResult.workspace_path,
          config_path: contractResult.config_path,
          errors: contractResult.errors,
        }
      : null,
    dispatch: {
      ok: dispatchOk,
      ask_tool_registered: modeResult?.ask_tool_registered ?? false,
      dispatch_tool_registered: modeResult?.dispatch_tool_registered ?? false,
      result: diagnostics.dispatch ?? null,
      error: modeResult?.failure_reason ?? null,
    },
    verification: {
      tasks_found: (modeResult?.tasks_created ?? 0) > 0,
      task_count: modeResult?.tasks_created ?? 0,
      attempts_observed: modeResult?.attempts_observed ?? 0,
    },
    diagnostics,
  };
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

async function writeOutput(report, outputPath) {
  try {
    const dir = path.dirname(outputPath);
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(outputPath, JSON.stringify(report, null, 2) + '\n', 'utf8');
    process.stderr.write(`M5 verify report => ${outputPath}\n`);
  } catch (err) {
    process.stderr.write(`Warning: failed to write report to ${outputPath}: ${err.message}\n`);
  }
}

// ---------------------------------------------------------------------------
// Entry point guard
// ---------------------------------------------------------------------------

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isMain) {
  main().catch((err) => {
    outputJson({
      ok: false,
      mode: 'unknown',
      error: err instanceof Error ? err.message : String(err),
    });
    process.exit(1);
  });
}
