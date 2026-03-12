/**
 * [IN] Dependencies/Inputs:
 *  - Node.js runtime with @modelcontextprotocol/sdk client packages.
 *  - CLI args for list-tools / dispatch modes, M5 dispatch payload fields, and optional timeout override.
 *  - Capability Hub server script path and optional OPENCLAW_* env overrides.
 * [OUT] Outputs:
 *  - JSON line to stdout with tool discovery or `cap.vk_plan_and_dispatch` call result.
 *  - Exit code 0 on handled responses, non-zero for transport/runtime failures.
 * [POS] Position in the system:
 *  - Thin MCP client helper for M5 verification scripts.
 *  - Avoids embedding MCP stdio logic inside PowerShell verification code or `/plan2vk` fallback exec flows.
 */
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const DEFAULT_DISPATCH_TIMEOUT_MS = 5 * 60 * 1000;
const MIN_TIMEOUT_MS = 1_000;

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith("--")) {
      out[key] = next;
      i += 1;
    } else {
      out[key] = "true";
    }
  }
  return out;
}

function outputJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function parseJsonSafe(raw) {
  if (typeof raw !== "string") return null;
  const normalized = raw.replace(/^\uFEFF/, "").trim();
  if (!normalized) return null;
  try {
    return JSON.parse(normalized);
  } catch {
    return null;
  }
}

function extractStructuredContent(toolResult) {
  if (toolResult?.structuredContent && typeof toolResult.structuredContent === "object") {
    return toolResult.structuredContent;
  }
  if (!Array.isArray(toolResult?.content)) return null;
  const textPart = toolResult.content.find(
    (part) => part && typeof part === "object" && part.type === "text" && typeof part.text === "string",
  );
  return textPart ? parseJsonSafe(textPart.text) : null;
}

function parseTimeoutMs(raw) {
  if (raw === undefined || raw === null || raw === "") return DEFAULT_DISPATCH_TIMEOUT_MS;
  const parsed = Number.parseInt(String(raw), 10);
  if (!Number.isFinite(parsed) || parsed < MIN_TIMEOUT_MS) return null;
  return parsed;
}

async function resolveSubtasks(args) {
  if (args["subtasks-file"]) {
    const raw = await fs.readFile(args["subtasks-file"], "utf8");
    const parsed = parseJsonSafe(raw);
    return Array.isArray(parsed) ? parsed : null;
  }
  if (args["subtasks-json"]) {
    const parsed = parseJsonSafe(args["subtasks-json"]);
    return Array.isArray(parsed) ? parsed : null;
  }
  const goal = typeof args.goal === "string" ? args.goal.trim() : "";
  if (!goal) return null;
  return [{ title: goal.slice(0, 72), description: goal }];
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const mode = String(args.mode || "list-tools").toLowerCase();
  if (!["list-tools", "dispatch"].includes(mode)) {
    outputJson({ ok: false, error_code: "invalid_input", error_message: `Unsupported mode: ${mode}` });
    process.exit(2);
  }
  const timeoutMs = parseTimeoutMs(args["timeout-ms"] ?? process.env.M5_DISPATCH_TIMEOUT_MS);
  if (!timeoutMs) {
    outputJson({
      ok: false,
      error_code: "invalid_input",
      error_message: `--timeout-ms must be an integer >= ${MIN_TIMEOUT_MS}`,
    });
    process.exit(2);
  }

  const scriptDir = path.dirname(fileURLToPath(import.meta.url));
  const hubRoot = path.resolve(scriptDir, "..");
  const hubScript = path.resolve(hubRoot, "src", "openclaw-capability-hub.js");

  const serverEnv = {
    ...(process.env.OPENCLAW_GATEWAY_URL ? { OPENCLAW_GATEWAY_URL: process.env.OPENCLAW_GATEWAY_URL } : {}),
    ...(process.env.OPENCLAW_GATEWAY_TOKEN ? { OPENCLAW_GATEWAY_TOKEN: process.env.OPENCLAW_GATEWAY_TOKEN } : {}),
    ...(process.env.OPENCLAW_SESSION_KEY ? { OPENCLAW_SESSION_KEY: process.env.OPENCLAW_SESSION_KEY } : {}),
    ...(args["gateway-url"] ? { OPENCLAW_GATEWAY_URL: args["gateway-url"] } : {}),
    ...(args["session-key"] ? { OPENCLAW_SESSION_KEY: args["session-key"] } : {}),
  };

  const transport = new StdioClientTransport({
    command: "node",
    args: [hubScript],
    stderr: "inherit",
    env: serverEnv,
  });
  const client = new Client({ name: "m5-dispatch-client", version: "0.1.0" }, { capabilities: {} });

  try {
    await client.connect(transport);
    if (mode === "list-tools") {
      const tools = await client.listTools();
      const names = (tools?.tools ?? []).map((tool) => tool.name).sort();
      outputJson({
        ok: true,
        mode,
        tools_count: names.length,
        ask_tool_registered: names.includes("cap.ask_user"),
        dispatch_tool_registered: names.includes("cap.vk_plan_and_dispatch"),
        tools: names,
      });
      return;
    }

    const goal = typeof args.goal === "string" ? args.goal.trim() : "";
    if (!goal) {
      outputJson({ ok: false, error_code: "invalid_input", error_message: "--goal is required for dispatch mode" });
      process.exit(2);
    }

    const subtasks = await resolveSubtasks(args);
    if (!Array.isArray(subtasks) || subtasks.length < 1) {
      outputJson({ ok: false, error_code: "invalid_input", error_message: "subtasks are required and must be an array" });
      process.exit(2);
    }

    const traceId = args["trace-id"] || "m5-dispatch-client";
    const callArgs = {
      meta: {
        trace_id: traceId,
        ...(args["session-key"] ? { user_session_key: args["session-key"] } : {}),
      },
      goal,
      subtasks,
      ...(args["project-id"] ? { project_id: args["project-id"] } : {}),
      ...(args["repo-ids"] ? { repo_ids: String(args["repo-ids"]).split(",").map((x) => x.trim()).filter(Boolean) } : {}),
      ...(args["target-branch"] ? { target_branch: args["target-branch"] } : {}),
      ...(args["assist-planning"] ? { assist_planning: String(args["assist-planning"]).toLowerCase() !== "false" } : {}),
      ...(args["idempotency-key"] ? { idempotency_key: args["idempotency-key"] } : {}),
    };

    const result = await client.callTool({
      name: "cap.vk_plan_and_dispatch",
      arguments: callArgs,
    }, undefined, {
      timeout: timeoutMs,
      maxTotalTimeout: timeoutMs,
    });
    const payload = extractStructuredContent(result);
    if (!payload || typeof payload !== "object") {
      outputJson({ ok: false, error_code: "temporary_failure", error_message: "Unable to parse tool result" });
      process.exit(1);
    }
    outputJson(payload);
  } finally {
    try {
      await transport.close();
    } catch {
      // ignore close errors
    }
  }
}

main().catch((error) => {
  outputJson({
    ok: false,
    error_code: "temporary_failure",
    error_message: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});
