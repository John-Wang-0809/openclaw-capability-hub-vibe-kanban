#!/usr/bin/env node
/**
 * [IN] Dependencies/Inputs:
 *  - Node.js `child_process`, `fs`, `path`, and `url` runtime modules.
 *  - CLI args for gateway URL, project ID, goal text, trace ID, and idempotency key.
 *  - Local files `test/subtasks.json` and `capability-hub/scripts/m5-dispatch-client.js`.
 * [OUT] Outputs:
 *  - Spawns `m5-dispatch-client.js` with the resolved arguments and exits with the child status code.
 * [POS] Position in the system:
 *  - Thin public test harness for manual multi-agent dispatch verification.
 *  - Does not implement routing, decomposition, or vibe-kanban API logic itself.
 */

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

function requireArg(args, key) {
  const value = args[key];
  if (!value || String(value).trim() === "") {
    throw new Error(`Missing required arg: --${key}`);
  }
  return String(value);
}

const args = parseArgs(process.argv.slice(2));
const gatewayUrl = args["gateway-url"] || "http://127.0.0.1:18789";
const projectId = requireArg(args, "project-id");
const goal = requireArg(args, "goal");
const traceId = args["trace-id"] || `multi-agent-${Date.now()}`;
const idempotencyKey = args["idempotency-key"] || `multi-agent-${Date.now()}`;

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..");
const subtasksFile = path.join(here, "subtasks.json");
const clientScript = path.join(repoRoot, "capability-hub", "scripts", "m5-dispatch-client.js");

if (!fs.existsSync(subtasksFile)) {
  throw new Error(`Missing subtasks file: ${subtasksFile}`);
}

if (!fs.existsSync(clientScript)) {
  throw new Error(`Missing dispatch client: ${clientScript}`);
}

const childArgs = [
  clientScript,
  "--mode",
  "dispatch",
  "--gateway-url",
  gatewayUrl,
  "--project-id",
  projectId,
  "--goal",
  goal,
  "--subtasks-file",
  subtasksFile,
  "--trace-id",
  traceId,
  "--idempotency-key",
  idempotencyKey,
  "--json",
];

const child = spawn("node", childArgs, { stdio: "inherit" });
child.on("exit", (code) => process.exit(code ?? 1));
