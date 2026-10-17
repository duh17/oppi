/**
 * The shared suite against the Cloudflare adapter in the local Workers runtime (workerd via
 * Miniflare), with SQLite-backed Durable Objects persisted to a temp directory and APNs
 * replaced by Miniflare's outbound service. Real Cloudflare and real APNs are not exercised.
 */

import { spawnSync } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { afterAll, beforeAll } from "vitest";
import { APP_ID, BUNDLE_ID, defineRelaySuite, type CapturedApnsRequest, type RelayHarness } from "./suite/relay-suite.js";

const relayRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
let bundleDir: string;

beforeAll(() => {
  bundleDir = mkdtempSync(join(tmpdir(), "oppi-relay-worker-"));
  // The same bundle `wrangler deploy` would upload, built without contacting Cloudflare.
  const build = spawnSync(
    join(relayRoot, "node_modules/.bin/wrangler"),
    ["deploy", "--dry-run", "--outdir", bundleDir],
    { cwd: relayRoot, encoding: "utf8", env: { ...process.env, WRANGLER_SEND_METRICS: "false" } },
  );
  if (build.status !== 0) throw new Error(`wrangler build failed:\n${build.stdout}\n${build.stderr}`);
}, 120_000);

afterAll(() => rmSync(bundleDir, { recursive: true, force: true }));

function readTree(dir: string): string {
  let text = "";
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    text += statSync(path).isDirectory() ? readTree(path) : readFileSync(path).toString("latin1");
  }
  return text;
}

const apnsKeyP8 = generateKeyPairSync("ec", { namedCurve: "P-256" })
  .privateKey.export({ type: "pkcs8", format: "pem" })
  .toString();

async function startHarness(): Promise<RelayHarness> {
  const persistDir = mkdtempSync(join(tmpdir(), "oppi-relay-do-"));
  const apnsRequests: CapturedApnsRequest[] = [];
  const logs: string[] = [];
  let handler: (request: CapturedApnsRequest) => { status: number; reason?: string } = () => ({ status: 200 });
  const mf = new Miniflare({
    modules: true,
    modulesRoot: bundleDir,
    scriptPath: join(bundleDir, "worker.js"),
    // The newest date this Miniflare's workerd supports; the Worker needs no newer flags.
    compatibilityDate: "2025-07-01",
    durableObjects: {
      REGISTRATIONS: { className: "RegistrationObject", useSQLite: true },
      CHALLENGES: { className: "ChallengeObject", useSQLite: true },
      APNS_TOKENS: { className: "ApnsTokenObject", useSQLite: true },
    },
    bindings: {
      APP_ID,
      BUNDLE_ID,
      APNS_KEY_P8: apnsKeyP8,
      APNS_KEY_ID: "KEYID12345",
      APNS_TEAM_ID: "TESTTEAM01",
    },
    durableObjectsPersist: persistDir,
    stripCfConnectingIp: false,
    handleRuntimeStdio: (stdout: Readable, stderr: Readable) => {
      for (const stream of [stdout, stderr]) stream.on("data", (chunk: Buffer) => logs.push(chunk.toString()));
    },
    outboundService: async (request: Request) => {
      const url = new URL(request.url);
      const headers: Record<string, string> = {};
      request.headers.forEach((value, name) => {
        if (name.startsWith("apns-")) headers[name] = value;
      });
      const captured = { host: url.host, path: url.pathname, headers, payload: await request.text() };
      apnsRequests.push(captured);
      const result = handler(captured);
      return new Response(result.reason ? JSON.stringify({ reason: result.reason }) : "", {
        status: result.status,
      });
    },
  });
  const url = (await mf.ready).toString().replace(/\/$/, "");
  return {
    url,
    apnsRequests,
    respondApns: (next) => {
      handler = next;
    },
    storageText: async () => readTree(persistDir),
    logs,
    close: async () => {
      await mf.dispose();
      rmSync(persistDir, { recursive: true, force: true });
    },
  };
}

defineRelaySuite("cloudflare local", startHarness);
