import crypto from "node:crypto";

/**
 * Minimal client for OpenClaw Gateway "Tools Invoke" API.
 *
 * Gateway docs:
 * - POST /tools/invoke
 * - Authorization: Bearer <token> (when gateway auth enabled)
 */

function normalizeBaseUrl(raw) {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return null;
  try {
    const url = new URL(trimmed);
    // Keep only scheme/host/port + any explicit path prefix, then strip trailing slashes.
    // (URL serialization always includes a "/" pathname, so strip it for stable joins.)
    const serialized = url.toString();
    return serialized.replace(/\/+$/, "");
  } catch {
    return null;
  }
}

function readIntEnv(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(String(raw), 10);
  return Number.isFinite(n) ? n : fallback;
}

export class OpenClawGatewayError extends Error {
  constructor(message, options) {
    super(message);
    this.name = "OpenClawGatewayError";
    this.code = options?.code ?? "temporary_failure";
    this.httpStatus = options?.httpStatus ?? null;
    this.details = options?.details ?? null;
  }
}

export function createOpenClawGatewayClient(options = {}) {
  const baseUrl =
    normalizeBaseUrl(options.baseUrl ?? process.env.OPENCLAW_GATEWAY_URL) ??
    "http://127.0.0.1:18789";

  const token = String(options.token ?? process.env.OPENCLAW_GATEWAY_TOKEN ?? "").trim() || null;

  const timeoutMs =
    typeof options.timeoutMs === "number" && Number.isFinite(options.timeoutMs)
      ? Math.max(1, Math.floor(options.timeoutMs))
      : readIntEnv("OPENCLAW_GATEWAY_TIMEOUT_MS", 20_000);

  async function invokeTool(params) {
    const tool = String(params?.tool ?? "").trim();
    if (!tool) {
      throw new OpenClawGatewayError("tools.invoke requires tool name", {
        code: "invalid_input",
      });
    }

    const body = {
      tool,
      action: params?.action ?? undefined,
      args:
        params?.args && typeof params.args === "object" && !Array.isArray(params.args)
          ? params.args
          : {},
      sessionKey: params?.sessionKey ?? undefined,
      dryRun: params?.dryRun ?? undefined,
    };

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(`${baseUrl}/tools/invoke`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });

      const text = await res.text();
      let json = null;
      if (text) {
        try {
          json = JSON.parse(text);
        } catch {
          // ignore; we'll return text as details
        }
      }

      if (!res.ok) {
        const message =
          (json && json.error && typeof json.error.message === "string" && json.error.message) ||
          `${res.status} ${res.statusText}`.trim();

        let code = "temporary_failure";
        if (res.status === 404) code = "not_supported";
        if (res.status === 401 || res.status === 403) code = "policy_denied";
        if (res.status === 400) code = "invalid_input";

        throw new OpenClawGatewayError(`OpenClaw gateway error: ${message}`, {
          code,
          httpStatus: res.status,
          details: json ?? text ?? null,
        });
      }

      const payload = json ?? { ok: true, result: text };
      if (!payload || typeof payload !== "object") {
        throw new OpenClawGatewayError("Invalid gateway response payload", {
          code: "temporary_failure",
          httpStatus: res.status,
          details: payload,
        });
      }

      if (payload.ok !== true) {
        const message =
          payload?.error && typeof payload.error.message === "string"
            ? payload.error.message
            : "Unknown tool error";
        const type = payload?.error && typeof payload.error.type === "string" ? payload.error.type : "";
        const code =
          type === "not_found" ? "not_supported" : type === "invalid_request" ? "invalid_input" : "temporary_failure";
        throw new OpenClawGatewayError(`OpenClaw tool error: ${message}`, {
          code,
          httpStatus: res.status,
          details: payload,
        });
      }

      return payload.result;
    } catch (err) {
      if (err instanceof OpenClawGatewayError) throw err;
      if (err?.name === "AbortError") {
        throw new OpenClawGatewayError("OpenClaw gateway request timed out", {
          code: "timeout",
        });
      }
      const message = err instanceof Error ? err.message : String(err);
      throw new OpenClawGatewayError(`OpenClaw gateway request failed: ${message}`, {
        code: "temporary_failure",
      });
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    baseUrl,
    token,
    timeoutMs,
    invokeTool,
  };
}

export function extractToolPayload(toolResult) {
  if (toolResult && typeof toolResult === "object" && "details" in toolResult) {
    const details = toolResult.details;
    if (details !== undefined) return details;
  }
  const content = toolResult && typeof toolResult === "object" ? toolResult.content : null;
  if (!Array.isArray(content)) return toolResult;
  const textBlock = content.find(
    (b) => b && typeof b === "object" && b.type === "text" && typeof b.text === "string",
  );
  const text = textBlock?.text;
  if (!text) return toolResult;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

export function ensureTraceId(meta) {
  const fromMeta = meta && typeof meta === "object" ? meta.trace_id : null;
  if (typeof fromMeta === "string" && fromMeta.trim()) return fromMeta.trim();
  return crypto.randomUUID();
}
