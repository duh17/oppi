/**
 * Canary proof for end-to-end-encrypted push (protocol/push/spec.md §6).
 *
 * Real server sealing (SessionPushNotifier → PushSender) sends session events whose session
 * name, workspace, session ID, and text are canary strings through the real relay to a mock
 * APNs: the Node adapter in capture mode, and the Cloudflare adapter in the local Workers
 * runtime (workerd via Miniflare). The canaries must appear nowhere in the relay's input,
 * logs, storage, or APNs output, in any common encoding, while the test receiver opens every
 * captured envelope back to them.
 *
 *   cd server && npx tsx scripts/push-canary.ts [--target node|cloudflare|all] [--write-capture]
 *
 * `--write-capture` records the Node run's APNs payloads in
 * protocol/push/vectors/canary-capture.json for the Apple test that decrypts them.
 * Needs `npm ci` in relay/. Real APNs and Cloudflare are not contacted.
 */

import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
} from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer, request as httpRequest, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PushSender } from "../src/push/push-sender.js";
import { ensureIdentityMaterial, identityConfigForDataDir } from "../src/security.js";
import { SessionPushNotifier } from "../src/session-push-notifier.js";
import { Storage } from "../src/storage.js";
import { openPushEnvelopeForTest } from "../tests/helpers/push-envelope-open.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const relayRoot = path.join(repoRoot, "relay");
const vectorsDir = path.join(repoRoot, "protocol/push/vectors");
const APP_ID = "AZAQMY4SPZ.dev.chenda.Oppi";
const BUNDLE_ID = "dev.chenda.Oppi";

const args = process.argv.slice(2);
const targetIndex = args.indexOf("--target");
const target = targetIndex >= 0 ? args[targetIndex + 1] : "all";
const writeCapture = args.includes("--write-capture");

interface CapturedApns {
  host: string;
  path: string;
  headers: Record<string, string>;
  payload: string;
}

interface RelayUnderTest {
  url: string;
  logs: () => string;
  storage: () => string;
  apns: () => CapturedApns[];
  close: () => Promise<void>;
}

function fail(message: string): never {
  console.error(`FAIL ${message}`);
  process.exit(1);
}

function encodings(value: string): string[] {
  const bytes = Buffer.from(value, "utf8");
  return [
    value,
    bytes.toString("base64"),
    bytes.toString("base64url"),
    bytes.toString("hex"),
    Buffer.from(value, "utf16le").toString("latin1"),
    JSON.stringify(value).slice(1, -1),
  ];
}

function readTree(dir: string): string {
  if (!existsSync(dir)) return "";
  let text = "";
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    text += statSync(full).isDirectory() ? readTree(full) : readFileSync(full).toString("latin1");
  }
  return text;
}

// ─── Relay input recorder ───

/** Forwards to the relay and records every request byte it was given: the relay's input. */
async function startRecordingProxy(
  upstream: string,
): Promise<{ url: string; input: () => string; server: Server }> {
  const chunks: Buffer[] = [];
  const upstreamUrl = new URL(upstream);
  const server = createServer((req, res) => {
    const body: Buffer[] = [];
    req.on("data", (chunk: Buffer) => body.push(chunk));
    req.on("end", () => {
      const requestBytes = Buffer.concat(body);
      chunks.push(
        Buffer.from(`${req.method} ${req.url}\n${JSON.stringify(req.headers)}\n`),
        requestBytes,
      );
      const forward = httpRequest(
        {
          host: upstreamUrl.hostname,
          port: upstreamUrl.port,
          method: req.method,
          path: req.url,
          headers: { ...req.headers, host: upstreamUrl.host },
        },
        (upstreamRes) => {
          res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
          upstreamRes.pipe(res);
        },
      );
      forward.on("error", () => {
        res.statusCode = 502;
        res.end();
      });
      forward.end(requestBytes);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    input: () => Buffer.concat(chunks).toString("latin1"),
    server,
  };
}

// ─── Relays ───

function ensureRelayBuilt(): void {
  if (!existsSync(path.join(relayRoot, "node_modules"))) fail("run `npm ci` in relay/ first");
  const build = spawnSync("npm", ["run", "build"], { cwd: relayRoot, encoding: "utf8" });
  if (build.status !== 0) fail(`relay build failed:\n${build.stdout}${build.stderr}`);
}

async function startNodeRelay(workDir: string): Promise<RelayUnderTest> {
  const capturePath = path.join(workDir, "apns.jsonl");
  const storePath = path.join(workDir, "relay-store.json");
  let logs = "";
  const child: ChildProcess = spawn(
    process.execPath,
    [path.join(relayRoot, "dist/node/main.js"), "--capture", capturePath],
    {
      env: {
        ...process.env,
        OPPI_RELAY_APP_ID: APP_ID,
        OPPI_RELAY_BUNDLE_ID: BUNDLE_ID,
        OPPI_RELAY_PORT: "0",
        OPPI_RELAY_STORE: storePath,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const url = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("relay did not start")), 15_000);
    child.stdout?.on("data", (chunk: Buffer) => {
      logs += chunk.toString();
      const match = /"url":"([^"]+)"/.exec(logs);
      if (match?.[1]) {
        clearTimeout(timer);
        resolve(match[1]);
      }
    });
    child.stderr?.on("data", (chunk: Buffer) => (logs += chunk.toString()));
    child.on("exit", (code) => reject(new Error(`relay exited ${code}: ${logs}`)));
  });
  return {
    url,
    logs: () => logs,
    storage: () => (existsSync(storePath) ? readFileSync(storePath, "latin1") : ""),
    apns: () =>
      existsSync(capturePath)
        ? readFileSync(capturePath, "utf8")
            .trim()
            .split("\n")
            .filter(Boolean)
            .map((line) => JSON.parse(line) as CapturedApns)
        : [],
    close: async () => {
      child.removeAllListeners("exit");
      child.kill("SIGTERM");
    },
  };
}

async function startCloudflareRelay(workDir: string): Promise<RelayUnderTest> {
  const bundleDir = path.join(workDir, "worker");
  const build = spawnSync(
    path.join(relayRoot, "node_modules/.bin/wrangler"),
    ["deploy", "--dry-run", "--outdir", bundleDir],
    { cwd: relayRoot, encoding: "utf8", env: { ...process.env, WRANGLER_SEND_METRICS: "false" } },
  );
  if (build.status !== 0) fail(`wrangler build failed:\n${build.stdout}${build.stderr}`);
  const miniflarePath = path.join(relayRoot, "node_modules/miniflare/dist/src/index.js");
  // Miniflare comes from relay/; the server package does not depend on it.
  const { Miniflare } = (await import(miniflarePath)) as {
    Miniflare: new (options: Record<string, unknown>) => {
      ready: Promise<URL>;
      dispose(): Promise<void>;
    };
  };
  const persistDir = path.join(workDir, "durable-objects");
  const captured: CapturedApns[] = [];
  let logs = "";
  const apnsKey = generateKeyPairSync("ec", { namedCurve: "P-256" })
    .privateKey.export({ type: "pkcs8", format: "pem" })
    .toString();
  const mf = new Miniflare({
    modules: true,
    modulesRoot: bundleDir,
    scriptPath: path.join(bundleDir, "worker.js"),
    compatibilityDate: "2025-07-01",
    durableObjects: {
      REGISTRATIONS: { className: "RegistrationObject", useSQLite: true },
      CHALLENGES: { className: "ChallengeObject", useSQLite: true },
    },
    bindings: {
      APP_ID,
      BUNDLE_ID,
      APNS_KEY_P8: apnsKey,
      APNS_KEY_ID: "CANARYKEY1",
      APNS_TEAM_ID: "CANARYTEAM",
    },
    durableObjectsPersist: persistDir,
    handleRuntimeStdio: (stdout: NodeJS.ReadableStream, stderr: NodeJS.ReadableStream) => {
      stdout.on("data", (chunk: Buffer) => (logs += chunk.toString()));
      stderr.on("data", (chunk: Buffer) => (logs += chunk.toString()));
    },
    outboundService: async (request: Request) => {
      const url = new URL(request.url);
      const headers: Record<string, string> = {};
      request.headers.forEach((value, name) => {
        if (name.startsWith("apns-")) headers[name] = value;
      });
      captured.push({ host: url.host, path: url.pathname, headers, payload: await request.text() });
      return new Response("", { status: 200 });
    },
  });
  const url = (await mf.ready).toString().replace(/\/$/, "");
  return {
    url,
    logs: () => logs,
    storage: () => readTree(persistDir),
    apns: () => captured,
    close: () => mf.dispose(),
  };
}

// ─── App side (what the phone does at the relay) ───

async function mintSendToken(relay: string): Promise<string> {
  const challenge = (await (await fetch(`${relay}/v1/challenge`, { method: "POST" })).json()) as {
    challenge: string;
  };
  const registration = (await (
    await fetch(`${relay}/v1/registrations`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        challenge: challenge.challenge,
        apnsToken: "c".repeat(64),
        environment: "sandbox",
        attestation: null,
      }),
    })
  ).json()) as { registrationId: string; registrationSecret: string };
  const permission = (await (
    await fetch(`${relay}/v1/registrations/${registration.registrationId}/permissions`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${registration.registrationSecret}`,
        "content-type": "application/json",
      },
      body: "{}",
    })
  ).json()) as { sendToken?: string };
  if (!permission.sendToken) fail("relay did not mint a send token");
  return permission.sendToken;
}

// ─── Run ───

interface CanaryRun {
  canaries: Record<string, string>;
  apns: CapturedApns[];
  serverPublicKey: string;
  now: number;
}

async function runCanary(
  name: string,
  start: (workDir: string) => Promise<RelayUnderTest>,
): Promise<CanaryRun> {
  const workDir = mkdtempSync(path.join(tmpdir(), `oppi-push-canary-${name}-`));
  const relay = await start(workDir);
  const proxy = await startRecordingProxy(relay.url);
  const tag = randomBytes(6).toString("hex");
  const canaries = {
    sessionName: `CANARY-NAME-${tag}`,
    sessionId: `canary-session-${tag}`,
    workspaceId: `canary-workspace-${tag}`,
    endedReason: `CANARY-REASON-${tag}`,
  };
  try {
    const dataDir = path.join(workDir, "server");
    const storage = new Storage(dataDir);
    storage.ensurePaired();
    const deviceJwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({
      format: "jwk",
    });
    const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
      publicKey: { kty: "EC", crv: "P-256", x: deviceJwk.x, y: deviceJwk.y },
    });
    if (!enrolled) fail("enrollment failed");
    const vectors = JSON.parse(
      readFileSync(path.join(vectorsDir, "cryptokit-hpke.json"), "utf8"),
    ) as {
      recipient: { seed: string; publicKey: string; keyId: string };
    };
    storage.updateConfig({ push: { mode: "relay", relays: [proxy.url] } });
    storage.setPushRegistration({
      deviceId: enrolled.deviceId,
      keyId: vectors.recipient.keyId,
      publicKey: vectors.recipient.publicKey,
      sendToken: await mintSendToken(proxy.url),
    });
    const session = storage.createSession(canaries.sessionName, undefined, {
      id: canaries.sessionId,
    });
    storage.saveSession({ ...session, workspaceId: canaries.workspaceId });

    const identity = ensureIdentityMaterial(identityConfigForDataDir(dataDir));
    const sender = new PushSender(storage, {
      signingKey: createPrivateKey(identity.privateKeyPem),
    });
    const results: Array<Promise<unknown>> = [];
    const tracking = new Proxy(sender, {
      get(targetSender, property, receiver) {
        if (property === "send") {
          return (...sendArgs: Parameters<PushSender["send"]>) => {
            const result = targetSender.send(...sendArgs);
            results.push(result);
            return result;
          };
        }
        return Reflect.get(targetSender, property, receiver) as unknown;
      },
    });
    const notifier = new SessionPushNotifier(tracking, storage, { isDevicePresent: () => false });
    const current = storage.getSession(canaries.sessionId);
    if (!current) fail("session missing");
    notifier.handleProgramStatusChange(current, {
      previous: { state: "working", since: 1 },
      current: { state: "blocked", kind: "permission", message: canaries.sessionName, since: 2 },
      changed: true,
    });
    notifier.handleProgramStatusChange(current, {
      previous: { state: "working", since: 3 },
      current: { state: "done", since: 4 },
      changed: true,
    });
    notifier.handleSessionEvent({
      sessionId: canaries.sessionId,
      event: { type: "error", error: `${canaries.sessionName} crashed` },
      durable: true,
    });
    notifier.handleSessionEvent({
      sessionId: canaries.sessionId,
      event: { type: "session_ended", reason: canaries.endedReason },
      durable: true,
    });
    const settled = (await Promise.all(results)) as Array<{ status: string } | null>;
    if (settled.length !== 4 || settled.some((result) => result?.status !== "delivered")) {
      fail(`${name}: expected 4 delivered pushes, got ${JSON.stringify(settled)}`);
    }

    const apns = relay.apns();
    if (apns.length !== 4) fail(`${name}: expected 4 APNs requests, saw ${apns.length}`);
    const surfaces = {
      "relay input": proxy.input(),
      "relay logs": relay.logs(),
      "relay storage": relay.storage(),
      "APNs output": JSON.stringify(apns),
    };
    for (const [surface, text] of Object.entries(surfaces)) {
      for (const [label, canary] of Object.entries(canaries)) {
        for (const encoded of encodings(canary)) {
          if (text.includes(encoded)) fail(`${name}: ${label} canary found in ${surface}`);
        }
      }
    }

    // Not vacuous: each captured payload is the fixed template around an envelope that the
    // phone's key opens back to the canaries.
    const serverPublicKey = createPublicKey(identity.publicKeyPem);
    const opened = [];
    for (const request of apns) {
      const payload = JSON.parse(request.payload) as { aps: unknown; e: string };
      const fixedAps = {
        alert: { title: "Oppi", body: "You have a new notification." },
        "mutable-content": 1,
      };
      if (
        JSON.stringify(payload.aps) !== JSON.stringify(fixedAps) ||
        Object.keys(payload).length !== 2
      ) {
        fail(`${name}: APNs payload is not the fixed template`);
      }
      opened.push(
        await openPushEnvelopeForTest(payload.e, {
          recipientSeed: Buffer.from(vectors.recipient.seed, "base64url"),
          serverPublicKey: serverPublicKey,
        }),
      );
    }
    const decrypted = JSON.stringify(opened);
    for (const [label, canary] of Object.entries(canaries)) {
      if (!decrypted.includes(canary)) fail(`${name}: ${label} canary did not survive encryption`);
    }
    console.log(
      `PASS ${name}: 4 pushes; canaries absent from relay input (${surfaces["relay input"].length} B), logs (${surfaces["relay logs"].length} B), storage (${surfaces["relay storage"].length} B), APNs output (${surfaces["APNs output"].length} B); all 4 envelopes open to them`,
    );
    return {
      canaries,
      apns,
      serverPublicKey: identity.publicKeyRaw,
      now: Date.now(),
    };
  } finally {
    proxy.server.close();
    await relay.close();
    rmSync(workDir, { recursive: true, force: true });
  }
}

ensureRelayBuilt();
let nodeRun: CanaryRun | undefined;
if (target === "node" || target === "all") nodeRun = await runCanary("node", startNodeRelay);
if (target === "cloudflare" || target === "all")
  await runCanary("cloudflare-local", startCloudflareRelay);

if (writeCapture) {
  if (!nodeRun) fail("--write-capture needs the node target");
  const fixture = {
    _meta: {
      description:
        "APNs payloads captured from the node relay in scripts/push-canary.ts. Apple tests decrypt them with the cryptokit-hpke.json recipient key. Test keys only.",
      generator: "server/scripts/push-canary.ts --write-capture",
    },
    now: nodeRun.now,
    serverPublicKey: nodeRun.serverPublicKey,
    serverFingerprint: `sha256:${createHash("sha256").update(Buffer.from(nodeRun.serverPublicKey, "base64url")).digest("base64url")}`,
    canaries: nodeRun.canaries,
    apnsPayloads: nodeRun.apns.map((request) => request.payload),
  };
  writeFileSync(
    path.join(vectorsDir, "canary-capture.json"),
    `${JSON.stringify(fixture, null, 2)}\n`,
  );
  console.log("wrote protocol/push/vectors/canary-capture.json");
}
