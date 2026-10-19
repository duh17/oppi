import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { ReadAloudLiveVoiceTts } from "../src/continuous-voice-media.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import { createSpeechRoutes } from "../src/routes/speech.js";
import type { RouteContext } from "../src/routes/types.js";
import { ConfigStore } from "../src/storage/config-store.js";
import type { ServerConfig } from "../src/types.js";
import {
  VoiceBackendHealth,
  type VoiceBackendHealthDeps,
  type VoiceBackendHealthEntry,
  type VoiceFeature,
} from "../src/voice-backend-health.js";
import { makeResponse } from "./harness/route-test-helpers.js";

type VoiceConfig = Pick<ServerConfig, "asr" | "tts">;
type Handler = (req: IncomingMessage, res: ServerResponse) => void;

const servers = new Set<Server>();
const tempDirs: string[] = [];

beforeEach(() => vi.stubEnv("XAI_API_KEY", ""));
afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all([...servers].map((server) => stop(server)));
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** A fake backend on 127.0.0.1 that counts the requests it receives. */
async function backend(
  handler: Handler = (_req, res) => res.end("ok"),
  port = 0,
): Promise<{ url: string; port: number; server: Server; requests: () => number }> {
  let requests = 0;
  const server = createServer((req, res) => {
    requests += 1;
    handler(req, res);
  });
  servers.add(server);
  await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
  const bound = (server.address() as AddressInfo).port;
  return { url: `http://127.0.0.1:${bound}`, port: bound, server, requests: () => requests };
}

async function stop(server: Server): Promise<void> {
  servers.delete(server);
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
}

/** A port nothing listens on. */
async function deadEndpoint(): Promise<{ url: string; port: number }> {
  const { url, port, server } = await backend();
  await stop(server);
  return { url, port };
}

function health(
  config: { loaded?: VoiceConfig; voice?: VoiceConfig },
  deps: Partial<VoiceBackendHealthDeps> = {},
): VoiceBackendHealth {
  return new VoiceBackendHealth({
    loadedConfig: () => config.loaded ?? {},
    voiceConfig: () => config.voice ?? config.loaded ?? {},
    ...deps,
  });
}

function routeContext(
  voiceBackendHealth: VoiceBackendHealth,
  tts?: VoiceConfig["tts"],
): RouteContext {
  return {
    voiceBackendHealth,
    storage: {
      getConfig: () => ({ configVersion: 2, tts }),
      listWorkspaces: () => [],
      listSessions: () => [],
      getDataDir: () => tmpdir(),
    },
    sessions: { durableSessionsAvailable: () => false, conversationStreamAvailable: () => false },
    sessionRuntimes: { getActiveSessionIds: () => new Set() },
    skillRegistry: { list: () => [] },
    getModelCatalog: () => [],
    serverStartedAt: Date.now(),
    serverVersion: "test",
    piVersion: "test",
  } as unknown as RouteContext;
}

interface ServerInfoVoice {
  capabilities: Partial<Record<"dictationStream" | "speech" | "liveVoice", { version: number }>>;
  voiceBackends: VoiceBackendHealthEntry[];
}

async function serverInfo(owner: VoiceBackendHealth): Promise<ServerInfoVoice> {
  const res = makeResponse();
  await createIdentityRoutes(
    routeContext(owner),
    createRouteHelpers(),
  )({
    method: "GET",
    path: "/server/info",
    url: new URL("http://localhost/server/info"),
    req: {} as never,
    res: res as never,
  });
  expect(res.statusCode).toBe(200);
  const body = JSON.parse(res.body) as ServerInfoVoice;
  // Only the voice capabilities; the rest of /server/info is not this owner's.
  const { dictationStream, speech, liveVoice } = body.capabilities;
  return {
    voiceBackends: body.voiceBackends,
    capabilities: JSON.parse(
      JSON.stringify({ dictationStream, speech, liveVoice }),
    ) as ServerInfoVoice["capabilities"],
  };
}

function feature(info: ServerInfoVoice, name: VoiceFeature): VoiceBackendHealthEntry {
  const found = info.voiceBackends.find((entry) => entry.feature === name);
  if (!found) throw new Error(`no ${name} entry`);
  return found;
}

const signedIn = async () => ({ auth: { apiKey: "xai-test-key" } });
const signedOut = async () => undefined;

describe("voice backend health in GET /server/info", () => {
  it("advertises a feature exactly when its backend is ready", async () => {
    const asr = await backend();
    const tts = await deadEndpoint();
    const owner = health(
      {
        loaded: { asr: { sttEndpoint: asr.url }, tts: { provider: "http", endpoint: tts.url } },
        voice: { asr: { liveVoiceBackend: "grok-voice" } },
      },
      { getAuth: signedOut },
    );

    // Nothing probed yet: HTTP backends read `checking` and are not advertised.
    const cold = await serverInfo(owner);
    expect(
      cold.voiceBackends.map(({ feature, label, state, target }) => ({
        feature,
        label,
        state,
        target,
      })),
    ).toEqual([
      { feature: "dictation", label: "Dictation", state: "checking", target: asr.url },
      { feature: "speech", label: "Read aloud", state: "checking", target: tts.url },
      { feature: "liveVoice", label: "Live Voice", state: "needs_credentials", target: "xAI" },
    ]);
    expect(cold.capabilities).toEqual({});

    await owner.refresh();
    const warm = await serverInfo(owner);
    expect(feature(warm, "dictation")).toMatchObject({
      state: "ready",
      checkedAt: expect.any(Number),
    });
    expect(feature(warm, "dictation").detail).toBeUndefined();
    expect(feature(warm, "speech")).toMatchObject({
      state: "unreachable",
      detail: `connect ECONNREFUSED 127.0.0.1:${tts.port}`,
    });
    expect(warm.capabilities).toEqual({ dictationStream: { version: 1 } });
  });

  it("reports features without a backend as not configured", async () => {
    const info = await serverInfo(
      health({
        loaded: {
          // Leftover pi-extension keys and removed OpenAI providers name no backend.
          asr: { backend: "pi-extension", extension: "x" } as unknown as VoiceConfig["asr"],
          tts: { provider: "http" },
        },
        voice: { asr: { liveVoiceBackend: "yuwp", sttEndpoint: "  " } },
      }),
    );
    expect(info.voiceBackends.map((entry) => entry.state)).toEqual([
      "not_configured",
      "not_configured",
      "not_configured",
    ]);
    expect(info.capabilities).toEqual({});
    const removed = await serverInfo(
      health({ loaded: { asr: { provider: "openai" } as unknown as VoiceConfig["asr"] } }),
    );
    expect(feature(removed, "dictation").state).toBe("not_configured");
  });

  it("never waits on a probe: a hanging backend reads checking, then unreachable", async () => {
    const hanging = await backend(() => {
      // Accept the request and never answer.
    });
    const owner = health(
      { loaded: { tts: { provider: "http", endpoint: hanging.url } } },
      { timeoutMs: 400 },
    );

    const started = performance.now();
    const first = await serverInfo(owner);
    expect(performance.now() - started).toBeLessThan(200);
    expect(feature(first, "speech").state).toBe("checking");
    expect(first.capabilities.speech).toBeUndefined();

    await owner.refresh();
    const later = await serverInfo(owner);
    expect(feature(later, "speech")).toMatchObject({
      state: "unreachable",
      detail: "No answer within 400 ms",
    });
    expect(hanging.requests()).toBe(1);
  });

  it("goes down, stays cached within the TTL, and comes back after it", async () => {
    let now = 1_000_000;
    const dead = await deadEndpoint();
    const owner = health(
      { loaded: { tts: { provider: "http", endpoint: dead.url } } },
      { now: () => now, ttlMs: 15_000 },
    );
    await owner.refresh();
    expect(feature(await serverInfo(owner), "speech")).toMatchObject({
      state: "unreachable",
      checkedAt: 1_000_000,
    });

    const revived = await backend(undefined, dead.port);
    now += 14_999;
    await owner.refresh();
    // Within the TTL the cached result stands and nothing is probed.
    expect(feature(await serverInfo(owner), "speech").state).toBe("unreachable");
    expect(revived.requests()).toBe(0);

    now += 1;
    // Stale: this read still serves the cached result and starts a probe.
    expect(feature(await serverInfo(owner), "speech").state).toBe("unreachable");
    await owner.refresh();
    const back = await serverInfo(owner);
    expect(feature(back, "speech")).toMatchObject({ state: "ready", checkedAt: now });
    expect(back.capabilities.speech).toEqual({ version: 1 });
    expect(revived.requests()).toBe(1);
  });

  it("caches a ready backend for the TTL and reprobes once stale", async () => {
    let now = 0;
    const tts = await backend((_req, res) => {
      // Any HTTP status means the backend answered.
      res.writeHead(404);
      res.end();
    });
    const owner = health(
      { loaded: { tts: { provider: "http", endpoint: `${tts.url}/some/path` } } },
      { now: () => now, ttlMs: 15_000 },
    );
    await owner.refresh();
    for (let i = 0; i < 3; i++) {
      expect(feature(await serverInfo(owner), "speech").state).toBe("ready");
    }
    expect(tts.requests()).toBe(1);

    now = 15_000;
    await serverInfo(owner);
    await owner.refresh();
    expect(tts.requests()).toBe(2);
  });

  it("shares one in-flight probe across readers and features on the same origin", async () => {
    const asr = await backend((_req, res) => {
      setTimeout(() => res.end("ok"), 50);
    });
    const owner = health({
      loaded: { asr: { sttEndpoint: asr.url } },
      voice: { asr: { liveVoiceBackend: "yuwp", sttEndpoint: `${asr.url}/` } },
    });

    const infos = await Promise.all([serverInfo(owner), serverInfo(owner), serverInfo(owner)]);
    for (const info of infos) {
      expect(feature(info, "dictation").state).toBe("checking");
      expect(feature(info, "liveVoice").state).toBe("checking");
    }
    await Promise.all([owner.refresh(), owner.refresh()]);
    expect(asr.requests()).toBe(1);

    const settled = await serverInfo(owner);
    expect(settled.capabilities).toEqual({
      dictationStream: { version: 1 },
      liveVoice: { version: 1 },
    });
  });

  it("follows xAI credentials without touching the network", async () => {
    let auth: VoiceBackendHealthDeps["getAuth"] = signedOut;
    const fetchFn = vi.fn<typeof fetch>(() => Promise.reject(new Error("no network")));
    const owner = health(
      {
        loaded: { asr: { provider: "xai" }, tts: { provider: "xai", voice: "eve" } },
        voice: { asr: { liveVoiceBackend: "grok-voice", sttEndpoint: "http://127.0.0.1:1" } },
      },
      { getAuth: (id) => auth!(id), fetchFn },
    );

    const out = await serverInfo(owner);
    expect(out.voiceBackends.map((entry) => entry.state)).toEqual([
      "needs_credentials",
      "needs_credentials",
      "needs_credentials",
    ]);
    expect(out.capabilities).toEqual({});

    auth = signedIn;
    const signedInInfo = await serverInfo(owner);
    expect(signedInInfo.voiceBackends.map(({ state, target }) => ({ state, target }))).toEqual([
      { state: "ready", target: "xAI" },
      { state: "ready", target: "xAI" },
      { state: "ready", target: "xAI" },
    ]);
    expect(signedInInfo.capabilities).toEqual({
      dictationStream: { version: 1 },
      speech: { version: 1 },
      liveVoice: { version: 1 },
    });

    auth = signedOut;
    vi.stubEnv("XAI_API_KEY", "xai-env-key");
    expect((await serverInfo(owner)).capabilities.liveVoice).toEqual({ version: 1 });

    vi.stubEnv("XAI_API_KEY", "");
    expect((await serverInfo(owner)).capabilities).toEqual({});
    await owner.refresh();
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("keeps local Live Voice unavailable while its configured voice is down", async () => {
    const asr = await backend();
    const voice = await deadEndpoint();
    const voiceConfig: VoiceConfig = {
      asr: { liveVoiceBackend: "yuwp", sttEndpoint: asr.url },
      tts: { provider: "http", endpoint: voice.url },
    };
    const owner = health({ voice: voiceConfig });
    await owner.refresh();

    const down = feature(await serverInfo(owner), "liveVoice");
    expect(down).toMatchObject({ state: "unreachable", target: asr.url });
    expect(down.detail).toBe(`Voice at ${voice.url}: connect ECONNREFUSED 127.0.0.1:${voice.port}`);

    // Without `tts` a local call runs silent, so listening alone is enough.
    delete voiceConfig.tts;
    expect(feature(await serverInfo(owner), "liveVoice").state).toBe("ready");
  });

  it("follows Live Voice settings saved after the server loaded its config", async () => {
    const asr = await backend();
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-live-voice-health-"));
    tempDirs.push(dataDir);
    const store = new ConfigStore(dataDir);
    store.updateConfig({ asr: { liveVoiceBackend: "yuwp" } });
    const owner = new VoiceBackendHealth({
      loadedConfig: () => store.getConfig(),
      voiceConfig: () => store.readVoiceConfig(),
    });
    expect(feature(await serverInfo(owner), "liveVoice").state).toBe("not_configured");

    // `oppi config set` runs in its own process with its own store; no server restart.
    new ConfigStore(dataDir).updateConfig({
      asr: { liveVoiceBackend: "yuwp", sttEndpoint: asr.url },
    });
    await serverInfo(owner);
    await owner.refresh();
    expect((await serverInfo(owner)).capabilities.liveVoice).toEqual({ version: 1 });
  });
});

describe("voice backend health from real read-aloud requests", () => {
  function wav(): Buffer {
    const header = Buffer.alloc(44);
    header.write("RIFF", 0);
    header.writeUInt32LE(36 + 4, 4);
    header.write("WAVE", 8);
    header.write("fmt ", 12);
    header.writeUInt32LE(16, 16);
    header.writeUInt16LE(1, 20);
    header.writeUInt16LE(1, 22);
    header.writeUInt32LE(24_000, 24);
    header.writeUInt32LE(48_000, 28);
    header.writeUInt16LE(2, 32);
    header.writeUInt16LE(16, 34);
    header.write("data", 36);
    header.writeUInt32LE(4, 40);
    return Buffer.concat([header, Buffer.alloc(4)]);
  }

  async function readAloud(owner: VoiceBackendHealth, endpoint: string) {
    const route = createSpeechRoutes(
      routeContext(owner, { provider: "http", endpoint }),
      createRouteHelpers(),
    );
    const speech = await backend((req, res) => {
      const url = new URL(req.url ?? "/", "http://localhost");
      void route({ method: req.method ?? "GET", path: url.pathname, url, req, res });
    });
    const response = await fetch(`${speech.url}/speech`, {
      method: "POST",
      body: JSON.stringify({ text: "Hello there." }),
    });
    const body = response.ok ? undefined : ((await response.json()) as { error: string }).error;
    if (response.ok) await response.arrayBuffer();
    await stop(speech.server);
    return { status: response.status, error: body };
  }

  it("marks the voice unreachable on a failed connect and ready again on success", async () => {
    let now = 0;
    let reply: Handler = (_req, res) => {
      res.writeHead(200, { "Content-Type": "audio/wav" });
      res.end(wav());
    };
    const tts = await backend((req, res) => reply(req, res));
    const owner = health(
      { loaded: { tts: { provider: "http", endpoint: tts.url } } },
      { now: () => now },
    );
    await owner.refresh();
    expect(feature(await serverInfo(owner), "speech").state).toBe("ready");

    await stop(tts.server);
    now = 1;
    expect(await readAloud(owner, tts.url)).toEqual({
      status: 503,
      error: `Read aloud backend at ${tts.url} is not reachable`,
    });
    // Within the TTL, with no probe: the failed request alone flips it.
    const down = await serverInfo(owner);
    expect(feature(down, "speech")).toMatchObject({
      state: "unreachable",
      detail: `connect ECONNREFUSED 127.0.0.1:${tts.port}`,
      checkedAt: 1,
    });
    expect(down.capabilities.speech).toBeUndefined();

    // Back, but the wrong path: the backend answers, so it is ready with the failure noted.
    reply = (_req, res) => {
      res.writeHead(404);
      res.end("not found");
    };
    const revived = await backend((req, res) => reply(req, res), tts.port);
    now = 2;
    expect((await readAloud(owner, tts.url)).status).toBe(502);
    const answered = await serverInfo(owner);
    expect(feature(answered, "speech")).toMatchObject({
      state: "ready",
      detail: "Last request failed: TTS backend returned 404: not found",
    });
    expect(answered.capabilities.speech).toEqual({ version: 1 });

    reply = (_req, res) => {
      res.writeHead(200, { "Content-Type": "audio/wav" });
      res.end(wav());
    };
    expect((await readAloud(owner, tts.url)).status).toBe(200);
    const recovered = feature(await serverInfo(owner), "speech");
    expect(recovered.state).toBe("ready");
    expect(recovered.detail).toBeUndefined();
    // Every flip came from a real request; nothing was probed after the first refresh.
    expect(revived.requests()).toBe(2);
  });

  it("marks Live Voice unavailable when a call's reply cannot reach the voice", async () => {
    const asr = await backend();
    const voice = await backend();
    const tts = { provider: "http" as const, endpoint: voice.url };
    const owner = health({
      voice: { asr: { liveVoiceBackend: "yuwp", sttEndpoint: asr.url }, tts },
    });
    await owner.refresh();
    expect(feature(await serverInfo(owner), "liveVoice").state).toBe("ready");

    await stop(voice.server);
    const speaker = new ReadAloudLiveVoiceTts(tts, { observer: owner });
    const speak = async () => {
      for await (const pcm of speaker.speak("Hi.", new AbortController().signal)) {
        expect(pcm).toBeUndefined();
      }
    };
    await expect(speak()).rejects.toThrow(`Read aloud backend at ${voice.url} is not reachable`);

    const info = await serverInfo(owner);
    expect(feature(info, "liveVoice")).toMatchObject({ state: "unreachable", target: asr.url });
    expect(info.capabilities.liveVoice).toBeUndefined();
  });
});
