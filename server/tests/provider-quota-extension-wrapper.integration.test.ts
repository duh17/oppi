/**
 * Real Oppi server + real HTTP + real global Pi extension loading for GET /server/provider-quotas.
 *
 * A stream-only `registerProvider("openai", { api, streamSimple })` extension inherits the
 * built-in auth, catalog and endpoint, so it must not hide the built-in quota row. Extensions that
 * bring their own endpoint, auth or native provider still own their provider id. Credentials are
 * synthetic, the Pi agent dir is isolated, and a local HTTP server stands in for the usage API.
 */
import { createServer, type IncomingHttpHeaders, type Server as HttpServer } from "node:http";
import { generateKeyPairSync } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { ModelRuntime } from "@earendil-works/pi-coding-agent";
import { Server } from "../src/server.js";
import { Storage } from "../src/storage.js";
import type { ProviderQuotasStatus } from "../src/provider-quota.js";

const LEGACY_TOKEN = "synthetic-legacy-codex-token";
const OFFICIAL_TOKEN = "synthetic-official-chatgpt-token";

/** Same registration shape as a real global OpenAI stream-wrapper extension. */
const OPENAI_STREAM_WRAPPER = `
export default function (pi) {
  pi.registerProvider("openai", {
    api: "openai-responses",
    streamSimple: () => { throw new Error("not called by the quota test"); },
  });
}
`;

const CUSTOM_ENDPOINT_XAI = `
export default function (pi) {
  pi.registerProvider("xai", {
    name: "Other xAI",
    api: "openai-completions",
    baseUrl: "https://api.other-xai.test/v1",
    apiKey: "synthetic-other-xai-key",
    models: [{
      id: "other", name: "other", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100,
    }],
  });
}
`;

const NATIVE_OPENCODE_GO = `
export default function (pi) {
  pi.registerProvider({
    id: "opencode-go", name: "Native OpenCode Go", getModels: () => [],
    auth: { apiKey: { name: "key", resolve: async () => undefined } },
  });
}
`;

const OPENAI_WRAPPER_WITH_OWN_QUOTA = `
export default function (pi) {
  pi.registerProvider("openai", {
    api: "openai-responses",
    streamSimple: () => { throw new Error("not called by the quota test"); },
  });
  pi.events.emit("oppi:provider-quota:v1", {
    providerId: "openai",
    displayName: "OpenAI (extension quota)",
    fetch: async () => ({
      authenticated: true,
      planType: "extension",
      windows: [{
        key: "ext", shortLabel: "Ext", title: "Extension window", usedPercent: 10,
        limitWindowSeconds: 3600, resetAt: null, includeWeekdayInReset: false,
      }],
    }),
  });
}
`;

let usage: HttpServer;
let usageOrigin: string;
let usageRequests: Array<{ path: string; headers: IncomingHttpHeaders }> = [];
let previous: { agentDir?: string; tls?: string; fetch: typeof fetch };
const cleanups: Array<() => Promise<void> | void> = [];

function devicePublicKey(): { kty: string; crv: string; x: string; y: string } {
  const { publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" }) as { x: string; y: string };
  return { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y };
}

interface Scenario {
  quotas(): Promise<ProviderQuotasStatus>;
  modelRuntime: ModelRuntime;
}

/** Boot a real server whose isolated Pi agent dir holds the given global extensions. */
async function startScenario(extensions: Record<string, string>): Promise<Scenario> {
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-quota-wrapper-agent-"));
  const extensionsDir = join(agentDir, "extensions");
  mkdirSync(extensionsDir, { recursive: true });
  for (const [name, source] of Object.entries(extensions)) {
    writeFileSync(join(extensionsDir, `${name}.ts`), source);
  }
  const farFuture = Date.now() + 365 * 24 * 60 * 60 * 1000;
  writeFileSync(
    join(agentDir, "auth.json"),
    JSON.stringify({
      "openai-codex": { type: "oauth", access: LEGACY_TOKEN, refresh: "r1", expires: farFuture },
      openai: { type: "oauth", access: OFFICIAL_TOKEN, refresh: "r2", expires: farFuture },
    }),
  );
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const dataDir = mkdtempSync(join(tmpdir(), "oppi-quota-wrapper-data-"));
  const storage = new Storage(dataDir);
  storage.updateConfig({
    port: 0,
    host: "127.0.0.1",
    tls: { mode: "self-signed" },
    providerQuotas: { openaiUseCodexPlan: true },
  });
  storage.ensurePaired();
  const enrolled = storage.enrollViaPairing(storage.issuePairingToken(), {
    publicKey: devicePublicKey(),
    name: "quota-wrapper",
  });
  if (!enrolled) throw new Error("enrollment failed");
  const server = new Server(storage);
  await server.start();
  cleanups.push(async () => {
    await server.stop().catch(() => {});
    rmSync(dataDir, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
  });

  const baseUrl = `https://127.0.0.1:${server.port}`;
  return {
    modelRuntime: (server as unknown as { modelRuntime: ModelRuntime }).modelRuntime,
    async quotas() {
      const res = await fetch(`${baseUrl}/server/provider-quotas`, {
        headers: { Authorization: `Bearer ${enrolled.accessToken}` },
      });
      expect(res.status).toBe(200);
      return (await res.json()) as ProviderQuotasStatus;
    },
  };
}

beforeAll(async () => {
  previous = {
    agentDir: process.env.PI_CODING_AGENT_DIR,
    tls: process.env.NODE_TLS_REJECT_UNAUTHORIZED,
    fetch: globalThis.fetch,
  };
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";

  const reset = Math.floor(Date.now() / 1000);
  usage = createServer((req, res) => {
    usageRequests.push({ path: req.url ?? "", headers: req.headers });
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify({
        plan_type: "plus",
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
}, 30_000);

afterEach(async () => {
  usageRequests = [];
  while (cleanups.length > 0) await cleanups.pop()?.();
}, 30_000);

afterAll(async () => {
  await new Promise<void>((resolve) => usage?.close(() => resolve()));
  vi.unstubAllGlobals();
  if (previous.agentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previous.agentDir;
  if (previous.tls === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED;
  else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous.tls;
});

describe("GET /server/provider-quotas with global provider extensions", () => {
  it("shows labelled plan quota for official OpenAI behind a stream-only wrapper, while custom providers stay excluded", async () => {
    const scenario = await startScenario({
      "openai-wrapper": OPENAI_STREAM_WRAPPER,
      "custom-xai": CUSTOM_ENDPOINT_XAI,
      "native-opencode-go": NATIVE_OPENCODE_GO,
    });

    const quotas = await scenario.quotas();
    const wrapper = scenario.modelRuntime.getRegisteredProviderConfig("openai");
    expect(typeof wrapper?.streamSimple).toBe("function");
    expect(scenario.modelRuntime.getRegisteredProviderConfig("xai")?.baseUrl).toBe(
      "https://api.other-xai.test/v1",
    );
    expect(scenario.modelRuntime.getRegisteredNativeProvider("opencode-go")).toBeDefined();

    const openai = quotas.providers.filter((p) => p.providerId === "openai");
    expect(openai).toHaveLength(1);
    expect(openai[0]).toMatchObject({
      displayName: "OpenAI (ChatGPT plan via legacy Codex)",
      authenticated: true,
      planType: "plus",
      windows: [
        { shortLabel: "Plan 5h", remainingPercent: 75 },
        { shortLabel: "Plan 7d", remainingPercent: 50 },
      ],
    });
    expect(openai[0]?.error).toBeUndefined();
    expect(quotas.providers.map((p) => p.providerId).sort()).toEqual(["openai", "openai-codex"]);

    // One legacy-only usage call; the official token never leaves the machine.
    expect(usageRequests).toHaveLength(1);
    expect(usageRequests[0]?.headers.authorization).toBe(`Bearer ${LEGACY_TOKEN}`);
    expect(JSON.stringify(usageRequests)).not.toContain(OFFICIAL_TOKEN);
  }, 60_000);

  it("prefers an explicit extension quota source over the built-in row for a wrapper id", async () => {
    const scenario = await startScenario({ "openai-wrapper": OPENAI_WRAPPER_WITH_OWN_QUOTA });

    const quotas = await scenario.quotas();
    expect(typeof scenario.modelRuntime.getRegisteredProviderConfig("openai")?.streamSimple).toBe(
      "function",
    );
    const openai = quotas.providers.filter((p) => p.providerId === "openai");
    expect(openai).toHaveLength(1);
    expect(openai[0]).toMatchObject({
      displayName: "OpenAI (extension quota)",
      planType: "extension",
    });
    expect(usageRequests).toHaveLength(1);
  }, 60_000);
});
