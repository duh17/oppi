#!/usr/bin/env node
// Minimal stdio MCP server for host-MCP activation tests: one `echo` tool.
// Appends a line to $MCP_ECHO_MARKER at process start (proves a spawn) and one
// per tools/call (proves the call reached the server).
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const marker = process.env.MCP_ECHO_MARKER;
const note = (line) => marker && appendFileSync(marker, `${line}\n`);
note(`spawn ${process.pid}`);

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });

createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  if (message.id === undefined) return; // notification
  switch (message.method) {
    case "initialize":
      reply(message.id, {
        protocolVersion: message.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: {} },
        serverInfo: { name: "echo", version: "1.0.0" },
      });
      break;
    case "tools/list":
      reply(message.id, {
        tools: [
          {
            name: "echo",
            description: "Echo the given text back.",
            inputSchema: {
              type: "object",
              properties: { text: { type: "string" } },
              required: ["text"],
            },
            annotations: { readOnlyHint: true },
          },
        ],
      });
      break;
    case "tools/call":
      note(`call ${message.params?.name} ${JSON.stringify(message.params?.arguments)}`);
      reply(message.id, {
        content: [{ type: "text", text: `echo:${message.params?.arguments?.text}` }],
      });
      break;
    case "ping":
      reply(message.id, {});
      break;
    default:
      send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `Method not found: ${message.method}` },
      });
  }
});
