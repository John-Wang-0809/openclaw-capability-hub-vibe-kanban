import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

async function main() {
  // NOTE: StdioClientTransport does NOT inherit process.env by default; it uses a
  // "default env" + the explicit `env` object below.
  const serverEnv = {
    ...(process.env.OPENCLAW_GATEWAY_URL
      ? { OPENCLAW_GATEWAY_URL: process.env.OPENCLAW_GATEWAY_URL }
      : {}),
    ...(process.env.OPENCLAW_GATEWAY_TOKEN
      ? { OPENCLAW_GATEWAY_TOKEN: process.env.OPENCLAW_GATEWAY_TOKEN }
      : {}),
    ...(process.env.OPENCLAW_SESSION_KEY
      ? { OPENCLAW_SESSION_KEY: process.env.OPENCLAW_SESSION_KEY }
      : {}),
  };

  const transport = new StdioClientTransport({
    command: "node",
    args: ["./src/openclaw-capability-hub.js"],
    stderr: "inherit",
    env: serverEnv,
  });
  const client = new Client(
    { name: "capability-hub-self-test", version: "0.1.0" },
    { capabilities: {} },
  );

  await client.connect(transport);

  const tools = await client.listTools();
  const names = (tools?.tools ?? []).map((t) => t.name).sort();
  console.log("tools:", names.join(", "));

  const required = [
    "cap.web_search",
    "cap.web_snapshot",
    "cap.ask_user",
    "cap.memory_search",
    "cap.fetch_doc",
  ];
  const missing = required.filter((n) => !names.includes(n));
  if (missing.length) {
    throw new Error(`Missing tools: ${missing.join(", ")}`);
  }

  // Call a non-interactive tool with minimal args.
  // This may return an error if the OpenClaw gateway isn't running, but it must not crash.
  const res = await client.callTool({
    name: "cap.web_search",
    arguments: {
      meta: { trace_id: "self-test" },
      query: "openclaw capability hub mcp",
      max_results: 1,
    },
  });
  console.log("cap.web_search result:", JSON.stringify(res, null, 2));

  await transport.close();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
