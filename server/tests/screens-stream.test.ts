import { EventEmitter } from "node:events";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { applyImmutable, type Op } from "@earendil-works/chord/delta";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PluginHost } from "../src/plugin-host.js";
import { SCREEN_PAGE_MAX_BYTES, serveScreens } from "../src/plugin-screens.js";
import { ScreensStreamMux } from "../src/screens-stream.js";
import { SERVER_FEATURE_PRESETS } from "../src/server-features.js";
import type { ScreensClientMessage, ScreensServerMessage } from "../src/types.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createIdentityRoutes } from "../src/routes/identity.js";
import type { RouteContext } from "../src/routes/types.js";
import { makeResponse, makeUnconfiguredVoiceBackendHealth } from "./harness/route-test-helpers.js";
import { makeTempDir } from "./harness/temp-dir.js";

const hosts: PluginHost[] = [];
const sockets: EventEmitter[] = [];
afterEach(async () => {
  // A closed socket releases its watches before the host goes.
  for (const ws of sockets.splice(0)) ws.emit("close");
  await Promise.all(hosts.splice(0).map((host) => host.close()));
});

function write(path: string, text: string): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}

/**
 * A plugin whose screen lists the words `add` gave it, and can break its own page on purpose.
 * Without `feature` it is a sidebar entry only: no extension, and a workspace scope too.
 */
function screenPlugin(id: string, order: number, feature?: string): string {
  return `
import { defineExtension, defineFacet, defineScreen, Extensions, Sidebar } from "oppi/v1";
const Screen = defineScreen(${JSON.stringify(id)});
export default defineFacet((host, self) => {
  ${feature ? `self.contribute(Extensions, defineExtension({ name: ${JSON.stringify(id)} }));` : ""}
  self.contribute(Sidebar, { id: ${JSON.stringify(id)}, title: "Things", icon: "list.bullet",
    order: ${order}, scopes: ${feature ? '["server"]' : '["server", "workspace"]'}, screen: Screen${feature ? `, feature: ${JSON.stringify(feature)}` : ""} });
  host.serve(Screen.contract, ({ scope, page }, self) => {
    const doc = self.state(Screen.document);
    const words = [];
    const page_ = (extra) => ({ title: page + " in " + scope, sections: [{ id: "main",
      rows: words.map((word, i) => ({ kind: "text", id: "w" + i, text: word })) }], ...extra });
    const put = (value, ctx) => doc.change((d) => {
      for (const key of Object.keys(d)) delete d[key];
      Object.assign(d, value);
    }, ctx);
    self.onLive((ctx) => put(page_({}), ctx));
    return { page: doc, act: async (args, ctx) => {
      if (args.action === "add") { words.push(String(args.values?.[0]?.value)); await put(page_({}), ctx); return { ok: true }; }
      if (args.action === "slow") { await new Promise((resolve) => setTimeout(resolve, 100)); words.push("slow"); await put(page_({}), ctx); return { ok: true }; }
      if (args.action === "huge") { await put(page_({ sections: [{ id: "main", rows: [{ kind: "text", id: "x", text: "x".repeat(${SCREEN_PAGE_MAX_BYTES}) }] }] }), ctx); return { ok: true }; }
      if (args.action === "eighth") { await put(page_({ sections: [{ id: "main", rows: [{ kind: "chart", id: "c" }] }] }), ctx); return { ok: true }; }
      if (args.action === "gone") { await put({ gone: true }, ctx); return { ok: true }; }
      if (args.action === "leave") return { ok: true, nav: { kind: "pop" } };
      return { ok: false, message: "No such action" };
    } };
  });
});
`;
}

async function loadedHost() {
  const base = makeTempDir("oppi-screens-");
  const builtInDir = join(base, "built-in");
  const agentDir = join(base, "agent");
  write(
    join(builtInDir, "package.json"),
    JSON.stringify({
      name: "test-built-ins",
      private: true,
      chord: { plugins: ["./things", "./first"] },
    }),
  );
  for (const [dir, source] of [
    ["things", screenPlugin("test.things", 20, "mcp")],
    ["first", screenPlugin("test.first", 10)],
  ] as const) {
    write(join(builtInDir, dir, "package.json"), JSON.stringify({ name: dir }));
    write(join(builtInDir, dir, "server.ts"), source);
  }
  // An owner plugin may not add a sidebar entry.
  write(join(agentDir, "plugins/owned/package.json"), JSON.stringify({ name: "owned" }));
  write(join(agentDir, "plugins/owned/server.ts"), screenPlugin("test.owned", 0));
  const host = new PluginHost({
    builtInDir,
    agentDir,
    required: new Set(),
    core: { first: [CodingTools], afterBuiltIns: [] },
  });
  hosts.push(host);
  const report = await host.load();
  expect(report.errors).toEqual([]);
  return host;
}

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  readonly sent: ScreensServerMessage[] = [];
  send(text: string): void {
    this.sent.push(JSON.parse(text) as ScreensServerMessage);
  }
}

async function connect() {
  const host = await loadedHost();
  /** The server's switches the stream reads; a test turns one off and calls `featuresChanged`. */
  const features = { ...SERVER_FEATURE_PRESETS.all };
  const mux = new ScreensStreamMux({
    screens: async () => host.screens(),
    features: () => features,
    workspaceExists: (id) => id === "ws1",
  });
  const ws = new FakeSocket();
  sockets.push(ws);
  mux.handleWebSocket(ws as never);
  const send = (message: ScreensClientMessage): void => {
    ws.emit("message", Buffer.from(JSON.stringify(message)), false);
  };
  /** The next frame after the `seen` first ones that `match` accepts. */
  const frame = async <T extends ScreensServerMessage["type"]>(
    type: T,
    seen = 0,
  ): Promise<Extract<ScreensServerMessage, { type: T }>> =>
    vi.waitFor(() => {
      const found = ws.sent.slice(seen).find((message) => message.type === type);
      if (!found) throw new Error(`no ${type} frame yet`);
      return found as Extract<ScreensServerMessage, { type: T }>;
    });
  /** What the app holds for `id`: the first value with every ops frame applied, in order. */
  const replica = (id = "w1"): unknown => {
    let value: unknown;
    for (const message of ws.sent) {
      if (message.type === "value" && message.watch === id) value = message.value;
      if (message.type === "ops" && message.watch === id)
        value = applyImmutable(value, message.ops as Op[]);
    }
    return value;
  };
  const settled = (id: string, expected: unknown) =>
    vi.waitFor(() => expect(replica(id)).toEqual(expected));
  return { host, mux, ws, features, send, frame, replica, settled };
}

const watch = (overrides: Partial<Extract<ScreensClientMessage, { type: "watch" }>> = {}) =>
  ({
    type: "watch",
    watch: "w1",
    entry: "test.things",
    scope: "server",
    page: "list",
    v: 1,
    ...overrides,
  }) as const;

describe("plugin screens", () => {
  it("answers /server/info while the plugins load, then lists only built-in entries in order", async () => {
    let loads = 0;
    const info = async (pluginScreens: () => Promise<unknown>, config: object = {}) => {
      const ctx = {
        storage: {
          getConfig: () => config,
          listWorkspaces: () => [],
          listSessions: () => [],
          getDataDir: () => makeTempDir("oppi-screens-info-"),
        },
        sessions: { durableSessionsAvailable: () => false, pluginScreens },
        sessionRuntimes: { getActiveSessionIds: () => new Set() },
        skillRegistry: { list: () => [] },
        getModelCatalog: () => [],
        voiceBackendHealth: makeUnconfiguredVoiceBackendHealth(),
        serverStartedAt: Date.now(),
      } as unknown as RouteContext;
      const res = makeResponse();
      await createIdentityRoutes(
        ctx,
        createRouteHelpers(),
      )({
        method: "GET",
        path: "/server/info",
        url: new URL("http://localhost/server/info"),
        req: {} as never,
        res: res as never,
      });
      return JSON.parse(res.body) as Record<string, unknown> & {
        capabilities: Record<string, unknown>;
      };
    };

    // Nothing loaded yet, and a load that never ends: the answer comes anyway, with no entries,
    // and it started the load.
    serveScreens(undefined);
    const loading = await info(() => {
      loads += 1;
      return new Promise(() => undefined);
    });
    expect(loading.capabilities.screens).toEqual({ v: 1 });
    expect(loading.sidebar).toEqual([]);
    await vi.waitFor(() => expect(loads).toBe(1));

    // Loaded: the built-ins' entries, the owner plugin's left out.
    const host = await loadedHost();
    const loaded = await info(async () => host.screens());
    expect(loaded.sidebar).toEqual([
      {
        id: "test.first",
        title: "Things",
        icon: "list.bullet",
        order: 10,
        scopes: ["server", "workspace"],
      },
      {
        id: "test.things",
        title: "Things",
        icon: "list.bullet",
        order: 20,
        scopes: ["server"],
        feature: "mcp",
      },
    ]);
    // A plugin that adds only a sidebar entry is no extension: sessions and the lists skip it.
    expect(host.plugins.map((plugin) => plugin.name)).toEqual(["things"]);
    expect(loaded.features).toEqual(SERVER_FEATURE_PRESETS.all);

    // An entry whose feature is off is not listed; the switches say which are off.
    const mcpOff = await info(async () => host.screens(), { features: { mcp: false } });
    expect((mcpOff.sidebar as { id: string }[]).map((entry) => entry.id)).toEqual(["test.first"]);
    expect(mcpOff.features).toEqual({ ...SERVER_FEATURE_PRESETS.all, mcp: false });
  });

  it("ends the watches of an entry whose feature turns off, and refuses new ones while it is off", async () => {
    const c = await connect();
    c.send(watch());
    c.send(watch({ watch: "w2", entry: "test.first" }));
    await vi.waitFor(() => expect(c.ws.sent.filter((m) => m.type === "value")).toHaveLength(2));

    c.features.mcp = false;
    c.mux.featuresChanged();
    expect(c.ws.sent.filter((m) => m.type === "ended")).toEqual([
      { type: "ended", watch: "w1", reason: "off" },
    ]);
    c.send(watch({ watch: "w3" }));
    await vi.waitFor(() =>
      expect(c.ws.sent.at(-1)).toEqual({ type: "ended", watch: "w3", reason: "off" }),
    );

    // The other entry's watch still runs.
    c.send({
      type: "act",
      watch: "w2",
      call: "c1",
      action: "add",
      values: [{ field: "w", value: "on" }],
    });
    expect(await c.frame("result")).toEqual({ type: "result", call: "c1", ok: true });
  });

  it("counts a watch from its message, so the limit holds while the plugins load", async () => {
    const mux = new ScreensStreamMux({
      screens: () => new Promise(() => undefined),
      features: () => SERVER_FEATURE_PRESETS.all,
      workspaceExists: () => true,
    });
    const ws = new FakeSocket();
    mux.handleWebSocket(ws as never);
    for (let n = 1; n <= 17; n++)
      ws.emit("message", Buffer.from(JSON.stringify(watch({ watch: `w${n}` }))), false);
    await vi.waitFor(() =>
      expect(ws.sent).toEqual([{ type: "failed", watch: "w17", message: "Too many open screens" }]),
    );
    ws.emit("close");
  });

  it("sends a watched page whole, then each change as ops on it", async () => {
    const c = await connect();
    c.send(watch());
    // Every screen document starts as a loading page until its source answers.
    expect((await c.frame("value")).value).toEqual({
      title: "",
      state: { kind: "loading" },
      sections: [],
    });
    await c.settled("w1", { title: "list in server", sections: [{ id: "main", rows: [] }] });
    expect(c.ws.sent.filter((m) => m.type === "value")).toHaveLength(1);

    const before = c.ws.sent.length;
    c.send({
      type: "act",
      watch: "w1",
      call: "c1",
      action: "add",
      values: [{ field: "word", value: "hello" }],
    });
    expect(await c.frame("result", before)).toEqual({ type: "result", call: "c1", ok: true });
    // Only the new row travels, not the page.
    expect((await c.frame("ops", before)).ops).toEqual([
      ["p", ["sections", 0, "rows"], 0, 0, [{ kind: "text", id: "w0", text: "hello" }]],
    ]);
    await c.settled("w1", {
      title: "list in server",
      sections: [{ id: "main", rows: [{ kind: "text", id: "w0", text: "hello" }] }],
    });
  });

  it("answers each act with its own result, failures and navigation included", async () => {
    const c = await connect();
    c.send(watch());
    await c.frame("value");
    c.send({ type: "act", watch: "w1", call: "c1", action: "nope" });
    c.send({ type: "act", watch: "w1", call: "c2", action: "leave" });
    c.send({ type: "act", watch: "other", call: "c3", action: "add" });
    await vi.waitFor(() => expect(c.ws.sent.filter((m) => m.type === "result")).toHaveLength(3));
    const results = Object.fromEntries(
      c.ws.sent.flatMap((m) => (m.type === "result" ? [[m.call, m]] : [])),
    );
    expect(results.c1).toEqual({
      type: "result",
      call: "c1",
      ok: false,
      message: "No such action",
    });
    expect(results.c2).toEqual({ type: "result", call: "c2", ok: true, nav: { kind: "pop" } });
    expect(results.c3).toMatchObject({ ok: false, message: "This page is not open." });
  });

  it("refuses a page over budget or outside the vocabulary, and diffs the next good one against the last sent", async () => {
    const c = await connect();
    c.send(watch());
    await c.settled("w1", { title: "list in server", sections: [{ id: "main", rows: [] }] });
    let seen = c.ws.sent.length;
    c.send({ type: "act", watch: "w1", call: "c1", action: "huge" });
    expect((await c.frame("failed", seen)).message).toMatch(/budget is 65536/);
    seen = c.ws.sent.length;
    c.send({ type: "act", watch: "w1", call: "c2", action: "eighth" });
    expect((await c.frame("failed", seen)).message).toMatch(
      /row kind "chart" is not one of the seven/,
    );

    // The app still holds the last good page; the next good one is diffed against it.
    expect(c.replica("w1")).toEqual({
      title: "list in server",
      sections: [{ id: "main", rows: [] }],
    });
    c.send({
      type: "act",
      watch: "w1",
      call: "c3",
      action: "add",
      values: [{ field: "w", value: "ok" }],
    });
    await c.settled("w1", {
      title: "list in server",
      sections: [{ id: "main", rows: [{ kind: "text", id: "w0", text: "ok" }] }],
    });
  });

  it("ends a watch whose page goes, and one the server cannot serve", async () => {
    const c = await connect();
    c.send(watch());
    await c.frame("value");
    c.send({ type: "act", watch: "w1", call: "c1", action: "gone" });
    expect(await c.frame("ended")).toEqual({ type: "ended", watch: "w1", reason: "gone" });

    const seen = c.ws.sent.length;
    c.send(watch({ watch: "a", entry: "test.owned" }));
    c.send(watch({ watch: "b", v: 2 }));
    c.send(watch({ watch: "c", scope: "workspace:w1" }));
    c.send(watch({ watch: "d", page: "a/b/c/d" }));
    await vi.waitFor(() => expect(c.ws.sent.length).toBe(seen + 4));
    expect(
      Object.fromEntries(c.ws.sent.slice(seen).map((m) => [(m as { watch: string }).watch, m])),
    ).toEqual({
      a: { type: "ended", watch: "a", reason: "gone" },
      b: { type: "ended", watch: "b", reason: "unsupported" },
      c: { type: "ended", watch: "c", reason: "unsupported" },
      d: { type: "ended", watch: "d", reason: "unsupported" },
    });
  });

  it("serves a workspace scope to an entry that has one, for a workspace that exists", async () => {
    const c = await connect();
    c.send(watch({ entry: "test.first", scope: "workspace:ws1" }));
    await c.settled("w1", { title: "list in workspace:ws1", sections: [{ id: "main", rows: [] }] });
    c.send(watch({ watch: "w2", entry: "test.first", scope: "workspace:gone" }));
    c.send(watch({ watch: "w3", entry: "test.first", scope: "workspace:" }));
    await vi.waitFor(() =>
      expect(c.ws.sent.filter((m) => m.type === "ended")).toEqual([
        { type: "ended", watch: "w2", reason: "gone" },
        { type: "ended", watch: "w3", reason: "unsupported" },
      ]),
    );
  });

  it("runs an act sent while its page opens, and finishes one whose page is unwatched meanwhile", async () => {
    const c = await connect();
    // The act follows the watch at once, before the plugins answered.
    c.send(watch());
    c.send({
      type: "act",
      watch: "w1",
      call: "c1",
      action: "add",
      values: [{ field: "w", value: "early" }],
    });
    expect(await c.frame("result")).toEqual({ type: "result", call: "c1", ok: true });

    // A change in flight is the person's: leaving the page does not cancel it.
    const seen = c.ws.sent.length;
    c.send({ type: "act", watch: "w1", call: "c2", action: "slow" });
    c.send({ type: "unwatch", watch: "w1" });
    // It wrote its page after the unwatch: an aborted act would fail here.
    expect(await c.frame("result", seen)).toEqual({ type: "result", call: "c2", ok: true });
  });
});
