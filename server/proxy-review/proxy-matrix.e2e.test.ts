/**
 * Isolated four-way reverse-proxy matrix. Real Caddy/nginx containers.
 * Deterministic provider: oppi-rp39-deterministic (not oMLX/ds4/mlx-serve).
 * Positive TLS clients always verify CA+hostname.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Agent as HttpsAgent } from "node:https";
import WebSocket from "ws";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SERVER_DIR = join(ROOT, "server");
const FORBIDDEN_PORTS = new Set([7749, 7750, 17760, 8888, 13001]);
const PUBLIC_HOST = "oppi.rp39.test";
const MODES = ["caddy-http", "caddy-https", "nginx-http", "nginx-https"] as const;
type Mode = (typeof MODES)[number];

function requireCmd(cmd: string, args: string[]): void {
  const result = spawnSync(cmd, args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(" ")} is required for proxy-review tests`);
  }
}

function freeLoopbackPort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => {
        if (error) reject(error);
        else if (!address || typeof address === "string") reject(new Error("port bind failed"));
        else if (FORBIDDEN_PORTS.has(address.port)) reject(new Error(`refusing forbidden port ${address.port}`));
        else resolvePort(address.port);
      });
    });
  });
}

function openssl(args: string[], cwd: string): void {
  execFileSync("openssl", args, { cwd, stdio: "pipe" });
}

function docker(args: string[], opts: { cwd?: string } = {}): string {
  return execFileSync("docker", args, {
    cwd: opts.cwd ?? SERVER_DIR,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function devicePublicKey() {
  const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { privateKey, publicKey: { kty: "EC" as const, crv: "P-256" as const, x: jwk.x, y: jwk.y } };
}

function httpsJson(
  port: number,
  ca: Buffer,
  path: string,
  options: { method?: string; body?: unknown; token?: string; headers?: Record<string, string> } = {},
): Promise<{ status: number; body: unknown }> {
  return new Promise((resolveResponse, reject) => {
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    const req = httpsRequest(
      {
        host: "127.0.0.1",
        port,
        servername: PUBLIC_HOST,
        ca,
        rejectUnauthorized: true,
        path,
        method: options.method ?? "GET",
        headers: {
          Host: PUBLIC_HOST,
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
          ...(options.headers ?? {}),
          ...(body
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body) }
            : {}),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => {
          data += chunk.toString("utf8");
        });
        res.on("end", () => {
          let parsed: unknown = data;
          try {
            parsed = JSON.parse(data);
          } catch {
            // keep text
          }
          resolveResponse({ status: res.statusCode ?? 0, body: parsed });
        });
      },
    );
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function writeEdgeCerts(dir: string): void {
  openssl(
    ["req", "-x509", "-newkey", "rsa:2048", "-keyout", "ca.key", "-out", "ca.crt", "-days", "2", "-nodes", "-subj", "/CN=oppi-rp39-test-ca"],
    dir,
  );
  writeFileSync(join(dir, "san.cnf"), `subjectAltName=DNS:${PUBLIC_HOST}\n`);
  openssl(["req", "-newkey", "rsa:2048", "-keyout", "edge.key", "-out", "edge.csr", "-nodes", "-subj", `/CN=${PUBLIC_HOST}`], dir);
  openssl(
    ["x509", "-req", "-in", "edge.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial", "-out", "edge.crt", "-days", "2", "-extfile", "san.cnf"],
    dir,
  );
}

function caddyfile(httpsOrigin: boolean): string {
  const upstream = httpsOrigin
    ? `reverse_proxy https://172.28.39.20:7750 {
    transport http {
      tls_trust_pool file /certs/origin-ca.crt
      tls_server_name localhost
    }
  }`
    : "reverse_proxy 172.28.39.20:7750";
  return `{
  auto_https off
  admin off
}
http://${PUBLIC_HOST}:80 {
  redir https://{host}{uri} permanent
}
https://${PUBLIC_HOST}:443 {
  tls /certs/edge.crt /certs/edge.key
  ${upstream}
}
`;
}

function nginxConf(httpsOrigin: boolean): string {
  const ssl = httpsOrigin
    ? `
        proxy_pass https://172.28.39.20:7750;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /certs/origin-ca.crt;
        proxy_ssl_server_name on;
        proxy_ssl_name localhost;
`
    : `
        proxy_pass http://172.28.39.20:7750;
`;
  return `
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
server {
    listen 80;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    server_name ${PUBLIC_HOST};
    ssl_certificate /certs/edge.crt;
    ssl_certificate_key /certs/edge.key;
    client_max_body_size 80m;
    location / {
${ssl}
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}
`;
}

function composeYaml(opts: {
  project: string;
  mode: Mode;
  image: string;
  httpsOrigin: boolean;
  runDir: string;
  edgePort: number;
}): string {
  const httpsOrigin = opts.httpsOrigin;
  const tlsMode = httpsOrigin ? "self-signed" : "disabled";
  const trusted = httpsOrigin
    ? ""
    : `oppi config set proxy.trustedPeers '["172.28.39.10/32"]' && `;
  const originCmd = `mkdir -p /data/oppi /data/pi-agent && oppi init --yes --force --data-dir /data/oppi && oppi config set host 0.0.0.0 && oppi config set port 7750 && oppi config set publicUrl https://${PUBLIC_HOST} && oppi config set tls.mode ${tlsMode} && ${trusted}exec oppi serve`;
  const proxyService =
    opts.mode.startsWith("caddy")
      ? `
  proxy:
    image: caddy:2-alpine
    container_name: ${opts.project}-proxy
    networks:
      edge:
        ipv4_address: 172.28.39.10
    ports:
      - "127.0.0.1:${opts.edgePort}:443"
    volumes:
      - ${opts.runDir}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${opts.runDir}/certs:/certs:ro
    depends_on:
      origin:
        condition: service_started
    restart: "no"
`
      : `
  proxy:
    image: nginx:1.27-alpine
    container_name: ${opts.project}-proxy
    networks:
      edge:
        ipv4_address: 172.28.39.10
    ports:
      - "127.0.0.1:${opts.edgePort}:443"
    volumes:
      - ${opts.runDir}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${opts.runDir}/certs:/certs:ro
    depends_on:
      origin:
        condition: service_started
    restart: "no"
`;
  return `name: ${opts.project}
services:
  origin:
    image: ${opts.image}
    container_name: ${opts.project}-origin
    networks:
      edge:
        ipv4_address: 172.28.39.20
    environment:
      OPPI_DATA_DIR: /data/oppi
      PI_CODING_AGENT_DIR: /data/pi-agent
      PI_AGENT_SYNC_MODE: skip
      SEARXNG_URL: ""
    volumes:
      - ${opts.project}-data:/data/oppi
      - ${join(SERVER_DIR, "proxy-review/fixtures/models.json")}:/data/pi-agent/models.json:ro
      - ${join(SERVER_DIR, "proxy-review/fixtures/settings.json")}:/data/pi-agent/settings.json:ro
    entrypoint: ["bash", "-lc"]
    command: [${JSON.stringify(originCmd)}]
    restart: "no"
  provider:
    image: node:24-bookworm-slim
    container_name: ${opts.project}-provider
    networks:
      edge:
        ipv4_address: 172.28.39.30
        aliases: ["oppi-rp39-provider"]
    volumes:
      - ${join(SERVER_DIR, "proxy-review/deterministic-provider.mjs")}:/provider.mjs:ro
    command: ["node", "/provider.mjs"]
    restart: "no"
  probe:
    image: curlimages/curl:8.11.1
    container_name: ${opts.project}-probe
    networks:
      edge:
        ipv4_address: 172.28.39.40
    command: ["sleep", "3600"]
    restart: "no"
  mint:
    image: ${opts.image}
    container_name: ${opts.project}-mint
    network_mode: "service:origin"
    environment:
      OPPI_DATA_DIR: /data/oppi
      REVIEW_MINT_SECRET: rp39-review-secret-value
      REVIEW_MINT_HOST: 127.0.0.1
      REVIEW_MINT_PORT: "8790"
    volumes:
      - ${opts.project}-data:/data/oppi
      - ${join(SERVER_DIR, "proxy-review/run-mint-sidecar.mjs")}:/mint.mjs:ro
    entrypoint: ["node"]
    command: ["/mint.mjs"]
    depends_on:
      origin:
        condition: service_started
    restart: "no"
${proxyService}
networks:
  edge:
    name: ${opts.project}-net
    ipam:
      config:
        - subnet: 172.28.39.0/24
volumes:
  ${opts.project}-data:
`;
}

describe("reverse-proxy four-way matrix", () => {
  let image = "";
  let imageSha = "";
  const runDirs: string[] = [];

  beforeAll(() => {
    requireCmd("docker", ["version"]);
    requireCmd("openssl", ["version"]);
    docker(["build", "-t", "oppi-rp39-origin:test", "-f", "server/Dockerfile", "."], { cwd: ROOT });
    image = "oppi-rp39-origin:test";
    const inspect = docker(["image", "inspect", "--format", "{{.Id}}", image]);
    imageSha = inspect.trim();
    expect(imageSha.length).toBeGreaterThan(10);
  }, 300_000);

  afterAll(() => {
    for (const dir of runDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  for (const mode of MODES) {
    it(`pairs and serves through ${mode}`, async () => {
      const httpsOrigin = mode.endsWith("https");
      const project = `oppi-rp39-${mode}`;
      const runDir = mkdtempSync(join(tmpdir(), `${project}-`));
      runDirs.push(runDir);
      mkdirSync(join(runDir, "certs"), { recursive: true });
      writeEdgeCerts(join(runDir, "certs"));
      writeFileSync(join(runDir, "Caddyfile"), caddyfile(httpsOrigin));
      writeFileSync(join(runDir, "nginx.conf"), nginxConf(httpsOrigin));
      writeFileSync(join(runDir, "certs", "origin-ca.crt"), "pending\n");
      const edgePort = await freeLoopbackPort();
      const composePath = join(runDir, "docker-compose.yml");
      writeFileSync(
        composePath,
        composeYaml({
          project,
          mode,
          image,
          httpsOrigin,
          runDir,
          edgePort,
        }),
      );
      const compose = ["compose", "-p", project, "-f", composePath];
      const down = () => {
        try {
          docker([...compose, "down", "-v", "--remove-orphans"]);
        } catch {
          // keep going so later modes can run
        }
      };

      try {
        docker([...compose, "up", "-d", "origin", "provider", "probe"], { cwd: runDir });
        const deadline = Date.now() + 120_000;
        let originReady = false;
        const originHealthUrl = httpsOrigin
          ? "https://127.0.0.1:7750/health"
          : "http://127.0.0.1:7750/health";
        while (Date.now() < deadline) {
          const health = spawnSync(
            "docker",
            ["exec", `${project}-origin`, "curl", "-fsS", originHealthUrl, ...(httpsOrigin ? ["-k"] : [])],
            { encoding: "utf8" },
          );
          if (health.status === 0) {
            originReady = true;
            break;
          }
          await new Promise((r) => setTimeout(r, 1000));
        }
        if (!originReady) {
          const logs = spawnSync("docker", ["logs", "--tail", "80", `${project}-origin`], {
            encoding: "utf8",
          });
          throw new Error(
            `${mode}: origin did not become healthy\n${logs.stdout}\n${logs.stderr}`,
          );
        }
        if (httpsOrigin) {
          docker(["cp", `${project}-origin:/data/oppi/tls/self-signed/ca.crt`, join(runDir, "certs", "origin-ca.crt")]);
        }
        docker([...compose, "up", "-d", "proxy", "mint"], { cwd: runDir });
        const ca = readFileSync(join(runDir, "certs", "ca.crt"));
        let edgeReady = false;
        const edgeDeadline = Date.now() + 60_000;
        while (Date.now() < edgeDeadline) {
          try {
            const health = await httpsJson(edgePort, ca, "/health");
            if (health.status === 200) {
              edgeReady = true;
              break;
            }
          } catch {
            // retry
          }
          await new Promise((r) => setTimeout(r, 1000));
        }
        if (!edgeReady) throw new Error(`${mode}: edge did not serve verified HTTPS /health`);

        const mintDeadline = Date.now() + 30_000;
        let mintUp = false;
        while (Date.now() < mintDeadline) {
          const mintProbe = spawnSync(
            "docker",
            ["exec", `${project}-origin`, "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:8790/r/not-the-secret"],
            { encoding: "utf8" },
          );
          if (mintProbe.stdout.trim() === "404") {
            mintUp = true;
            break;
          }
          await new Promise((r) => setTimeout(r, 500));
        }
        if (!mintUp) throw new Error(`${mode}: mint sidecar did not become ready`);
        const preview = spawnSync(
          "docker",
          [
            "exec",
            `${project}-origin`,
            "curl",
            "-sS",
            "-D",
            "-",
            "-o",
            "/tmp/mint-preview.html",
            "-A",
            "facebookexternalhit/1.1",
            "http://127.0.0.1:8790/r/rp39-review-secret-value",
          ],
          { encoding: "utf8" },
        );
        expect(preview.stdout).toMatch(/HTTP\/\d\.\d 200/);
        expect(preview.stdout).not.toMatch(/oppi:\/\/connect/);
        const head = spawnSync(
          "docker",
          ["exec", `${project}-origin`, "curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "-I", "http://127.0.0.1:8790/r/rp39-review-secret-value"],
          { encoding: "utf8" },
        );
        expect(head.stdout.trim()).toBe("405");

        const pairOut = docker(["exec", `${project}-origin`, "oppi", "pair", "--json"]);
        const invite = JSON.parse(pairOut) as {
          inviteURL: string;
          pairingToken: string;
          host: string;
          port: number;
          scheme: string;
          tlsCertFingerprint?: string;
          fingerprint: string;
        };
        expect(invite.host).toBe(PUBLIC_HOST);
        expect(invite.port).toBe(443);
        expect(invite.scheme).toBe("https");
        expect(invite.tlsCertFingerprint).toBeUndefined();
        expect(invite.inviteURL).toContain("oppi://connect");
        expect(invite.fingerprint).toMatch(/^sha256:/);

        const device = devicePublicKey();
        const paired = await httpsJson(edgePort, ca, "/pair", {
          method: "POST",
          body: {
            pairingToken: invite.pairingToken,
            devicePublicKey: device.publicKey,
            deviceName: `${mode}-phone`,
          },
        });
        expect(paired.status).toBe(200);
        const creds = paired.body as { accessToken: string; deviceId: string };
        expect(creds.accessToken.startsWith("at_")).toBe(true);

        const me = await httpsJson(edgePort, ca, "/me", { token: creds.accessToken });
        expect(me.status).toBe(200);

        const wsStatus = await new Promise<number>((resolveStatus) => {
          const ws = new WebSocket(`wss://127.0.0.1:${edgePort}/app/events/stream`, {
            headers: { Host: PUBLIC_HOST, Authorization: `Bearer ${creds.accessToken}` },
            agent: new HttpsAgent({ ca, servername: PUBLIC_HOST, rejectUnauthorized: true }),
          });
          const timer = setTimeout(() => {
            ws.terminate();
            resolveStatus(0);
          }, 20_000);
          ws.once("open", () => {
            clearTimeout(timer);
            ws.close();
            resolveStatus(200);
          });
          ws.once("unexpected-response", (_req, res) => {
            clearTimeout(timer);
            res.resume();
            resolveStatus(res.statusCode || 0);
          });
          ws.once("error", () => {
            clearTimeout(timer);
            resolveStatus(0);
          });
        });
        expect(wsStatus).toBe(200);

        const workspace = await httpsJson(edgePort, ca, "/workspaces", {
          method: "POST",
          token: creds.accessToken,
          body: { name: "review", cwd: "/tmp/review-workspace" },
        });
        expect([200, 201]).toContain(workspace.status);

        const owner = await httpsJson(edgePort, ca, "/me", { token: "sk_should_not_work" });
        expect(owner.status).toBe(401);

        const probe = spawnSync(
          "docker",
          [
            "exec",
            `${project}-probe`,
            "curl",
            "-sS",
            "-o",
            "/dev/null",
            "-w",
            "%{http_code}",
            "-H",
            "X-Forwarded-Proto: https",
            "-H",
            "X-Forwarded-For: 203.0.113.9",
            "http://172.28.39.20:7750/pair",
            "-X",
            "POST",
            "--data",
            "{}",
          ],
          { encoding: "utf8" },
        );
        expect(probe.stdout.trim()).not.toBe("200");

        docker(["restart", `${project}-proxy`]);
        let reconnected = false;
        const reconnectDeadline = Date.now() + 60_000;
        while (Date.now() < reconnectDeadline) {
          try {
            const health = await httpsJson(edgePort, ca, "/health");
            if (health.status === 200) {
              reconnected = true;
              break;
            }
          } catch {
            // retry
          }
          await new Promise((r) => setTimeout(r, 1000));
        }
        expect(reconnected).toBe(true);
        const meAfter = await httpsJson(edgePort, ca, "/me", { token: creds.accessToken });
        expect(meAfter.status).toBe(200);

        expect(imageSha.startsWith("sha256:") || imageSha.length > 10).toBe(true);
      } finally {
        down();
      }
    }, 300_000);
  }
});
