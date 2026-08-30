import { createServer } from "node:http";
import { existsSync, unlinkSync } from "node:fs";
import { createRequire } from "node:module";

const socketPath = process.argv[2];
const serverRoot = process.env.OPPI_SERVER_ROOT;
if (!socketPath || !serverRoot) {
  console.error("usage: OPPI_SERVER_ROOT=... node unix-ws-echo.mjs <socket-path>");
  process.exit(1);
}

const require = createRequire(`${serverRoot}/package.json`);
const { WebSocketServer } = require("ws");

if (existsSync(socketPath)) {
  unlinkSync(socketPath);
}

const server = createServer();
const wss = new WebSocketServer({ server, maxPayload: 16 * 1024 * 1024 });
wss.on("connection", (ws) => {
  ws.on("message", (data, isBinary) => {
    if (!isBinary && String(data) === "close-please") {
      ws.close(1000, "bye");
      return;
    }
    ws.send(data, { binary: isBinary });
  });
});
server.listen(socketPath, () => {
  process.stdout.write(`ready ${socketPath}\n`);
});
