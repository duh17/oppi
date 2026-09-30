/**
 * Real Oppi server + real HTTP for GET /server/provider-quotas with the OpenAI Codex plan opt-in.
 *
 * Only the ChatGPT usage endpoint is faked: a local HTTP server stands in for chatgpt.com and
 * records every request. Credentials are synthetic and live in an isolated Pi agent dir.
 */
import { createServer, type IncomingHttpHeaders, type Server as HttpServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { runCli } from "../src/cli/runner.js";
import { createCliConfigStorage } from "../src/cli/connection-config.js";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { ProviderQuotasStatus } from "../src/provider-quota.js";

const LEGACY_TOKEN = "synthetic-legacy-codex-token";
const OFFICIAL_TOKEN = "synthetic-official-chatgpt-token";
const USAGE_PATH = "/backend-api/wham/usage";

let dataDir: string;
let agentDir: string;
let storage: Storage;
let server: Server;
let baseUrl: string;
let token: string;
let usage: HttpServer;
let usageOrigin: string;
let usageRequests: Array<{ path: string; headers: IncomingHttpHeaders }> = [];
let previous: { agentDir?: string; tls?: string; fetch: typeof fetch };

function devicePublicKey(): { kty: string; crv: string; x: string; y: string } {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

async function getQuotas(): Promise<ProviderQuotasStatus> {
  const res = await fetch(`${baseUrl}/server/provider-quotas`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(res.status).toBe(200);
  return (await res.json()) as ProviderQuotasStatus;
}

/** `oppi config set`, run through the real CLI command against its own config owner. */
async function cliSetOptIn(on: boolean): Promise<unknown> {
  const result = await runCli(
    ["config", "set", "providerQuotas.openaiUseCodexPlan", on ? "true" : "false"],
    { dataDir, captureHuman: true, forceJson: true },
  );
  expect(result.ok).toBe(true);
  return JSON.parse(result.stdout);
}

async function startServer(): Promise<void> {
  storage = new Storage(dataDir);
  server = new Server(storage);
  await server.start();
  baseUrl = `https://127.0.0.1:${server.port}`;
}

beforeAll(async () => {
  previous = {
    agentDir: process.env.PI_CODING_AGENT_DIR,
    tls: process.env.NODE_TLS_REJECT_UNAUTHORIZED,
    fetch: globalThis.fetch,
  };

  agentDir = mkdtempSync(join(tmpdir(), "oppi-quota-agent-"));
  mkdirSync(agentDir, { recursive: true });
  const farFuture = Date.now() + 365 * 24 * 60 * 60 * 1000;
  writeFileSync(
    join(agentDir, "auth.json"),
    JSON.stringify({
      "openai-codex": { type: "oauth", access: LEGACY_TOKEN, refresh: "r1", expires: farFuture },
      openai: { type: "oauth", access: OFFICIAL_TOKEN, refresh: "r2", expires: farFuture },
    }),
  );
  process.env.PI_CODING_AGENT_DIR = agentDir;
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

  const reset = Math.floor(Date.now() / 1000);
  usage = createServer((req, res) => {
    usageRequests.push({ path: req.url ?? "", headers: req.headers });
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        plan_type: "plus",
        // Non-null so the test proves the official plan row drops credits.
        credits: { has_credits: true, unlimited: false, balance: "12.50" },
        rate_limit: {
          primary_window: {
            used_percent: 25,
            limit_window_seconds: 18_000,
            reset_at: reset + 3_600,
          },
          secondary_window: {
            used_percent: 50,
            limit_window_seconds: 604_800,
            reset_at: reset + 86_400,
          },
        },
      }),
    );
  });
  await new Promise<void>((resolve) => usage.listen(0, "127.0.0.1", resolve));
  const address = usage.address();
  if (!address || typeof address === "string") throw new Error("usage server did not bind");
  usageOrigin = `http://127.0.0.1:${address.port}`;

  // Redirect only chatgpt.com to the local stand-in; everything else is untouched.
  const realFetch = previous.fetch;
  vi.stubGlobal("fetch", ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    return url.startsWith("https://chatgpt.com/")
      ? realFetch(url.replace("https://chatgpt.com", usageOrigin), init)
      : realFetch(input, init);
  }) as typeof fetch);

  dataDir = mkdtempSync(join(tmpdir(), "oppi-quota-plan-"));
  storage = new Storage(dataDir);
  storage.updateConfig({ port: 0, host: "127.0.0.1", tls: { mode: "self-signed" } });
  storage.ensurePaired();
  const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: devicePublicKey(),
    name: "quota-plan",
  });
  if (!enrolled) throw new Error("enrollment failed");
  token = enrolled.accessToken;
  await startServer();
}, 30_000);

afterAll(async () => {
  await server?.stop().catch(() => {});
  await new Promise<void>((resolve) => usage?.close(() => resolve()));
  vi.unstubAllGlobals();
  if (previous.agentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previous.agentDir;
  if (previous.tls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous.tls;
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(agentDir, { recursive: true, force: true });
}, 45_000);

describe("GET /server/provider-quotas OpenAI Codex plan opt-in", () => {
  it("keeps official OpenAI unknown by default; the CLI opt-in applies after a server restart", async () => {
    usageRequests = [];
    const off = await getQuotas();
    const offOfficial = off.providers.find((p) => p.providerId === "openai");
    expect(offOfficial).toMatchObject({ displayName: "OpenAI", authenticated: true, windows: [] });
    expect(offOfficial?.error).toContain("https://chatgpt.com/settings/usage");
    expect(usageRequests).toHaveLength(1);

    // `oppi config set` runs in another process with its own config owner. It persists the
    // value and says a restart is needed, but the running server keeps its startup config.
    const set = await cliSetOptIn(true);
    expect(set).toMatchObject({
      ok: true,
      data: {
        key: "providerQuotas.openaiUseCodexPlan",
        value: true,
        restartHint: "Restart the Oppi server for this change to take effect.",
      },
    });
    expect(createCliConfigStorage(dataDir).getConfig().providerQuotas).toEqual({
      openaiUseCodexPlan: true,
    });

    usageRequests = [];
    const stillOff = await getQuotas();
    expect(stillOff.providers.find((p) => p.providerId === "openai")).toMatchObject({
      displayName: "OpenAI",
      windows: [],
    });
    expect(usageRequests).toHaveLength(1);

    await server.stop();
    await startServer();

    usageRequests = [];
    const on = await getQuotas();
    const legacy = on.providers.find((p) => p.providerId === "openai-codex");
    const official = on.providers.find((p) => p.providerId === "openai");
    expect(legacy).toMatchObject({
      displayName: "Codex",
      planType: "plus",
      credits: { hasCredits: true, unlimited: false, balance: "12.50" },
    });
    expect(official).toMatchObject({
      displayName: "OpenAI (ChatGPT plan via legacy Codex)",
      authenticated: true,
      planType: "plus",
      credits: null,
      windows: [
        { shortLabel: "Plan 5h", title: "5-hour plan (via legacy Codex)", remainingPercent: 75 },
        { shortLabel: "Plan 7d", title: "Weekly plan (via legacy Codex)", remainingPercent: 50 },
      ],
    });
    expect(official?.error).toBeUndefined();

    // One upstream request, authenticated with only the legacy token.
    expect(usageRequests).toHaveLength(1);
    expect(usageRequests[0]?.path).toBe(USAGE_PATH);
    expect(usageRequests[0]?.headers.authorization).toBe(`Bearer ${LEGACY_TOKEN}`);
    expect(JSON.stringify(usageRequests)).not.toContain(OFFICIAL_TOKEN);

    // Turning it off is the same: the running server keeps the opt-in until it restarts.
    await cliSetOptIn(false);
    expect((await getQuotas()).providers.find((p) => p.providerId === "openai")).toMatchObject({
      displayName: "OpenAI (ChatGPT plan via legacy Codex)",
    });
    await server.stop();
    await startServer();
    expect((await getQuotas()).providers.find((p) => p.providerId === "openai")).toMatchObject({
      displayName: "OpenAI",
      windows: [],
    });
  }, 60_000);
});
