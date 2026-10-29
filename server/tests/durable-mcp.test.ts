import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { ModelRuntime, ProjectTrustStore, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { ConversationId } from "@earendil-works/pi-durable";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import type { GondolinExecResult, GondolinProcess, GondolinVm } from "../src/gondolin-ops.js";
import { DurableBackend } from "../src/durable-backend.js";
import { DurableHarness, SessionHost } from "../src/durable-harness.js";
import { DurableMcp } from "../src/durable-mcp.js";
import { collected } from "./helpers/collected.js";
import { PROJECT_TRUST_OPTIONS } from "../src/project-trust.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { resolveSandboxGuestCwd } from "../src/workspace-folder.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";

const ECHO_SERVER = fileURLToPath(new URL("./fixtures/mcp-echo-server.mjs", import.meta.url));

const managers: SessionManager[] = [];
let agentDir: string;
let previousAgentDir: string | undefined;

beforeEach(() => {
  agentDir = makeTempDir("oppi-durable-mcp-agent-");
  previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
});

afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  rmSync(agentDir, { recursive: true, force: true });
});

function echoServer(marker: string, extra: Record<string, unknown> = {}) {
  return {
    command: process.execPath,
    args: [ECHO_SERVER],
    env: { MCP_ECHO_MARKER: marker },
    ...extra,
  };
}

function writeMcpJson(dir: string, servers: Record<string, unknown>): void {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "mcp.json"), JSON.stringify({ mcpServers: servers }));
}

async function fixture(
  responses: FauxResponseStep[],
  sandboxConfig?: NonNullable<Workspace["sandboxConfig"]>,
  tools?: NonNullable<Session["launch"]>["tools"],
  /** The Pi Tools setting (`defaultTools`); Pi's default when unset. */
  defaultTools?: string[],
) {
  const dir = makeTempDir("oppi-durable-mcp-test-");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
  vi.spyOn(SettingsManager, "create").mockImplementation(() =>
    SettingsManager.inMemory({
      defaultProvider: "faux",
      defaultModel: "faux-1",
      defaultThinkingLevel: "off",
      compaction: { enabled: false },
      ...(defaultTools ? { defaultTools } : {}),
    }),
  );
  const storage = new Storage(dir);
  storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
  const workspace = storage.createWorkspace({
    name: "Durable MCP",
    hostMount: dir,
    ...(sandboxConfig ? { runtime: "sandbox" as const, sandboxConfig } : {}),
  });
  const session = storage.createSession("Durable MCP", "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspace.id;
  if (tools) session.launch = { status: "accepted", requestedAt: Date.now(), tools };
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  return { dir, faux, storage, workspace, session, manager };
}

function observe(manager: SessionManager, sessionId: string) {
  const messages: ServerMessage[] = [];
  const unsubscribe = manager.subscribe(sessionId, (message) => messages.push(message));
  return { messages, unsubscribe };
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

async function prompt(manager: SessionManager, sessionId: string, text: string) {
  const projection = observe(manager, sessionId);
  await manager.sendPrompt(sessionId, text);
  await waitFor(
    () => projection.messages.some((message) => message.type === "agent_end"),
    "agent_end",
  );
  projection.unsubscribe();
  return projection.messages;
}

async function toolResults(manager: SessionManager, sessionId: string): Promise<string[]> {
  const history = (await manager.runCommand(sessionId, { type: "get_messages" })) as {
    role: string;
    content: unknown;
  }[];
  return history
    .filter((message) => message.role === "toolResult")
    .map((message) => JSON.stringify(message.content));
}

const read = (path: string): string => (existsSync(path) ? readFileSync(path, "utf8") : "");

/**
 * A stand-in workspace VM that records every exec. Long-lived stdio peers run as local
 * processes so the MCP protocol is real; `durable-gondolin-live` and the classic live MCP
 * test cover a real guest.
 */
function recordingVm() {
  const peers: { argv: string[]; cwd?: string; env?: Record<string, string> }[] = [];
  const done = (): GondolinExecResult => ({
    ok: true,
    exitCode: 0,
    stdout: "",
    stdoutBuffer: Buffer.alloc(0),
  });
  const vm: GondolinVm = {
    fs: {
      mkdir: async () => {},
      access: async () => {},
      readFile: async () => Buffer.alloc(0),
      writeFile: async () => {},
    },
    exec: (argv, options) => {
      if (!options?.stdin)
        return Object.assign(Promise.resolve(done()), {
          async *output() {},
          write() {},
          end() {},
        });
      const args = [...(argv as string[])];
      peers.push({ argv: args, cwd: options.cwd, env: options.env });
      const child = spawn(args[0]!, args.slice(1), {
        // Exactly what was configured: a host-env leak into the guest must show up.
        env: { ...options.env },
        stdio: "pipe",
      });
      options.signal?.addEventListener("abort", () => child.kill());
      const exited = new Promise<GondolinExecResult>((resolve) =>
        child.on("close", (code) => resolve({ ...done(), ok: code === 0, exitCode: code ?? 1 })),
      );
      return Object.assign(exited, {
        async *output() {
          for await (const data of child.stdout) yield { stream: "stdout" as const, data };
        },
        write: (data: string | Buffer) => child.stdin.write(data),
        end: () => child.stdin.end(),
      }) as GondolinProcess;
    },
  };
  return { vm, peers };
}

describe("server durable MCP (host)", () => {
  it("offers direct tools on the first prompt, reports a broken server once, and stops its servers with the session", async () => {
    const marker = join(agentDir, "echo.marker");
    writeMcpJson(agentDir, {
      echo: echoServer(marker, { exposure: "direct" }),
      broken: { command: join(agentDir, "missing-mcp-server"), exposure: "direct" },
    });
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall("mcp__echo__echo", { text: "hi" })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("DIRECT_DONE"),
    ]);
    await f.manager.startSession(f.session.id, f.workspace);
    const notices: string[] = [];
    f.manager.subscribe(f.session.id, (message) => {
      if (message.type === "extension_ui_notification" && message.method === "notify")
        notices.push(message.message ?? "");
    });

    await prompt(f.manager, f.session.id, "Echo hi");
    expect(read(marker)).toContain('call echo {"text":"hi"}');
    expect(await toolResults(f.manager, f.session.id)).toEqual([
      expect.stringContaining("echo:hi"),
    ]);
    await waitFor(() => notices.length > 0, "MCP startup notice");
    expect(notices).toEqual([expect.stringMatching(/broken: failed/)]);
    expect(notices[0]).not.toContain("echo");

    const pid = Number(read(marker).match(/^spawn (\d+)/)?.[1]);
    expect(pid).toBeGreaterThan(0);
    await f.manager.stopSession(f.session.id);
    await waitFor(() => {
      try {
        process.kill(pid, 0);
        return false;
      } catch {
        return true;
      }
    }, "echo server to exit after Stop");
  });

  it("frees a stopped session while an older registry snapshot still holds its MCP extension", async () => {
    writeMcpJson(agentDir, {
      echo: echoServer(join(agentDir, "echo.marker"), { exposure: "direct" }),
      search: echoServer(join(agentDir, "search.marker")),
    });
    const f = await fixture([
      fauxAssistantMessage([fauxToolCall("mcp__echo__echo", { text: "hi" })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("RETAIN_DONE"),
    ]);
    // A running task invocation keeps the registry snapshot it was reserved with, and with it every
    // extension installed then, past their uninstall. Hold what this session installs the same way.
    const install = vi.spyOn(DurableHarness.prototype, "installExtension");
    const opened = vi.spyOn(DurableMcp, "open");
    const created = vi.spyOn(DurableBackend, "create");
    await f.manager.startSession(f.session.id, f.workspace);
    await prompt(f.manager, f.session.id, "Echo hi");
    const pinned = install.mock.calls
      .map(([extension]) => extension)
      .filter((extension) => extension.name === `oppi.mcp/${f.session.id}`);
    // Tools and the server section, from after the servers connected.
    expect(pinned.at(-1)?.tools?.map((tool) => tool.name)).toContain("mcp__echo__echo");
    const mcp = new WeakRef((await opened.mock.results[0]!.value)!);
    const backend = new WeakRef(await created.mock.results[0]!.value);
    for (const spy of [install, opened, created]) {
      spy.mockClear();
      spy.mockRestore();
    }

    await f.manager.stopSession(f.session.id);

    expect(await collected(mcp)).toBe(true);
    expect(await collected(backend)).toBe(true);
    expect(pinned.length).toBeGreaterThan(0);
  });

  it("turns codemode on for a codemode server, whose tools scripts call and tool_search loads, and keeps loaded ones after a restart", async () => {
    const marker = join(agentDir, "echo.marker");
    // No exposure: Pi's default, codemode. The Pi Tools setting adds tool_search but not
    // codemode: the server turns codemode on, as in classic.
    writeMcpJson(agentDir, { echo: echoServer(marker) });
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("mcp__echo__echo", { text: "early" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage(
          [
            fauxToolCall("codemode", {
              code: 'console.log(await tools.mcp__echo__echo({ text: "script" }));',
            }),
          ],
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage([fauxToolCall("tool_search", { query: "echo text back" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage([fauxToolCall("mcp__echo__echo", { text: "found" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage("SEARCH_DONE"),
      ],
      undefined,
      undefined,
      ["+tool_search"],
    );
    await f.manager.startSession(f.session.id, f.workspace);
    await prompt(f.manager, f.session.id, "Find and use the echo tool");

    const calls = read(marker)
      .split("\n")
      .filter((line) => line.startsWith("call "));
    // Not offered to the model before tool_search loads it, but scripts call it.
    expect(calls).toEqual(['call echo {"text":"script"}', 'call echo {"text":"found"}']);
    const results = await toolResults(f.manager, f.session.id);
    expect(results).toHaveLength(4);
    expect(results[0]).not.toContain("echo:early");
    expect(results[1]).toContain("echo:script");
    expect(results[2]).toContain("mcp__echo__echo");
    expect(results[3]).toContain("echo:found");

    // A new server process and Harness: the loaded tool stays offered without a search.
    await f.manager.close();
    managers.splice(managers.indexOf(f.manager), 1);
    f.faux.appendResponses([
      fauxAssistantMessage([fauxToolCall("mcp__echo__echo", { text: "again" })], {
        stopReason: "toolUse",
      }),
      fauxAssistantMessage("RESTART_DONE"),
    ]);
    const restarted = new SessionManager(new Storage(f.dir));
    managers.push(restarted);
    await restarted.resumeDurableSessions();
    await restarted.startSession(f.session.id, f.workspace);
    await prompt(restarted, f.session.id, "Echo again");
    expect(read(marker)).toContain('call echo {"text":"again"}');
    expect((await toolResults(restarted, f.session.id)).at(-1)).toContain("echo:again");
  });

  it("follows Pi's tool policy: an allow list naming codemode lets scripts reach MCP tools, never direct or excluded ones", async () => {
    const marker = (name: string) => join(agentDir, `${name}.marker`);
    writeMcpJson(agentDir, {
      echo: echoServer(marker("echo")),
      loud: echoServer(marker("loud"), { exposure: "direct" }),
      secret: echoServer(marker("secret")),
    });
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("mcp__loud__echo", { text: "direct" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage([fauxToolCall("tool_search", { query: "echo text back" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage(
          [
            fauxToolCall("codemode", {
              code: [
                'console.log(await tools.mcp__echo__echo({ text: "script" }));',
                'for (const name of ["mcp__secret__echo", "mcp__loud__echo"]) {',
                '  try { await tools[name]({ text: "no" }); console.log(name, "called"); }',
                '  catch { console.log(name, "unavailable"); }',
                "}",
              ].join("\n"),
            }),
          ],
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage("POLICY_DONE"),
      ],
      undefined,
      // A saved Agent's classic list: codemode is how classic reaches these servers.
      { allowed: ["read", "codemode"], excluded: ["mcp__secret__*"] },
    );
    await f.manager.startSession(f.session.id, f.workspace);
    await prompt(f.manager, f.session.id, "Find and use the echo tool");

    const calls = (name: string) =>
      read(marker(name))
        .split("\n")
        .filter((line) => line.startsWith("call "));
    expect(calls("echo")).toEqual(['call echo {"text":"script"}']);
    expect(calls("loud")).toEqual([]);
    expect(calls("secret")).toEqual([]);
    const results = await toolResults(f.manager, f.session.id);
    // The allow list names neither the direct tool nor tool_search: the model gets neither.
    expect(results[0]).not.toContain("echo:direct");
    expect(results[1]).not.toContain("mcp__echo__echo");
    expect(results[2]).toContain("echo:script");
    expect(results[2]).toContain("mcp__secret__echo unavailable");
    expect(results[2]).toContain("mcp__loud__echo unavailable");
  });

  it("in a sandbox, loads only picked global servers, runs stdio in the VM, and refuses hosts outside Allowed Hosts", async () => {
    const marker = (name: string) => join(agentDir, `${name}.marker`);
    const rootsEnv = (name: string) => ({ MCP_ECHO_MARKER: marker(name), MCP_ECHO_ROOTS: "1" });
    writeMcpJson(agentDir, {
      picked: echoServer(marker("picked"), { exposure: "direct", env: rootsEnv("picked") }),
      // Default exposure, codemode: scripts call it in the sandbox too.
      lazy: echoServer(marker("lazy"), { env: rootsEnv("lazy") }),
      unpicked: echoServer(marker("unpicked"), { exposure: "direct" }),
      remote: { url: "https://evil.test/mcp", exposure: "direct" },
    });
    const { vm, peers } = recordingVm();
    const ensure = vi.spyOn(SdkBackend, "ensureSandboxWorkspaceVm").mockResolvedValue(vm);
    const opening = vi.spyOn(SessionHost.prototype, "open");
    const f = await fixture(
      [
        fauxAssistantMessage([fauxToolCall("mcp__picked__echo", { text: "hi" })], {
          stopReason: "toolUse",
        }),
        fauxAssistantMessage("SANDBOX_DONE"),
      ],
      { mcpServers: ["picked", "lazy", "remote"], allowedHosts: ["mcp.example.com"] },
    );
    // Sandboxes trust their project for skills; its mcp.json must still never load.
    writeMcpJson(join(f.dir, ".pi"), {
      project: echoServer(marker("project"), { exposure: "direct" }),
    });
    await f.manager.startSession(f.session.id, f.workspace);
    expect(ensure).toHaveBeenCalledOnce();
    const notices: string[] = [];
    f.manager.subscribe(f.session.id, (message) => {
      if (message.type === "extension_ui_notification" && message.method === "notify")
        notices.push(message.message ?? "");
    });

    await prompt(f.manager, f.session.id, "Echo hi");
    expect(read(marker("picked"))).toContain('call echo {"text":"hi"}');
    expect(await toolResults(f.manager, f.session.id)).toEqual([
      expect.stringContaining("echo:hi"),
    ]);
    await waitFor(() => notices.length > 0, "MCP startup notice");
    expect(notices).toEqual([
      expect.stringContaining('"remote" is blocked in this sandbox: evil.test is not in'),
    ]);

    // Both picked stdio servers started through the VM, in the guest workspace.
    const guestCwd = resolveSandboxGuestCwd(f.workspace);
    expect(peers.map((peer) => peer.argv)).toEqual([
      [process.execPath, ECHO_SERVER],
      [process.execPath, ECHO_SERVER],
    ]);
    expect(peers.every((peer) => peer.cwd === guestCwd)).toBe(true);
    // The peers get exactly the configured env, nothing from the host.
    expect(
      peers
        .map((peer) => peer.env)
        .sort((a, b) => a!.MCP_ECHO_MARKER!.localeCompare(b!.MCP_ECHO_MARKER!)),
    ).toEqual([rootsEnv("lazy"), rootsEnv("picked")]);
    // Servers can ask for roots/list: it is the guest path, never the host mount.
    const guestRoot = `file://${guestCwd}`;
    await waitFor(
      () => read(marker("picked")).includes("roots ") && read(marker("lazy")).includes("roots "),
      "roots/list answers",
    );
    for (const name of ["picked", "lazy"]) {
      const text = read(marker(name));
      expect(text).toContain(`roots ${JSON.stringify([guestRoot])}`);
      expect(text).not.toContain(f.dir);
    }
    expect(existsSync(marker("unpicked"))).toBe(false);
    expect(existsSync(marker("project"))).toBe(false);

    const { harness } = await opening.mock.results.at(-1)!.value;
    const id = f.storage.getSession(f.session.id)!.serverDurable!.conversationId as ConversationId;
    const agent = await (await harness.conversation(id, BACKGROUND_CONTEXT))!.agent(
      BACKGROUND_CONTEXT,
    );
    const offered = agent.tools.map((tool: { name: string }) => tool.name);
    expect(offered).toEqual(expect.arrayContaining(["codemode", "mcp__picked__echo"]));
    expect(offered.filter((name: string) => name.startsWith("mcp__"))).toEqual([
      "mcp__picked__echo",
    ]);
    // The codemode server keeps its exposure in a sandbox: callable from scripts, not offered.
    expect(agent.callable.map((tool: { name: string }) => tool.name)).toContain("mcp__lazy__echo");
  });

  it.each([
    ["deny", 2, false],
    ["allow for this session", 1, true],
  ] as const)(
    "asks on the phone before loading a project's mcp.json (%s)",
    async (_label, option, spawns) => {
      const marker = join(agentDir, "project-echo.marker");
      const f = await fixture([]);
      writeMcpJson(join(f.dir, ".pi"), { project: echoServer(marker, { exposure: "direct" }) });
      const dialogs: string[] = [];
      f.manager.subscribeStartupUI(f.session.id, (message) => {
        if (message.type !== "extension_ui_request" || message.method !== "select") return;
        dialogs.push(message.title ?? "");
        // The decision must come before any project MCP server can spawn.
        expect(existsSync(marker)).toBe(false);
        void f.manager.respondToUIRequest(f.session.id, {
          type: "extension_ui_response",
          id: message.id,
          value: PROJECT_TRUST_OPTIONS[option],
        });
      });
      await f.manager.startSession(f.session.id, f.workspace);

      expect(dialogs).toEqual([expect.stringContaining("Trust project folder?")]);
      if (spawns) await waitFor(() => existsSync(marker), "project MCP server spawn");
      else {
        await new Promise((resolve) => setTimeout(resolve, 300));
        expect(existsSync(marker)).toBe(false);
        expect(new ProjectTrustStore(agentDir).get(f.dir)).toBe(false);
      }
    },
  );
});
