import { execSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { WebSocket } from "ws";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";

let hasOpenSSL = true;
try {
  execSync("openssl version", { stdio: "ignore" });
} catch {
  hasOpenSSL = false;
}

function logSkip(unavailable: boolean, suite: string, reason: string): boolean {
  if (unavailable) console.warn(`[test] Skipping ${suite}: ${reason}`);
  return unavailable;
}

function httpsGet(url: string): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      url,
      {
        rejectUnauthorized: false,
      },
      (res) => {
        let body = "";
        res.setEncoding("utf-8");
        res.on("data", (chunk) => {
          body += chunk;
        });
        res.on("end", () => {
          resolve({ status: res.statusCode ?? 0, body });
        });
      },
    );

    req.on("error", reject);
    req.end();
  });
}

async function waitForHttpsShutdown(url: string, timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      await httpsGet(`${url}/health`);
    } catch {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`HTTPS server still accepted connections after ${timeoutMs}ms`);
}

describe.skipIf(logSkip(!hasOpenSSL, "HTTPS/WSS integration", "openssl executable is unavailable"))(
  "HTTPS/WSS integration",
  () => {
    it("serves /health over HTTPS and bound session stream over WSS", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-https-integration-"));
      const storage = new Storage(dataDir);
      storage.updateConfig({
        host: "127.0.0.1",
        port: 0,
        tls: { mode: "self-signed" },
      });

      const token = storage.ensurePaired();
      const server = new Server(storage);
      let baseURL = "";

      try {
        await server.start();
        baseURL = `https://127.0.0.1:${server.port}`;

        const health = await httpsGet(`${baseURL}/health`);
        expect(health.status).toBe(200);
        const body = JSON.parse(health.body) as { ok?: boolean };
        expect(body.ok).toBe(true);

        const workspace = storage.createWorkspace({ name: "https-ws" });
        const session = storage.createSession("https session");
        session.workspaceId = workspace.id;
        session.workspaceName = workspace.name;
        storage.saveSession(session);

        const streamMessage = await new Promise<Record<string, unknown> | null>((resolve) => {
          const ws = new WebSocket(
            `${baseURL.replace("https", "wss")}/workspaces/${workspace.id}/sessions/${session.id}/stream`,
            {
              headers: { Authorization: `Bearer ${token}` },
              rejectUnauthorized: false,
            },
          );

          const timeout = setTimeout(() => {
            ws.terminate();
            resolve(null);
          }, 30_000);

          ws.once("message", (raw) => {
            clearTimeout(timeout);
            const parsed = JSON.parse(raw.toString()) as Record<string, unknown>;
            ws.close();
            resolve(parsed);
          });

          ws.once("error", () => {
            clearTimeout(timeout);
            resolve(null);
          });
        });

        expect(streamMessage).not.toBeNull();
        expect(streamMessage?.type).toBe("stream_connected");
      } finally {
        await server.stop().catch(() => {});
        if (baseURL) await waitForHttpsShutdown(baseURL);
        rmSync(dataDir, { recursive: true, force: true });
      }
    }, 60_000);
  },
);
