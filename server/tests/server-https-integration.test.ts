import { execSync } from "node:child_process";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";
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

function enrollTestDevice(storage: Storage): string {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  const result = storage.enrollViaPairing(
    storage.issuePairingToken(),
    { name: "https-test", publicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y } },
  );
  if (!result) throw new Error("test device enrollment failed");
  return result.accessToken;
}

function httpsRequestJSON(
  url: string,
  options: { method?: string; body?: unknown; token?: string } = {},
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    const req = httpsRequest(
      url,
      {
        method: options.method ?? "GET",
        rejectUnauthorized: false,
        headers: {
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
          ...(body
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }
            : {}),
        },
      },
      (res) => {
        let responseBody = "";
        res.setEncoding("utf-8");
        res.on("data", (chunk) => {
          responseBody += chunk;
        });
        res.on("end", () => resolve({ status: res.statusCode ?? 0, body: responseBody }));
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
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

      storage.ensurePaired();
      const token = enrollTestDevice(storage);
      const server = new Server(storage);
      let baseURL = "";

      try {
        await server.start();
        baseURL = `https://127.0.0.1:${server.port}`;

        const health = await httpsGet(`${baseURL}/health`);
        expect(health.status).toBe(200);
        const body = JSON.parse(health.body) as { ok?: boolean };
        expect(body.ok).toBe(true);

        const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
        const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
        const pair = await httpsRequestJSON(`${baseURL}/pair`, {
          method: "POST",
          body: {
            pairingToken: storage.issuePairingToken(),
            deviceName: "HTTPS route test",
            devicePublicKey: { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y },
          },
        });
        expect(pair.status).toBe(200);
        const paired = JSON.parse(pair.body) as { deviceId: string; accessToken: string };

        const challengeResponse = await httpsRequestJSON(`${baseURL}/auth/challenge`, {
          method: "POST",
          body: { deviceId: paired.deviceId },
        });
        expect(challengeResponse.status).toBe(200);
        const challenge = JSON.parse(challengeResponse.body) as { nonce: string; audience: string };
        const signature = cryptoSign(
          "sha256",
          Buffer.from(`${challenge.audience}.${challenge.nonce}`),
          { key: privateKey, dsaEncoding: "ieee-p1363" },
        ).toString("base64url");
        const refresh = await httpsRequestJSON(`${baseURL}/auth/refresh`, {
          method: "POST",
          body: { deviceId: paired.deviceId, nonce: challenge.nonce, signature },
        });
        expect(refresh.status).toBe(200);
        const refreshed = JSON.parse(refresh.body) as { accessToken: string };
        expect(
          (await httpsRequestJSON(`${baseURL}/me`, { token: refreshed.accessToken })).status,
        ).toBe(200);

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
