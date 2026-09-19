#!/usr/bin/env node
/**
 * Isolated deterministic OpenAI-compatible provider for reverse-proxy tests.
 * Label: oppi-rp39-deterministic. Never call oMLX/ds4/mlx-serve.
 */

import { createServer } from "node:http";

const MODEL = "oppi-rp39-deterministic";
const TEXT = "Hello from Oppi reverse-proxy test.";

const server = createServer((req, res) => {
  if (req.url === "/health") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ ok: true, provider: MODEL }));
    return;
  }
  if (req.url === "/v1/models") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ object: "list", data: [{ id: MODEL, object: "model" }] }));
    return;
  }
  if (req.url === "/v1/chat/completions" && req.method === "POST") {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => {
      let parsed = {};
      try {
        parsed = JSON.parse(raw || "{}");
      } catch {
        parsed = {};
      }
      const tools = Array.isArray(parsed.tools) ? parsed.tools : [];
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      if (tools.length > 0) {
        const name = tools[0]?.function?.name || tools[0]?.name || "bash";
        res.write(
          `data: ${JSON.stringify({
            id: "rp39",
            object: "chat.completion.chunk",
            choices: [
              {
                index: 0,
                delta: {
                  role: "assistant",
                  tool_calls: [
                    {
                      index: 0,
                      id: "call_rp39",
                      type: "function",
                      function: { name, arguments: '{"command":"echo ping"}' },
                    },
                  ],
                },
              },
            ],
          })}\n\n`,
        );
        res.write(
          `data: ${JSON.stringify({
            id: "rp39",
            object: "chat.completion.chunk",
            choices: [{ index: 0, delta: {}, finish_reason: "tool_calls" }],
          })}\n\n`,
        );
      } else {
        res.write(
          `data: ${JSON.stringify({
            id: "rp39",
            object: "chat.completion.chunk",
            choices: [{ index: 0, delta: { role: "assistant", content: TEXT } }],
          })}\n\n`,
        );
        res.write(
          `data: ${JSON.stringify({
            id: "rp39",
            object: "chat.completion.chunk",
            choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
          })}\n\n`,
        );
      }
      res.write("data: [DONE]\n\n");
      res.end();
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

server.listen(8080, "0.0.0.0", () => {
  process.stdout.write(`${MODEL} listening on 8080\n`);
});
