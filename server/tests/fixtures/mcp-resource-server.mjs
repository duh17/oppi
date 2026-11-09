#!/usr/bin/env node
// Minimal stdio MCP server with one readable resource, `test://notes`. Pi lists a server's tools
// first, and only then learns of its resources, so it answers `tools/list` with none.
import { createInterface } from "node:readline";

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
        capabilities: { tools: {}, resources: {} },
        serverInfo: { name: "notes", version: "1.0.0" },
      });
      break;
    case "tools/list":
      reply(message.id, { tools: [] });
      break;
    case "resources/list":
      reply(message.id, {
        resources: [{ uri: "test://notes", name: "Notes", mimeType: "text/plain" }],
      });
      break;
    case "resources/read":
      reply(message.id, {
        contents: [
          { uri: message.params?.uri, mimeType: "text/plain", text: "NOTES-RESOURCE-BODY" },
        ],
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
