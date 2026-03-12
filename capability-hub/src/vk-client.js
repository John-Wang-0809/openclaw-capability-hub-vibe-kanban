/**
 * [IN] Dependencies/Inputs:
 *  - Node.js fetch/fs/path/crypto runtime.
 *  - Local config files: vk-bindings.local.json (preferred) or vk-bindings.json, plus config/m5-dispatch-policy.json.
 *  - vibe-kanban HTTP API: /api/projects/{id}/repositories, /api/tasks/create-and-start, /api/task-attempts.
 * [OUT] Outputs:
 *  - createM5DispatchService(): dispatcher for M5 reverse orchestration.
 *  - Dispatch result payload with parent/subtask/assist ids, warnings, and structured errors.
 * [POS] Position in the system:
 *  - Capability Hub internal adapter for M5 dispatch flow.
 *  - Owns vk API calls, routing policy execution, idempotency cache, and dispatch logs.
 */
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_VK_API_BASE_URL = "http://127.0.0.1:3001";
const DEFAULT_TTL_MS = 30 * 60 * 1000;
const DEFAULT_TIMEOUT_MS = 20_000;
const DEFAULT_RETRY_COUNT = 2;

function nowIso() {
  return new Date().toISOString();
}

function normalizeBaseUrl(raw, fallback = null) {
  const value = String(raw ?? "").trim();
  if (!value) return fallback;
  try {
    return new URL(value).toString().replace(/\/+$/, "");
  } catch {
    return fallback;
  }
}

function toCleanString(value) {
  return typeof value === "string" ? value.trim() : "";
}

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function readJsonFile(filePath, fallbackValue) {
  try {
    const raw = await fs.readFile(filePath, "utf8");
    const normalized = String(raw).replace(/^\uFEFF/, "");
    return JSON.parse(normalized);
  } catch {
    return fallbackValue;
  }
}

async function writeJsonFile(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function appendJsonl(filePath, lineValue) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const line = `${JSON.stringify(lineValue)}\n`;
  await fs.appendFile(filePath, line, "utf8");
}

async function resolveFirstExistingFilePath(filePaths, fallbackPath) {
  for (const filePath of ensureArray(filePaths)) {
    try {
      await fs.access(filePath);
      return filePath;
    } catch {
      continue;
    }
  }
  return fallbackPath;
}

function resolveTaskId(createTaskResponseData) {
  if (isObject(createTaskResponseData) && typeof createTaskResponseData.id === "string") {
    return createTaskResponseData.id;
  }
  if (
    isObject(createTaskResponseData) &&
    isObject(createTaskResponseData.task) &&
    typeof createTaskResponseData.task.id === "string"
  ) {
    return createTaskResponseData.task.id;
  }
  return null;
}

function resolveWorkspaceId(taskAttemptsData) {
  const attempts = ensureArray(taskAttemptsData);
  if (attempts.length < 1 || !isObject(attempts[0])) return null;
  if (typeof attempts[0].workspace_id === "string") return attempts[0].workspace_id;
  if (typeof attempts[0].workspaceId === "string") return attempts[0].workspaceId;
  return null;
}

function resolveLink(uiBaseUrl, projectId, taskId) {
  if (!uiBaseUrl || !projectId || !taskId) return null;
  return `${uiBaseUrl}/projects/${projectId}/tasks/${taskId}`;
}

function compileRoutingRules(policyRules) {
  return ensureArray(policyRules)
    .map((rule) => {
      const id = toCleanString(rule?.id) || "unnamed_rule";
      const pattern = toCleanString(rule?.pattern);
      const executor = toCleanString(rule?.executor);
      if (!pattern || !executor) return null;
      try {
        return { id, regex: new RegExp(pattern, "i"), executor };
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function pickExecutorForTask(compiledRules, defaultExecutor, task) {
  const title = toCleanString(task?.title);
  const description = toCleanString(task?.description);
  const source = `${title}\n${description}`;
  for (const rule of compiledRules) {
    if (rule.regex.test(source)) return rule.executor;
  }
  return defaultExecutor;
}

function buildRepoSpecs(repoIds, targetBranch) {
  return ensureArray(repoIds)
    .map((repoId) => toCleanString(repoId))
    .filter(Boolean)
    .map((repoId) => ({
      repo_id: repoId,
      target_branch: toCleanString(targetBranch) || "main",
    }));
}

function sanitizeSubtasks(rawSubtasks, minCount, maxCount) {
  const warnings = [];
  const errors = [];
  const all = ensureArray(rawSubtasks);
  if (all.length < minCount) {
    errors.push({ code: "invalid_input", message: `subtasks must contain at least ${minCount} items`, stage: "validate_subtasks" });
    return { subtasks: [], warnings, errors };
  }

  let sliced = all;
  if (all.length > maxCount) {
    sliced = all.slice(0, maxCount);
    warnings.push(`subtasks exceeded max=${maxCount}; truncated`);
  }

  const subtasks = [];
  sliced.forEach((item, index) => {
    const title = toCleanString(item?.title);
    const description = toCleanString(item?.description);
    if (!title) {
      errors.push({
        code: "invalid_input",
        message: `subtasks[${index}] missing title`,
        stage: "validate_subtasks",
      });
      return;
    }
    subtasks.push({ title, description });
  });

  if (subtasks.length < 1) {
    errors.push({ code: "invalid_input", message: "no valid subtasks after validation", stage: "validate_subtasks" });
  }
  return { subtasks, warnings, errors };
}

class VkApiClient {
  constructor({ baseUrl, timeoutMs = DEFAULT_TIMEOUT_MS, retryCount = DEFAULT_RETRY_COUNT }) {
    this.baseUrl = normalizeBaseUrl(baseUrl, DEFAULT_VK_API_BASE_URL);
    this.timeoutMs = timeoutMs;
    this.retryCount = retryCount;
  }

  async request(method, apiPath, body, stage) {
    const url = `${this.baseUrl}${apiPath}`;
    const payload = body ? JSON.stringify(body) : undefined;
    for (let attempt = 0; attempt <= this.retryCount; attempt += 1) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await fetch(url, {
          method,
          headers: {
            "Content-Type": "application/json",
          },
          body: payload,
          signal: controller.signal,
        });

        const rawText = await response.text();
        let parsed = null;
        if (rawText) {
          try {
            parsed = JSON.parse(rawText);
          } catch {
            parsed = null;
          }
        }

        if (!response.ok) {
          const message = parsed?.error || parsed?.message || `${response.status} ${response.statusText}`.trim();
          throw new Error(`vk_api_http_error stage=${stage} status=${response.status}: ${message}`);
        }

        if (isObject(parsed) && parsed.success === false) {
          const message = parsed?.error || "vibe-kanban returned success=false";
          throw new Error(`vk_api_business_error stage=${stage}: ${message}`);
        }

        if (isObject(parsed) && Object.prototype.hasOwnProperty.call(parsed, "data")) {
          return parsed.data;
        }
        return parsed;
      } catch (error) {
        const isLast = attempt >= this.retryCount;
        if (isLast) {
          const text = error instanceof Error ? error.message : String(error);
          throw new Error(`vk_api_request_failed stage=${stage}: ${text}`);
        }
        await sleep((attempt + 1) * 500);
      } finally {
        clearTimeout(timer);
      }
    }
    throw new Error(`vk_api_request_failed stage=${stage}: unknown`);
  }

  async getProjectRepositories(projectId) {
    return this.request("GET", `/api/projects/${encodeURIComponent(projectId)}/repositories`, null, "list_repositories");
  }

  async createAndStartTask(payload) {
    return this.request("POST", "/api/tasks/create-and-start", payload, "create_and_start");
  }

  async getTaskAttempts(taskId) {
    return this.request("GET", `/api/task-attempts?task_id=${encodeURIComponent(taskId)}`, null, "task_attempts");
  }
}

function createResultSkeleton(dispatchId, projectId) {
  return {
    ok: false,
    dispatch_id: dispatchId,
    project_id: projectId ?? null,
    parent_task_id: null,
    parent_workspace_id: null,
    subtasks_created: [],
    assist_task_id: null,
    warnings: [],
    errors: [],
    links: [],
  };
}

async function loadDispatchState(statePath) {
  const state = await readJsonFile(statePath, { version: "m5", records: {} });
  if (!isObject(state) || !isObject(state.records)) {
    return { version: "m5", records: {} };
  }
  return state;
}

function pruneExpiredState(state, nowMs) {
  const records = isObject(state.records) ? state.records : {};
  const next = {};
  for (const [key, value] of Object.entries(records)) {
    const expiresAt = Date.parse(value?.expires_at ?? "");
    if (Number.isFinite(expiresAt) && expiresAt > nowMs) {
      next[key] = value;
    }
  }
  state.records = next;
  return state;
}

export function createM5DispatchService(options = {}) {
  const srcDir = path.dirname(fileURLToPath(import.meta.url));
  const hubRoot = path.resolve(options.hubRoot ?? path.resolve(srcDir, ".."));
  const paths = {
    policyPath: path.join(hubRoot, "config", "m5-dispatch-policy.json"),
    bindingsPaths: [
      path.join(hubRoot, "vk-bindings.local.json"),
      path.join(hubRoot, "vk-bindings.json"),
    ],
    statePath: path.join(hubRoot, "m5-dispatch-state.json"),
    logPath: path.join(hubRoot, "m5-dispatch-log.jsonl"),
  };

  async function dispatch(rawArgs, context = {}) {
    const traceId = toCleanString(context.traceId) || crypto.randomUUID();
    const goal = toCleanString(rawArgs?.goal);
    const dispatchId = crypto.randomUUID();

    const bindingsPath = await resolveFirstExistingFilePath(
      paths.bindingsPaths,
      paths.bindingsPaths[paths.bindingsPaths.length - 1],
    );
    const bindings = await readJsonFile(bindingsPath, {});
    const policy = await readJsonFile(paths.policyPath, {});
    const defaultExecutor = toCleanString(bindings?.defaultExecutorProfileId);
    const projectId = toCleanString(rawArgs?.project_id) || toCleanString(bindings?.defaultProjectId);

    const result = createResultSkeleton(dispatchId, projectId);
    const limits = {
      min: Number.isFinite(policy?.subtask_limits?.min) ? Math.max(1, Math.floor(policy.subtask_limits.min)) : 1,
      max: Number.isFinite(policy?.subtask_limits?.max) ? Math.max(1, Math.floor(policy.subtask_limits.max)) : 10,
    };
    const compiledRules = compileRoutingRules(policy?.routing_rules);
    const repoIdsFromBindings = ensureArray(bindings?.repoBindings).map((x) => toCleanString(x?.repoId)).filter(Boolean);
    const targetBranchFromBindings = toCleanString(ensureArray(bindings?.repoBindings)[0]?.targetBranch) || "main";
    const repoIds = ensureArray(rawArgs?.repo_ids).map((x) => toCleanString(x)).filter(Boolean);
    const effectiveRepoIds = repoIds.length > 0 ? repoIds : repoIdsFromBindings;
    const effectiveTargetBranch = toCleanString(rawArgs?.target_branch) || targetBranchFromBindings;
    const repoSpecs = buildRepoSpecs(effectiveRepoIds, effectiveTargetBranch);
    const idempotencyKey =
      toCleanString(rawArgs?.idempotency_key) || toCleanString(context?.meta?.trace_id) || traceId;

    if (!goal) {
      result.errors.push({ code: "invalid_input", message: "goal is required", stage: "validate_input" });
      return result;
    }
    if (!projectId) {
      result.errors.push({ code: "invalid_input", message: "project_id is required", stage: "validate_input" });
      return result;
    }
    if (!defaultExecutor) {
      result.errors.push({ code: "invalid_input", message: "vk-bindings.defaultExecutorProfileId is required", stage: "validate_bindings" });
      return result;
    }
    if (repoSpecs.length < 1) {
      result.errors.push({ code: "invalid_input", message: "repo_ids or vk-bindings.repoBindings is required", stage: "validate_bindings" });
      return result;
    }

    const normalizedPrefix = toCleanString(policy?.prefix) || "/plan2vk";
    result.warnings.push(`prefix contract: ${normalizedPrefix}`);

    const sanitized = sanitizeSubtasks(rawArgs?.subtasks, limits.min, limits.max);
    result.warnings.push(...sanitized.warnings);
    result.errors.push(...sanitized.errors);
    if (result.errors.length > 0) {
      return result;
    }

    const nowMs = Date.now();
    const state = pruneExpiredState(await loadDispatchState(paths.statePath), nowMs);
    const cached = state.records[idempotencyKey];
    if (cached && isObject(cached.result)) {
      return {
        ...cached.result,
        warnings: [...ensureArray(cached.result.warnings), `idempotency cache hit: ${idempotencyKey}`],
      };
    }

    const vkApi = new VkApiClient({
      baseUrl: normalizeBaseUrl(bindings?.vkApiBaseUrl, DEFAULT_VK_API_BASE_URL),
    });
    const uiBase = normalizeBaseUrl(bindings?.vkUiBaseUrl, vkApi.baseUrl);

    try {
      await vkApi.getProjectRepositories(projectId);
    } catch (error) {
      result.errors.push({
        code: "temporary_failure",
        message: error instanceof Error ? error.message : String(error),
        stage: "validate_project_repositories",
      });
      return result;
    }

    try {
      const parentPayload = {
        task: {
          project_id: projectId,
          title: `[M5] Dispatch: ${goal.slice(0, 80)}`,
          description: `M5 reverse orchestration parent task.\nGoal:\n${goal}`,
        },
        executor_profile_id: { executor: defaultExecutor, variant: null },
        repos: repoSpecs,
      };
      const parentCreated = await vkApi.createAndStartTask(parentPayload);
      result.parent_task_id = resolveTaskId(parentCreated);
      if (!result.parent_task_id) {
        throw new Error("Unable to resolve parent_task_id from create-and-start response");
      }
    } catch (error) {
      result.errors.push({
        code: "temporary_failure",
        message: error instanceof Error ? error.message : String(error),
        stage: "create_parent",
      });
      return result;
    }

    try {
      for (let i = 0; i < 5; i += 1) {
        const attempts = await vkApi.getTaskAttempts(result.parent_task_id);
        result.parent_workspace_id = resolveWorkspaceId(attempts);
        if (result.parent_workspace_id) break;
        await sleep(1000);
      }
      if (!result.parent_workspace_id) {
        result.warnings.push("parent workspace id not found yet; child tasks created without parent_workspace_id");
      }
    } catch (error) {
      result.warnings.push(`parent workspace lookup failed: ${error instanceof Error ? error.message : String(error)}`);
    }

    for (let i = 0; i < sanitized.subtasks.length; i += 1) {
      const task = sanitized.subtasks[i];
      const executor = pickExecutorForTask(compiledRules, defaultExecutor, task);
      const payload = {
        task: {
          project_id: projectId,
          title: task.title,
          description: task.description || `Derived from goal: ${goal}`,
          ...(result.parent_workspace_id ? { parent_workspace_id: result.parent_workspace_id } : {}),
        },
        executor_profile_id: { executor, variant: null },
        repos: repoSpecs,
      };
      try {
        const created = await vkApi.createAndStartTask(payload);
        const taskId = resolveTaskId(created);
        if (!taskId) {
          throw new Error("Unable to resolve subtask id from create-and-start response");
        }
        result.subtasks_created.push({ task_id: taskId, executor, title: task.title });
      } catch (error) {
        result.errors.push({
          code: "temporary_failure",
          message: error instanceof Error ? error.message : String(error),
          stage: `create_subtask_${i + 1}`,
        });
      }
    }

    const assistEnabled = rawArgs?.assist_planning !== false && policy?.assist?.enabled !== false;
    const assistExecutor = toCleanString(policy?.assist?.executor) || "CODEX";
    if (assistEnabled) {
      const assistPayload = {
        task: {
          project_id: projectId,
          title: `[M5 Assist] Planning support: ${goal.slice(0, 70)}`,
          description: `Provide planning assistance for goal:\n${goal}`,
          ...(result.parent_workspace_id ? { parent_workspace_id: result.parent_workspace_id } : {}),
        },
        executor_profile_id: { executor: assistExecutor, variant: null },
        repos: repoSpecs,
      };
      try {
        const assistCreated = await vkApi.createAndStartTask(assistPayload);
        result.assist_task_id = resolveTaskId(assistCreated);
      } catch (error) {
        result.warnings.push(`assist task failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    }

    const links = [];
    if (result.parent_task_id) {
      const parentLink = resolveLink(uiBase, projectId, result.parent_task_id);
      if (parentLink) links.push(parentLink);
    }
    result.subtasks_created.forEach((subtask) => {
      const link = resolveLink(uiBase, projectId, subtask.task_id);
      if (link) links.push(link);
    });
    if (result.assist_task_id) {
      const assistLink = resolveLink(uiBase, projectId, result.assist_task_id);
      if (assistLink) links.push(assistLink);
    }
    result.links = links;
    result.ok = result.subtasks_created.length > 0;
    if (!result.ok && result.errors.length < 1) {
      result.errors.push({ code: "temporary_failure", message: "no subtasks created", stage: "create_subtasks" });
    }

    const expiresAt = new Date(Date.now() + DEFAULT_TTL_MS).toISOString();
    state.records[idempotencyKey] = {
      expires_at: expiresAt,
      result,
    };
    await writeJsonFile(paths.statePath, state);
    await appendJsonl(paths.logPath, {
      timestamp: nowIso(),
      trace_id: traceId,
      dispatch_id: result.dispatch_id,
      idempotency_key: idempotencyKey,
      project_id: result.project_id,
      parent_task_id: result.parent_task_id,
      subtasks_created: result.subtasks_created.length,
      assist_task_id: result.assist_task_id,
      ok: result.ok,
      warnings: result.warnings,
      errors: result.errors,
    });

    return result;
  }

  return {
    paths,
    dispatch,
  };
}
