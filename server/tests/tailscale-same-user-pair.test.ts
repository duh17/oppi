import { execSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { localApiRequest, type LocalApiError } from "../src/cli/local-api-client.js";
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

function writeFakeTailscale(binDir: string): void {
  writeFileSync(
    join(binDir, "tailscale"),
    `#!/bin/sh
set -eu
if [ "\${OPPI_TEST_STATUS_FAIL:-}" = "1" ] && [ "$1" = "status" ]; then
  printf '%s\\n' 'status failed' >&2
  exit 1
fi
if [ "$1" = "status" ]; then
  dns="\${OPPI_TEST_SELF_DNS:-mac.tail1234.ts.net}"
  ip="\${OPPI_TEST_SELF_IP:-100.101.102.1}"
  login="\${OPPI_TEST_SELF_LOGIN:-chen@example.com}"
  stable_id="\${OPPI_TEST_SELF_STABLE_ID:-nSelf1CNTRL}"
  if [ "\${OPPI_TEST_SELF_TAGGED:-}" = "1" ]; then
    printf '{"Self":{"DNSName":"%s.","UserID":1,"Tags":["tag:server"],"TailscaleIPs":["%s"]},"User":{"1":{"ID":1,"LoginName":"tagged-devices","DisplayName":"tagged-devices"}}}\\n' "$dns" "$ip"
    exit 0
  fi
  printf '{"Self":{"ID":"%s","DNSName":"%s.","UserID":1,"TailscaleIPs":["%s"]},"User":{"1":{"ID":1,"LoginName":"%s"}}}\\n' "$stable_id" "$dns" "$ip" "$login"
  exit 0
fi
if [ "$1" = "cert" ]; then
  if [ -n "\${OPPI_TEST_CERT_LOG:-}" ]; then
    printf 'cert\\n' >> "\${OPPI_TEST_CERT_LOG}"
  fi
  printf '%s\\n' 'cert failed' >&2
  exit 1
fi
if [ "$1" = "whois" ]; then
  if [ -n "\${OPPI_TEST_WHOIS_GATE:-}" ]; then
    mkdir -p "\${OPPI_TEST_WHOIS_GATE}"
    printf 'started\\n' > "\${OPPI_TEST_WHOIS_GATE}/started"
    while [ ! -f "\${OPPI_TEST_WHOIS_GATE}/release" ]; do
      sleep 0.02
    done
  fi
  if [ "\${OPPI_TEST_WHOIS_FAIL:-}" = "1" ]; then
    printf '%s\\n' 'whois failed' >&2
    exit 1
  fi
  ip=""
  for arg in "$@"; do ip="$arg"; done
  self_ip="\${OPPI_TEST_SELF_IP:-100.101.102.1}"
  self_login="\${OPPI_TEST_SELF_LOGIN:-chen@example.com}"
  peer_login="\${OPPI_TEST_PEER_LOGIN:-$self_login}"
  login="$peer_login"
  if [ "$ip" = "$self_ip" ]; then
    login="$self_login"
  fi
  if [ "\${OPPI_TEST_WHOIS_USER_FIELD:-}" = "1" ]; then
    printf '{"User":{"ID":1,"LoginName":"%s"}}\\n' "$login"
    exit 0
  fi
  if [ "\${OPPI_TEST_PEER_TAGGED:-}" = "1" ] && [ "$ip" != "$self_ip" ]; then
    printf '{"Node":{"ID":2,"StableID":"nCi1CNTRL","Name":"ci.tail1234.ts.net.","User":1,"Tags":["tag:ci"],"Addresses":["%s/32"],"Hostinfo":{"OS":"linux","Hostname":"ci"}},"UserProfile":{"ID":1,"LoginName":"tagged-devices","DisplayName":"tagged-devices"},"CapMap":{}}\\n' "$ip"
    exit 0
  fi
  stable_id="\${OPPI_TEST_PEER_STABLE_ID:-nPeer1CNTRL}"
  printf '{"Node":{"ID":2,"StableID":"%s","Name":"iphone.tail1234.ts.net.","User":1,"Addresses":["%s/32"],"Hostinfo":{"OS":"iOS","Hostname":"iPhone"}},"UserProfile":{"ID":1,"LoginName":"%s","DisplayName":"Chen"},"CapMap":{}}\\n' "$stable_id" "$ip" "$login"
  exit 0
fi
exit 1
`,
    { mode: 0o755 },
  );
}

function writeTailscaleLeaf(dataDir: string, host: string): void {
  const certDir = join(dataDir, "tls", "tailscale");
  mkdirSync(certDir, { recursive: true });
  const certPath = join(certDir, "server.crt");
  const keyPath = join(certDir, "server.key");
  execSync(
    `openssl req -x509 -newkey rsa:2048 -nodes` +
      ` -keyout "${keyPath}" -out "${certPath}"` +
      ` -days 30 -subj "/CN=${host}" -addext "subjectAltName=DNS:${host}"`,
    { stdio: "ignore" },
  );
}

function certLogContents(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function httpsJSON(
  url: string,
  options: {
    method?: string;
    body?: unknown;
    token?: string;
    headers?: Record<string, string>;
  } = {},
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
          ...(options.headers ?? {}),
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

async function waitForFile(path: string, timeoutMs = 5_000): Promise<void> {
  const started = Date.now();
  while (!existsSync(path)) {
    if (Date.now() - started > timeoutMs) {
      throw new Error(`timed out waiting for ${path}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe("POST /pair/tailscale", () => {
  const previousPath = process.env.PATH;
  let dataDir = "";
  let fakeBinDir = "";
  let server: Server | undefined;

  afterEach(async () => {
    process.env.PATH = previousPath;
    delete process.env.OPPI_TEST_PEER_LOGIN;
    delete process.env.OPPI_TEST_SELF_LOGIN;
    delete process.env.OPPI_TEST_WHOIS_FAIL;
    delete process.env.OPPI_TEST_STATUS_FAIL;
    delete process.env.OPPI_TEST_WHOIS_GATE;
    delete process.env.OPPI_TEST_WHOIS_USER_FIELD;
    delete process.env.OPPI_TEST_PEER_TAGGED;
    delete process.env.OPPI_TEST_SELF_TAGGED;
    delete process.env.OPPI_TEST_SELF_IP;
    delete process.env.OPPI_TEST_SELF_STABLE_ID;
    delete process.env.OPPI_TEST_PEER_STABLE_ID;
    delete process.env.OPPI_TEST_CERT_LOG;
    delete process.env.OPPI_TAILSCALE_BIN;
    if (server) {
      await server.stop().catch(() => {});
      server = undefined;
    }
    if (dataDir) {
      rmSync(dataDir, { recursive: true, force: true });
      dataDir = "";
    }
  });

  async function startServer(
    tlsMode: "self-signed" | "disabled" | "tailscale",
    extras: { publicUrl?: string; trustedPeers?: string[]; certLog?: boolean } = {},
  ): Promise<Storage> {
    dataDir = mkdtempSync(join(tmpdir(), "oppi-tailscale-pair-"));
    fakeBinDir = join(dataDir, "bin");
    mkdirSync(fakeBinDir, { recursive: true });
    writeFakeTailscale(fakeBinDir);
    process.env.PATH = `${fakeBinDir}:${previousPath ?? ""}`;
    if (extras.certLog) {
      process.env.OPPI_TEST_CERT_LOG = join(dataDir, "cert-invocations.log");
    }

    const storage = new Storage(dataDir);
    storage.ensurePaired();
    if (tlsMode === "tailscale") {
      writeTailscaleLeaf(dataDir, process.env.OPPI_TEST_SELF_DNS ?? "mac.tail1234.ts.net");
    }
    storage.updateConfig({
      host: "127.0.0.1",
      port: 0,
      tls: { mode: tlsMode },
      ...(extras.publicUrl ? { publicUrl: extras.publicUrl } : {}),
      ...(extras.trustedPeers ? { proxy: { trustedPeers: extras.trustedPeers } } : {}),
    });
    server = new Server(storage);
    await server.start();
    return storage;
  }

  it("returns 404 on the unix socket even with owner sk_", async () => {
    const storage = await startServer("disabled");
    await expect(
      localApiRequest(storage, "/pair/tailscale", { method: "POST", body: {} }),
    ).rejects.toMatchObject({ status: 404 } satisfies Partial<LocalApiError>);
    expect(storage.getConfig().pairingToken).toBeUndefined();
  });

  describe.skipIf(logSkip(!hasOpenSSL, "POST /pair/tailscale HTTPS", "openssl executable is unavailable"))(
    "HTTPS",
    () => {
      it("mints a pairing token from an existing Tailscale cert without invoking cert", async () => {
        const storage = await startServer("tailscale", { certLog: true });
        const certLog = process.env.OPPI_TEST_CERT_LOG ?? join(dataDir, "cert-invocations.log");
        const certBefore = certLogContents(certLog);
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(200);
        const body = JSON.parse(res.body) as {
          pairingToken?: string;
          scheme?: string;
          host?: string;
        };
        expect(typeof body.pairingToken).toBe("string");
        expect(body.pairingToken?.length).toBeGreaterThan(0);
        expect(body.scheme).toBe("https");
        expect(body.host).toBe("mac.tail1234.ts.net");
        expect(storage.getConfig().pairingToken).toBe(body.pairingToken);
        expect(certLogContents(certLog)).toBe(certBefore);
      });

      it("runs the identity proof through OPPI_TAILSCALE_BIN when tailscale is not on PATH", async () => {
        await startServer("tailscale");
        process.env.PATH = "/usr/bin:/bin";
        process.env.OPPI_TAILSCALE_BIN = join(fakeBinDir, "tailscale");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(200);
        expect(typeof (JSON.parse(res.body) as { pairingToken?: string }).pairingToken).toBe(
          "string",
        );
      });

      it("rejects the server's own Tailscale IP even when its login matches", async () => {
        process.env.OPPI_TEST_SELF_IP = "127.0.0.1";
        const storage = await startServer("tailscale");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Server Tailscale node is not a peer" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("rejects the server's stable node ID from whois even at a different IP", async () => {
        process.env.OPPI_TEST_PEER_STABLE_ID = "nSelf1CNTRL";
        const storage = await startServer("tailscale");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Server Tailscale node is not a peer" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it.each(["self", "peer"])("rejects when the %s stable ID is absent", async (missing) => {
        if (missing === "self") process.env.OPPI_TEST_SELF_STABLE_ID = " ";
        else process.env.OPPI_TEST_PEER_STABLE_ID = " ";
        const storage = await startServer("tailscale");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Tailscale node identity is unavailable" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 404 with publicUrl even when the socket is not a trusted proxy", async () => {
        process.env.OPPI_TEST_STATUS_FAIL = "1";
        const storage = await startServer("tailscale", { publicUrl: "https://oppi.example.com" });
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(404);
        expect(JSON.parse(res.body)).toEqual({ error: "Not found" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it.each([
        ["Forwarded", "for=203.0.113.99;proto=https"],
        ["X-Forwarded-For", "203.0.113.99"],
        ["X-Forwarded-Proto", "https"],
        ["X-Real-IP", "203.0.113.99"],
        ["Via", "1.1 proxy"],
      ])("rejects %s even from an untrusted direct socket peer", async (header, value) => {
        const storage = await startServer("tailscale");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
          headers: { [header]: value },
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({
          error: "Tailscale pairing is not available through a reverse proxy",
        });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 503 when whois logins match but tls.mode is not tailscale", async () => {
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(503);
        expect(JSON.parse(res.body)).toEqual({
          error: "Same-user Tailscale pairing requires tls.mode=tailscale",
        });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("consumes the pairing limiter on missing-host 503s", async () => {
        const storage = await startServer("self-signed");
        const url = `https://127.0.0.1:${server!.port}/pair/tailscale`;
        for (let i = 0; i < 5; i += 1) {
          const failed = await httpsJSON(url, { method: "POST", body: {} });
          expect(failed.status).toBe(503);
          expect(JSON.parse(failed.body)).toEqual({
            error: "Same-user Tailscale pairing requires tls.mode=tailscale",
          });
        }
        const blocked = await httpsJSON(url, { method: "POST", body: {} });
        expect(blocked.status).toBe(429);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("consumes the pairing limiter on unsupported-TLS 503s", async () => {
        const storage = await startServer("self-signed");
        storage.updateConfig({ tls: { mode: "disabled" } });
        const url = `https://127.0.0.1:${server!.port}/pair/tailscale`;
        for (let i = 0; i < 5; i += 1) {
          const failed = await httpsJSON(url, { method: "POST", body: {} });
          expect(failed.status).toBe(503);
          expect(JSON.parse(failed.body)).toEqual({ error: "HTTPS pairing requires TLS" });
        }
        const blocked = await httpsJSON(url, { method: "POST", body: {} });
        expect(blocked.status).toBe(429);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 403 when whois logins differ", async () => {
        process.env.OPPI_TEST_PEER_LOGIN = "other@example.com";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Different Tailscale user" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 403 when whois uses the inauthentic User field", async () => {
        process.env.OPPI_TEST_WHOIS_USER_FIELD = "1";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body).error).toMatch(/whois/i);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 403 for a tagged peer identity", async () => {
        process.env.OPPI_TEST_PEER_TAGGED = "1";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Tagged Tailscale identity" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 403 when the server node is tagged", async () => {
        process.env.OPPI_TEST_SELF_TAGGED = "1";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body)).toEqual({ error: "Tagged Tailscale identity" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 403 when whois fails", async () => {
        process.env.OPPI_TEST_WHOIS_FAIL = "1";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(403);
        expect(JSON.parse(res.body).error).toMatch(/whois/i);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("returns 503 when Tailscale status is unavailable", async () => {
        process.env.OPPI_TEST_STATUS_FAIL = "1";
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        expect(res.status).toBe(503);
        expect(JSON.parse(res.body).error).toBeTruthy();
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("consumes the pairing limiter on status 503", async () => {
        process.env.OPPI_TEST_STATUS_FAIL = "1";
        const storage = await startServer("self-signed");
        const url = `https://127.0.0.1:${server!.port}/pair/tailscale`;
        for (let i = 0; i < 5; i += 1) {
          const failed = await httpsJSON(url, { method: "POST", body: {} });
          expect(failed.status).toBe(503);
        }
        const blocked = await httpsJSON(url, { method: "POST", body: {} });
        expect(blocked.status).toBe(429);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("rejects an outsider through a same-owner reverse proxy", async () => {
        const storage = await startServer("self-signed", {
          publicUrl: "https://oppi.example.com",
          trustedPeers: ["127.0.0.1/32", "::1/128"],
        });
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
          headers: {
            "X-Forwarded-Proto": "https",
            "X-Forwarded-For": "203.0.113.99",
          },
        });
        expect(res.status).toBe(404);
        expect(JSON.parse(res.body)).toEqual({ error: "Not found" });
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });

      it("does not stall Unix or live traffic while whois is in flight", async () => {
        const storage = await startServer("self-signed");
        const gate = join(dataDir, "whois-gate");
        mkdirSync(gate, { recursive: true });
        process.env.OPPI_TEST_WHOIS_GATE = gate;

        const pairing = httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
        });
        await waitForFile(join(gate, "started"));

        const unixStarted = Date.now();
        const me = await localApiRequest<{ user: string }>(storage, "/me");
        expect(me.user).toBe("owner");
        expect(Date.now() - unixStarted).toBeLessThan(1_000);

        const liveStarted = Date.now();
        const health = await httpsJSON(`https://127.0.0.1:${server!.port}/health`);
        expect(health.status).toBe(200);
        expect(Date.now() - liveStarted).toBeLessThan(1_000);

        writeFileSync(join(gate, "release"), "1");
        const res = await pairing;
        expect(res.status).toBe(503);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      }, 15_000);

      it("admits at most two in-flight whois proofs", async () => {
        const storage = await startServer("self-signed");
        const gate = join(dataDir, "whois-gate");
        mkdirSync(gate, { recursive: true });
        process.env.OPPI_TEST_WHOIS_GATE = gate;
        const url = `https://127.0.0.1:${server!.port}/pair/tailscale`;
        const first = httpsJSON(url, { method: "POST", body: {} });
        const second = httpsJSON(url, { method: "POST", body: {} });
        const third = httpsJSON(url, { method: "POST", body: {} });
        await waitForFile(join(gate, "started"));
        const firstFinished = await Promise.race([
          first,
          second,
          third,
          new Promise<{ status: number; body: string }>((_, reject) => {
            setTimeout(() => reject(new Error("expected a 429 before whois release")), 2_000);
          }),
        ]);
        expect(firstFinished.status).toBe(429);
        expect(JSON.parse(firstFinished.body)).toEqual({
          error: "Too many Tailscale identity checks",
        });
        writeFileSync(join(gate, "release"), "1");
        const results = await Promise.all([first, second, third]);
        expect(results.filter((result) => result.status === 429)).toHaveLength(1);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      }, 15_000);

      it("returns 404 when the request presents owner sk_", async () => {
        const storage = await startServer("self-signed");
        const res = await httpsJSON(`https://127.0.0.1:${server!.port}/pair/tailscale`, {
          method: "POST",
          body: {},
          token: storage.getToken(),
        });
        expect(res.status).toBe(404);
        expect(storage.getConfig().pairingToken).toBeUndefined();
      });
    },
  );
});
