const { createInterface } = require("node:readline");
const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  let result;
  switch (message.method) {
    case "initialize": result = { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "fixture-echo", version: "1.0" } }; break;
    case "tools/list": result = { tools: [{ name: "echo", description: "Echo text", inputSchema: { type: "object", properties: { text: { type: "string" } } } }] }; break;
    case "tools/call": result = { content: [{ type: "text", text: message.params.arguments.text }] }; break;
    default: result = {};
  }
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) + "\n");
});
