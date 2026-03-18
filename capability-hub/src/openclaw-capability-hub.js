#!/usr/bin/env node
/**
 * [IN] Dependencies/Inputs:
 *  - OpenClaw Gateway tools-invoke HTTP endpoint and auth env vars.
 *  - Local Capability Hub config/state files (doc roots, M5 policy/bindings/state).
 *  - MCP stdio requests from executor runtimes (Codex/Claude Code/etc.).
 * [OUT] Outputs:
 *  - MCP tools: cap.web_search, cap.memory_search, cap.fetch_doc, cap.web_snapshot, cap.ask_user, cap.vk_plan_and_dispatch.
 *  - Structured MCP tool payloads with trace_id + hub_contract_version.
 * [POS] Position in the system:
 *  - Stdio MCP gateway/adapter layer between executors and OpenClaw/vibe-kanban capabilities.
 *  - It orchestrates tool calls but does not execute task business logic itself.
 */
import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import * as z from "zod/v4";
import {
  OpenClawGatewayError,
  createOpenClawGatewayClient,
  ensureTraceId,
  extractToolPayload,
} from "./openclaw-gateway.js";
import { createM5DispatchService } from "./vk-client.js";

const HUB_CONTRACT_VERSION = "0.1.0";

const server = new McpServer({
  name: "openclaw-capability-hub",
  version: HUB_CONTRACT_VERSION,
});

const MetaSchema = z
  .object({
    trace_id: z.string().optional(),
    hub_contract_version: z.string().optional(),
    project_id: z.string().optional(),
    task_id: z.string().optional(),
    attempt_id: z.string().optional(),
    workspace_id: z.string().optional(),
    executor: z.string().optional(),
    repo_paths: z.array(z.string()).optional(),
    user_session_key: z.string().optional(),
  })
  .passthrough();

const ErrorPayloadSchema = z
  .object({
    code: z.enum([
      "timeout",
      "policy_denied",
      "invalid_input",
      "temporary_failure",
      "not_supported",
    ]),
    message: z.string(),
    retryable: z.boolean(),
    suggested_next_action: z.string().optional(),
  })
  .passthrough();

function asToolResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    structuredContent: payload,
  };
}

function ok(traceId, extra) {
  return asToolResult({
    ok: true,
    trace_id: traceId,
    hub_contract_version: HUB_CONTRACT_VERSION,
    ...extra,
  });
}

function err(traceId, error) {
  return asToolResult({
    ok: false,
    trace_id: traceId,
    hub_contract_version: HUB_CONTRACT_VERSION,
    error,
  });
}

function mapGatewayError(traceId, e) {
  if (!(e instanceof OpenClawGatewayError)) {
    return err(traceId, {
      code: "temporary_failure",
      message: e instanceof Error ? e.message : String(e),
      retryable: true,
    });
  }
  const retryable = e.code === "timeout" || e.code === "temporary_failure";
  return err(traceId, {
    code: e.code,
    message: e.message,
    retryable,
  });
}

function normalizeRecencyDaysToFreshness(recencyDays) {
  if (typeof recencyDays !== "number" || !Number.isFinite(recencyDays)) return undefined;
  const d = Math.max(0, Math.floor(recencyDays));
  if (d <= 1) return "pd";
  if (d <= 7) return "pw";
  if (d <= 31) return "pm";
  if (d <= 366) return "py";
  return undefined;
}

function hostFromUrl(raw) {
  try {
    return new URL(raw).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function shouldKeepByDomain(url, includeDomains, excludeDomains) {
  const host = hostFromUrl(url);
  const inc = Array.isArray(includeDomains) ? includeDomains.map((d) => String(d).toLowerCase()) : [];
  const exc = Array.isArray(excludeDomains) ? excludeDomains.map((d) => String(d).toLowerCase()) : [];
  if (exc.length > 0 && host) {
    for (const d of exc) {
      if (!d) continue;
      if (host === d || host.endsWith(`.${d}`)) return false;
    }
  }
  if (inc.length > 0) {
    if (!host) return false;
    for (const d of inc) {
      if (!d) continue;
      if (host === d || host.endsWith(`.${d}`)) return true;
    }
    return false;
  }
  return true;
}

function extractMessageText(message) {
  const role = message && typeof message === "object" ? message.role : "";
  if (role !== "user" && role !== "assistant") return null;

  const content = message.content;
  if (typeof content === "string") return content.trim() ? content : null;
  if (!Array.isArray(content)) return null;

  const chunks = [];
  for (const block of content) {
    if (!block || typeof block !== "object") continue;
    if (block.type !== "text") continue;
    if (typeof block.text === "string" && block.text.trim()) chunks.push(block.text);
  }
  const joined = chunks.join("\n").trim();
  return joined ? joined : null;
}

function fingerprintMessage(msg) {
  try {
    return JSON.stringify(msg);
  } catch {
    return String(msg);
  }
}

function resolveAllowedDocRoots() {
  const raw = String(process.env.CAP_FETCH_DOC_ROOTS ?? "").trim();
  if (!raw) return [process.cwd()];
  return raw
    .split(";")
    .map((p) => p.trim())
    .filter(Boolean)
    .map((p) => path.resolve(p));
}

function isPathUnderAnyRoot(absPath, roots) {
  const normalized = path.resolve(absPath);
  for (const root of roots) {
    const rel = path.relative(root, normalized);
    if (!rel.startsWith("..") && !path.isAbsolute(rel)) {
      return true;
    }
  }
  return false;
}

const gateway = createOpenClawGatewayClient();
const m5DispatchService = createM5DispatchService();

server.registerTool(
  "cap.web_search",
  {
    description: "Search the web via OpenClaw (policy-governed).",
    inputSchema: {
      meta: MetaSchema.optional(),
      query: z.string(),
      recency_days: z.number().optional(),
      max_results: z.number().int().min(1).max(10).optional(),
      include_domains: z.array(z.string()).optional(),
      exclude_domains: z.array(z.string()).optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      results: z
        .array(
          z.object({
            title: z.string(),
            url: z.string(),
            snippet: z.string().optional(),
            why_relevant: z.string().optional(),
            published: z.string().optional(),
            site_name: z.string().optional(),
          }),
        )
        .optional(),
      error: ErrorPayloadSchema.optional(),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    try {
      const freshness = normalizeRecencyDaysToFreshness(args.recency_days);
      const count = typeof args.max_results === "number" ? args.max_results : 5;
      const sessionKey = args?.meta?.user_session_key || process.env.OPENCLAW_SESSION_KEY || undefined;

      const toolResult = await gateway.invokeTool({
        tool: "web_search",
        args: {
          query: args.query,
          count,
          ...(freshness ? { freshness } : {}),
        },
        sessionKey,
      });

      const payload = extractToolPayload(toolResult);
      if (!payload || typeof payload !== "object") {
        return err(traceId, {
          code: "temporary_failure",
          message: "web_search returned an invalid payload",
          retryable: true,
        });
      }

      if ("error" in payload && typeof payload.error === "string") {
        return err(traceId, {
          code: "temporary_failure",
          message: String(payload.message ?? payload.error),
          retryable: true,
          suggested_next_action: "configure OpenClaw web_search provider and retry",
        });
      }

      const rawResults = Array.isArray(payload.results) ? payload.results : [];
      const filtered = rawResults.filter((r) =>
        shouldKeepByDomain(r?.url, args.include_domains, args.exclude_domains),
      );

      const results = filtered.map((r) => ({
        title: typeof r?.title === "string" ? r.title : "",
        url: typeof r?.url === "string" ? r.url : "",
        snippet: typeof r?.description === "string" ? r.description : undefined,
        published: typeof r?.published === "string" ? r.published : undefined,
        site_name: typeof r?.siteName === "string" ? r.siteName : undefined,
      }));

      return ok(traceId, { results });
    } catch (e) {
      return mapGatewayError(traceId, e);
    }
  },
);

server.registerTool(
  "cap.memory_search",
  {
    description: "Search long-term memory via OpenClaw (policy-governed).",
    inputSchema: {
      meta: MetaSchema.optional(),
      query: z.string(),
      scope: z.string().optional(),
      top_k: z.number().int().min(1).max(20).optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      items: z
        .array(
          z.object({
            text: z.string(),
            source: z.string().optional(),
            score: z.number().optional(),
            path: z.string().optional(),
            from: z.number().optional(),
            to: z.number().optional(),
          }),
        )
        .optional(),
      error: ErrorPayloadSchema.optional(),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    try {
      const sessionKey = args?.meta?.user_session_key || process.env.OPENCLAW_SESSION_KEY || undefined;
      const maxResults = typeof args.top_k === "number" ? args.top_k : 5;
      const toolResult = await gateway.invokeTool({
        tool: "memory_search",
        args: {
          query: args.query,
          maxResults,
        },
        sessionKey,
      });

      const payload = extractToolPayload(toolResult);
      if (!payload || typeof payload !== "object") {
        return err(traceId, {
          code: "temporary_failure",
          message: "memory_search returned an invalid payload",
          retryable: true,
        });
      }

      if (payload.disabled === true) {
        return err(traceId, {
          code: "not_supported",
          message: typeof payload.error === "string" ? payload.error : "memory_search disabled",
          retryable: false,
        });
      }

      const results = Array.isArray(payload.results) ? payload.results : [];
      const items = results.map((r) => ({
        text: typeof r?.text === "string" ? r.text : "",
        source: "openclaw_memory",
        score: typeof r?.score === "number" ? r.score : undefined,
        path: typeof r?.path === "string" ? r.path : undefined,
        from: typeof r?.from === "number" ? r.from : undefined,
        to: typeof r?.to === "number" ? r.to : undefined,
      }));

      return ok(traceId, { items });
    } catch (e) {
      return mapGatewayError(traceId, e);
    }
  },
);

server.registerTool(
  "cap.fetch_doc",
  {
    description:
      "Read allowlisted local docs on the Hub host. Defaults to CAP_FETCH_DOC_ROOTS (or cwd).",
    inputSchema: {
      meta: MetaSchema.optional(),
      paths: z.array(z.string()).min(1),
      max_chars: z.number().int().min(1).max(200_000).optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      documents: z
        .array(
          z.object({
            path: z.string(),
            content_excerpt: z.string(),
            summary: z.string().optional(),
          }),
        )
        .optional(),
      error: ErrorPayloadSchema.optional(),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    try {
      const roots = resolveAllowedDocRoots();
      const maxChars = typeof args.max_chars === "number" ? args.max_chars : 20_000;
      const documents = [];

      for (const p of args.paths) {
        const abs = path.resolve(String(p));
        if (!isPathUnderAnyRoot(abs, roots)) {
          return err(traceId, {
            code: "policy_denied",
            message: `Path not allowlisted: ${abs}`,
            retryable: false,
          });
        }
        const buf = await fs.readFile(abs);
        const text = buf.toString("utf8");
        const firstLine = text.split(/\r?\n/, 1)[0]?.trim() ?? "";
        const summary =
          firstLine.startsWith("#") ? firstLine.replace(/^#+\s*/, "").trim() : firstLine;
        documents.push({
          path: abs,
          content_excerpt: text.length > maxChars ? `${text.slice(0, maxChars)}…` : text,
          ...(summary ? { summary } : {}),
        });
      }

      return ok(traceId, { documents });
    } catch (e) {
      return mapGatewayError(traceId, e);
    }
  },
);

server.registerTool(
  "cap.web_snapshot",
  {
    description:
      "Capture a web snapshot using OpenClaw browser (preferred) or web_fetch fallback.",
    inputSchema: {
      meta: MetaSchema.optional(),
      url: z.string().url(),
      goal: z.string().optional(),
      viewport: z.string().optional(),
      full_page: z.boolean().optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      summary: z.string().optional(),
      issues: z.array(z.string()).optional(),
      recommendations: z.array(z.string()).optional(),
      screenshots: z
        .array(
          z.object({
            path: z.string(),
            description: z.string().optional(),
          }),
        )
        .optional(),
      snapshot: z.string().optional(),
      error: ErrorPayloadSchema.optional(),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    const sessionKey = args?.meta?.user_session_key || process.env.OPENCLAW_SESSION_KEY || undefined;

    // Keep the browser interaction best-effort; web_fetch fallback provides a usable baseline.
    try {
      // Ensure browser is running (no-op if already started).
      await gateway.invokeTool({
        tool: "browser",
        action: "start",
        args: {},
        sessionKey,
      });

      const opened = await gateway.invokeTool({
        tool: "browser",
        action: "open",
        args: { targetUrl: args.url },
        sessionKey,
      });
      const openedPayload = extractToolPayload(opened);
      const targetId =
        openedPayload && typeof openedPayload === "object" && typeof openedPayload.targetId === "string"
          ? openedPayload.targetId
          : null;
      if (!targetId) {
        throw new Error("browser open did not return targetId");
      }

      const snapRes = await gateway.invokeTool({
        tool: "browser",
        action: "snapshot",
        args: {
          targetId,
          snapshotFormat: "ai",
          refs: "aria",
        },
        sessionKey,
      });
      const snapPayload = extractToolPayload(snapRes);
      const snapshotText =
        snapPayload && typeof snapPayload === "object" && typeof snapPayload.snapshot === "string"
          ? snapPayload.snapshot
          : null;

      const screenshotRes = await gateway.invokeTool({
        tool: "browser",
        action: "screenshot",
        args: {
          targetId,
          fullPage: args.full_page !== false,
          type: "png",
        },
        sessionKey,
      });

      const screenshotPath =
        screenshotRes &&
        typeof screenshotRes === "object" &&
        screenshotRes.details &&
        typeof screenshotRes.details.path === "string"
          ? screenshotRes.details.path
          : null;

      return ok(traceId, {
        summary: `Captured browser snapshot for ${args.url}`,
        issues: [],
        recommendations: [],
        screenshots: screenshotPath ? [{ path: screenshotPath, description: "Full page" }] : [],
        snapshot: snapshotText ?? undefined,
      });
    } catch (e) {
      try {
        const fetched = await gateway.invokeTool({
          tool: "web_fetch",
          args: { url: args.url, extractMode: "markdown", maxChars: 20_000 },
          sessionKey,
        });
        const payload = extractToolPayload(fetched);
        const text =
          payload && typeof payload === "object" && typeof payload.text === "string" ? payload.text : "";
        return ok(traceId, {
          summary: `Fetched page content for ${args.url} (web_fetch fallback; browser snapshot unavailable)`,
          issues: [],
          recommendations: [],
          screenshots: [],
          snapshot: text,
        });
      } catch (e2) {
        const mapped = mapGatewayError(traceId, e);
        const mapped2 = mapGatewayError(traceId, e2);
        const msg1 = mapped?.structuredContent?.error?.message ?? "";
        const msg2 = mapped2?.structuredContent?.error?.message ?? "";
        return msg2 && msg2 !== msg1 ? mapped2 : mapped;
      }
    }
  },
);

server.registerTool(
  "cap.vk_plan_and_dispatch",
  {
    description:
      "Dispatch a decomposed /plan2vk goal into vibe-kanban tasks with rule-based executor routing.",
    inputSchema: {
      meta: MetaSchema.optional(),
      goal: z.string(),
      subtasks: z.array(
        z.object({
          title: z.string(),
          description: z.string().optional(),
        }),
      ),
      project_id: z.string().optional(),
      repo_ids: z.array(z.string()).optional(),
      target_branch: z.string().optional(),
      assist_planning: z.boolean().optional(),
      idempotency_key: z.string().optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      dispatch_id: z.string(),
      project_id: z.string().nullable(),
      parent_task_id: z.string().nullable(),
      parent_workspace_id: z.string().nullable(),
      subtasks_created: z.array(
        z.object({
          task_id: z.string(),
          executor: z.string(),
          title: z.string(),
          route_type: z.string().optional(),
          confidence: z.number().nullable().optional(),
          reasoning: z.string().optional(),
        }),
      ),
      assist_task_id: z.string().nullable(),
      warnings: z.array(z.string()),
      errors: z.array(
        z.object({
          code: z.string(),
          message: z.string(),
          stage: z.string(),
        }),
      ),
      links: z.array(z.string()),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    try {
      const result = await m5DispatchService.dispatch(args, { traceId, meta: args?.meta });
      return asToolResult({
        trace_id: traceId,
        hub_contract_version: HUB_CONTRACT_VERSION,
        ...result,
      });
    } catch (e) {
      return asToolResult({
        ok: false,
        trace_id: traceId,
        hub_contract_version: HUB_CONTRACT_VERSION,
        dispatch_id: crypto.randomUUID(),
        project_id: null,
        parent_task_id: null,
        parent_workspace_id: null,
        subtasks_created: [],
        assist_task_id: null,
        warnings: [],
        errors: [
          {
            code: "temporary_failure",
            message: e instanceof Error ? e.message : String(e),
            stage: "vk_dispatch_runtime",
          },
        ],
        links: [],
      });
    }
  },
);

server.registerTool(
  "cap.ask_user",
  {
    description:
      "Ask the user a question via OpenClaw chat surface, then wait for the reply (polling session history).",
    inputSchema: {
      meta: MetaSchema.optional(),
      question: z.string(),
      context: z.string().optional(),
      choices: z.array(z.string()).optional(),
      default: z.string().optional(),
      timeout_seconds: z.number().int().min(1).max(3600).optional(),
    },
    outputSchema: {
      ok: z.boolean(),
      trace_id: z.string(),
      hub_contract_version: z.string(),
      answer: z.string().optional(),
      chosen: z.string().optional(),
      notes: z.string().optional(),
      error: ErrorPayloadSchema.optional(),
    },
  },
  async (args) => {
    const traceId = ensureTraceId(args?.meta);
    const sessionKey =
      args?.meta?.user_session_key || process.env.OPENCLAW_SESSION_KEY || undefined;
    if (!sessionKey) {
      return err(traceId, {
        code: "invalid_input",
        message: "cap.ask_user requires meta.user_session_key (or OPENCLAW_SESSION_KEY)",
        retryable: false,
      });
    }

    const timeoutSeconds =
      typeof args.timeout_seconds === "number" ? args.timeout_seconds : 900;
    const startedAt = Date.now();
    const pollEveryMs = 2000;

    try {
      const before = await gateway.invokeTool({
        tool: "sessions_history",
        args: { sessionKey, limit: 20, includeTools: false },
      });
      const beforePayload = extractToolPayload(before);
      const beforeMessages = Array.isArray(beforePayload?.messages) ? beforePayload.messages : [];
      const beforeLastUser = [...beforeMessages]
        .reverse()
        .find((m) => m && typeof m === "object" && m.role === "user");
      const beforeFingerprint = beforeLastUser ? fingerprintMessage(beforeLastUser) : null;

      const choiceText =
        Array.isArray(args.choices) && args.choices.length
          ? `\n\nChoices:\n- ${args.choices.join("\n- ")}`
          : "";
      const defaultText = args.default ? `\nDefault: ${args.default}` : "";
      const contextText = args.context ? `\n\nContext:\n${args.context}` : "";

      const prompt = [
        `Question (${traceId}):`,
        args.question,
        contextText,
        choiceText,
        defaultText,
        "\nReply with your answer (or one of the choices).",
      ]
        .join("\n")
        .trim();

      const list = await gateway.invokeTool({
        tool: "sessions_list",
        args: { limit: 500 },
      });
      const listPayload = extractToolPayload(list);
      const sessions = Array.isArray(listPayload?.sessions) ? listPayload.sessions : [];
      const match = sessions.find((s) => s && typeof s === "object" && s.key === sessionKey);
      const delivery =
        match && typeof match === "object" && match.deliveryContext && typeof match.deliveryContext === "object"
          ? match.deliveryContext
          : null;
      const channel =
        (delivery && typeof delivery.channel === "string" && delivery.channel) ||
        (match && typeof match.lastChannel === "string" ? match.lastChannel : "");
      const target =
        (delivery && typeof delivery.to === "string" && delivery.to) ||
        (match && typeof match.lastTo === "string" ? match.lastTo : "");
      const accountId =
        (delivery && typeof delivery.accountId === "string" && delivery.accountId) ||
        (match && typeof match.lastAccountId === "string" ? match.lastAccountId : "");

      if (!channel || !target) {
        return err(traceId, {
          code: "temporary_failure",
          message:
            "Unable to resolve delivery target for the user session. Ensure OpenClaw session has a chat/channel target.",
          retryable: true,
          suggested_next_action: "open OpenClaw chat session and retry cap.ask_user",
        });
      }

      await gateway.invokeTool({
        tool: "message",
        action: "send",
        args: {
          channel,
          target,
          ...(accountId ? { accountId } : {}),
          message: prompt,
        },
        sessionKey,
      });

      while (Date.now() - startedAt < timeoutSeconds * 1000) {
        await new Promise((r) => setTimeout(r, pollEveryMs));
        const hist = await gateway.invokeTool({
          tool: "sessions_history",
          args: { sessionKey, limit: 20, includeTools: false },
        });
        const histPayload = extractToolPayload(hist);
        const messages = Array.isArray(histPayload?.messages) ? histPayload.messages : [];
        const lastUser = [...messages]
          .reverse()
          .find((m) => m && typeof m === "object" && m.role === "user");
        if (!lastUser) continue;
        const fp = fingerprintMessage(lastUser);
        if (beforeFingerprint && fp === beforeFingerprint) continue;

        const answerText = extractMessageText(lastUser);
        if (!answerText) continue;

        let chosen = undefined;
        if (Array.isArray(args.choices) && args.choices.length) {
          const lowered = answerText.toLowerCase();
          const matchChoice = args.choices.find((c) => lowered.includes(String(c).toLowerCase()));
          if (matchChoice) chosen = matchChoice;
        }
        return ok(traceId, { answer: answerText, chosen });
      }

      return err(traceId, {
        code: "timeout",
        message: `Timed out waiting for user reply after ${timeoutSeconds}s`,
        retryable: true,
        suggested_next_action: args.default
          ? `use default=${args.default} or retry cap.ask_user`
          : "retry cap.ask_user",
      });
    } catch (e) {
      return mapGatewayError(traceId, e);
    }
  },
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    `openclaw-capability-hub (stdio MCP) running. gateway=${gateway.baseUrl} contract=${HUB_CONTRACT_VERSION}`,
  );
}

main().catch((e) => {
  const msg = e instanceof Error ? e.stack || e.message : String(e);
  console.error(`Hub server failed: ${msg}`);
  process.exit(1);
});
