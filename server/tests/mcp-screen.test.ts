import { EventEmitter } from "node:events";
import { cpSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { applyImmutable, type Op } from "@earendil-works/chord/delta";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  bindOppiHost,
  type OppiDurableHost,
  type OppiMcpHost,
} from "../src/durable-extension-api.js";
import { PluginHost } from "../src/plugin-host.js";
import { ScreensStreamMux } from "../src/screens-stream.js";
import { SERVER_FEATURE_PRESETS } from "../src/server-features.js";
import type {
  McpAddServerRequest,
  McpServerSummary,
  ScreenPage,
  ScreensClientMessage,
  ScreensServerMessage,
} from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

/** The server's MCP management as the plugin sees it, over an in-memory `mcp.json`. */
const servers: McpServerSummary[] = [];
const calls: unknown[][] = [];
/** The scopes the plugin probed. */
const listed = new Set<string>();
const mcp = {
  list: async (scope: string) => {
    listed.add(scope);
    return {
      scope:
        scope === "global"
          ? {
              id: "global",
              title: "Global",
              kind: "global" as const,
              servers: structuredClone(servers),
              errors: [],
            }
          : {
              id: scope,
              title: "oppi",
              kind: "project" as const,
              projectTrust: "trusted" as const,
              servers: [{ ...summary("local"), state: "unknown" }],
              inherited: structuredClone(servers),
              errors: [],
            },
    };
  },
  add: async (scope: string, input: McpAddServerRequest) => {
    calls.push(["add", scope, input]);
    servers.push(summary(input.name));
  },
  patch: async (scope: string, name: string, patch: { enabled?: boolean }) => {
    calls.push(["patch", scope, name, patch]);
    const entry = servers.find((server) => server.name === name)!;
    if (patch.enabled !== undefined) {
      entry.enabled = patch.enabled;
      entry.state = patch.enabled ? "connected" : "disabled";
    }
  },
  remove: async (scope: string, name: string) => {
    calls.push(["remove", scope, name]);
    servers.splice(
      servers.findIndex((server) => server.name === name),
      1,
    );
  },
  login: async () => {
    throw new Error("not in this test");
  },
  logout: async () => undefined,
  auth: {
    get: () => undefined,
    cancel: () => undefined,
    submit: async () => undefined,
    active: () => undefined,
  },
} as unknown as OppiMcpHost;

function summary(name: string): McpServerSummary {
  return {
    name,
    transport: "http",
    config: { url: `https://example.test/${name}` },
    enabled: true,
    exposure: "codemode",
    state: "connected",
    tools: ["search"],
    supportsOAuth: false,
  };
}

// Bound once per test file, before the plugin loads: the plugin reads `oppiHost().mcp()`.
bindOppiHost({ files: { internalUrls: {} }, mcp: () => mcp } as unknown as OppiDurableHost);

let host: PluginHost;
beforeAll(async () => {
  const base = makeTempDir("oppi-mcp-screen-");
  const builtInDir = join(base, "built-in");
  mkdirSync(builtInDir, { recursive: true });
  writeFileSync(
    join(builtInDir, "package.json"),
    JSON.stringify({ name: "test-built-ins", private: true, chord: { plugins: ["./mcp-screen"] } }),
  );
  // A copy of the real plugin: a built-in root takes no folder linked from outside it, and the
  // plugin imports nothing of the server but types.
  cpSync(
    fileURLToPath(new URL("../plugins/mcp-screen", import.meta.url)),
    join(builtInDir, "mcp-screen"),
    {
      recursive: true,
    },
  );
  host = new PluginHost({
    builtInDir,
    agentDir: join(base, "agent"),
    required: new Set(),
    core: { first: [CodingTools], afterBuiltIns: [] },
  });
  expect((await host.load()).errors).toEqual([]);
});
afterAll(() => host.close());

class FakeSocket extends EventEmitter {
  readonly OPEN = 1;
  readyState = 1;
  readonly sent: ScreensServerMessage[] = [];
  send(text: string): void {
    this.sent.push(JSON.parse(text) as ScreensServerMessage);
  }
}

function connect() {
  const mux = new ScreensStreamMux({
    screens: async () => host.screens(),
    features: () => SERVER_FEATURE_PRESETS.all,
    workspaceExists: () => true,
  });
  const ws = new FakeSocket();
  mux.handleWebSocket(ws as never);
  const send = (message: ScreensClientMessage) =>
    ws.emit("message", Buffer.from(JSON.stringify(message)), false);
  const page = (id: string): ScreenPage | undefined => {
    let value: unknown;
    for (const message of ws.sent) {
      if (message.type === "value" && message.watch === id) value = message.value;
      if (message.type === "ops" && message.watch === id)
        value = applyImmutable(value, message.ops as Op[]);
    }
    return value as ScreenPage | undefined;
  };
  const result = (call: string) =>
    vi.waitFor(() => {
      const found = ws.sent.find((message) => message.type === "result" && message.call === call);
      if (!found) throw new Error(`no result for ${call}`);
      return found;
    });
  const watch = (id: string, page: string, scope = "server") =>
    send({ type: "watch", watch: id, entry: "oppi.mcp", scope, page, v: 1 });
  return { mux, ws, send, page, result, watch };
}

const rowIds = (page: ScreenPage | undefined, section: string) =>
  page?.sections.find((s) => s.id === section)?.rows.map((row) => row.id);

describe("MCP Servers plugin screen", () => {
  it("lists the servers, toggles one, adds one and removes one, each change reaching every open page", async () => {
    servers.splice(0, servers.length, summary("echo"));
    const c = connect();
    c.watch("list", "list");
    await vi.waitFor(() => expect(rowIds(c.page("list"), "servers")).toEqual(["server.echo"]));

    c.watch("detail", "server/echo");
    await vi.waitFor(() => expect(c.page("detail")?.title).toBe("echo"));
    c.send({
      type: "act",
      watch: "detail",
      call: "c1",
      action: "enabled",
      row: "enabled",
      values: [{ field: "enabled", value: false }],
    });
    expect(await c.result("c1")).toEqual({ type: "result", call: "c1", ok: true });
    expect(calls.at(-1)).toEqual(["patch", "global", "echo", { enabled: false }]);
    const toggle = () => c.page("detail")?.sections.find((s) => s.id === "config")?.rows[0];
    await vi.waitFor(() => expect(toggle()).toMatchObject({ kind: "toggle", value: false }));
    // The list under it probes again on its own.
    await vi.waitFor(
      () =>
        expect(c.page("list")?.sections.find((s) => s.id === "servers")?.rows[0]).toMatchObject({
          status: { text: "Disabled" },
        }),
      { timeout: 3000 },
    );

    c.watch("add", "add");
    await vi.waitFor(() =>
      expect(c.page("add")?.submit).toEqual({
        title: "Add",
        action: "add",
        requires: ["name", "url", "command"],
      }),
    );
    c.send({
      type: "act",
      watch: "add",
      call: "c2",
      action: "add",
      values: [{ field: "name", value: "docs" }],
    });
    expect(await c.result("c2")).toEqual({
      type: "result",
      call: "c2",
      ok: false,
      message: "Enter the server's URL.",
    });
    c.send({
      type: "act",
      watch: "add",
      call: "c3",
      action: "add",
      values: [
        { field: "name", value: "docs" },
        { field: "transport", value: "http" },
        { field: "url", value: "https://example.test/docs" },
        { field: "headers", value: "X-Key=${DOCS_KEY}" },
      ],
    });
    expect(await c.result("c3")).toEqual({
      type: "result",
      call: "c3",
      ok: true,
      nav: { kind: "pop" },
    });
    expect(calls.at(-1)).toEqual([
      "add",
      "global",
      { name: "docs", url: "https://example.test/docs", headers: { "X-Key": "${DOCS_KEY}" } },
    ]);
    await vi.waitFor(
      () => expect(rowIds(c.page("list"), "servers")).toEqual(["server.echo", "server.docs"]),
      { timeout: 3000 },
    );

    c.send({ type: "act", watch: "detail", call: "c4", action: "remove" });
    expect(await c.result("c4")).toEqual({
      type: "result",
      call: "c4",
      ok: true,
      nav: { kind: "pop" },
    });
    // The removed server's page ends; the list drops its row.
    await vi.waitFor(
      () => expect(c.ws.sent).toContainEqual({ type: "ended", watch: "detail", reason: "gone" }),
      { timeout: 3000 },
    );
    await vi.waitFor(() => expect(rowIds(c.page("list"), "servers")).toEqual(["server.docs"]), {
      timeout: 3000,
    });
    c.ws.emit("close");
  });

  it("draws and changes a host workspace's own servers, with the global ones it inherits", async () => {
    servers.splice(0, servers.length, summary("echo"));
    const c = connect();
    c.watch("list", "list", "workspace:ws1");
    await vi.waitFor(() => {
      const page = c.page("list");
      expect(page?.sections.find((s) => s.id === "servers")?.header).toBe("This Workspace");
      expect(rowIds(page, "servers")).toEqual(["server.local"]);
      // Inherited rows say where they come from and open nothing.
      expect(page?.sections.find((s) => s.id === "inherited")?.rows).toEqual([
        expect.objectContaining({ id: "inherited.echo", status: expect.anything() }),
      ]);
      expect(page?.sections.find((s) => s.id === "inherited")?.rows[0]).not.toHaveProperty("push");
    });
    expect(listed).toContain("ws1");

    // The Add form names the workspace (and asks the app to name the host), and saves to the
    // workspace's file.
    c.watch("add", "add", "workspace:ws1");
    await vi.waitFor(() => {
      const configuration = c.page("add")?.sections.find((s) => s.id === "configuration");
      expect(configuration?.rows.find((row) => row.id === "scope")).toMatchObject({
        value: "oppi",
      });
      expect(configuration?.namesHost).toBe(true);
      expect(configuration?.footer).toBe(
        "Saved to this workspace\u2019s .pi/mcp.json. Project trust: trusted.",
      );
    });
    c.send({
      type: "act",
      watch: "add",
      call: "w1",
      action: "add",
      values: [
        { field: "name", value: "tools" },
        { field: "transport", value: "stdio" },
        { field: "command", value: "node" },
      ],
    });
    expect(await c.result("w1")).toMatchObject({ ok: true });
    expect(calls.at(-1)).toEqual(["add", "ws1", { name: "tools", command: "node" }]);
    c.ws.emit("close");
  });
});
