import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  ProjectTrustStore,
  type AgentSession,
  type ResourceLoader,
} from "@earendil-works/pi-coding-agent";
import type { SdkBackendConfig } from "../src/sdk-backend.js";
import { PROJECT_TRUST_OPTIONS, PROJECT_TRUST_TIMEOUT_MS } from "../src/project-trust.js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AgentConfigurationError } from "../src/agent-launch-errors.js";
import { resolveSelectedAgentExtensionPaths } from "../src/agent-extension-selection.js";
import type { AgentDefinition } from "../src/agent-launch-service.js";
import { availableMcpBuiltinNames } from "../src/host-mcp-extensions.js";
import * as GondolinManagerModule from "../src/gondolin-manager.js";
import { resolveSandboxGuestCwd, SdkBackend } from "../src/sdk-backend.js";
import { SessionManager as ManagedSessions } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import { serverResourceId } from "../src/server-resource-id.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import type { Session, Workspace } from "../src/types.js";

const FIXTURE = fileURLToPath(new URL("./fixtures/mcp-echo-server.mjs", import.meta.url));

function makeSession(): Session {
  const now = Date.now();
  return {
    id: "host-mcp-session",
    workspaceId: "workspace-1",
    status: "starting",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    model: "fake/fake-model",
  };
}

/**
 * OpenAI-compatible endpoint whose first completion calls `mcp__echo__echo`
 * and whose second (after the tool result) answers with text.
 */
function startFakeModel(): Promise<{ server: Server; baseUrl: string }> {
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const sawToolResult = (JSON.parse(body || "{}").messages ?? []).some(
        (m: { role?: string }) => m.role === "tool",
      );
      const chunk = (delta: object, finish: string | null) =>
        `data: ${JSON.stringify({
          id: "chatcmpl-1",
          object: "chat.completion.chunk",
          created: 1,
          model: "fake-model",
          choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`;
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (sawToolResult) {
        res.write(chunk({ role: "assistant", content: "done" }, null));
        res.write(chunk({}, "stop"));
      } else {
        res.write(
          chunk(
            {
              role: "assistant",
              tool_calls: [
                {
                  index: 0,
                  id: "call_1",
                  type: "function",
                  function: { name: "mcp__echo__echo", arguments: '{"text":"hi"}' },
                },
              ],
            },
            null,
          ),
        );
        res.write(chunk({}, "tool_calls"));
      }
      res.end("data: [DONE]\n\n");
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") throw new Error("no port");
      resolve({ server, baseUrl: `http://127.0.0.1:${address.port}/v1` });
    });
  });
}

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
}

describe("host MCP/codemode/tool-search activation", { concurrent: false }, () => {
  let cwd: string;
  let agentDir: string;
  let marker: string;
  let observed: string;
  let previousAgentDir: string | undefined;
  let fakeModel: { server: Server; baseUrl: string };
  const backends: SdkBackend[] = [];

  beforeEach(async () => {
    cwd = mkdtempSync(join(tmpdir(), "oppi-host-mcp-cwd-"));
    agentDir = mkdtempSync(join(tmpdir(), "oppi-host-mcp-agent-"));
    marker = join(agentDir, "mcp-echo.marker");
    observed = join(agentDir, "tool-calls.log");
    previousAgentDir = process.env.PI_CODING_AGENT_DIR;
    process.env.PI_CODING_AGENT_DIR = agentDir;
    fakeModel = await startFakeModel();

    writeFileSync(join(agentDir, "auth.json"), "{}");
    writeFileSync(
      join(agentDir, "models.json"),
      JSON.stringify({
        providers: {
          fake: {
            baseUrl: fakeModel.baseUrl,
            api: "openai-completions",
            apiKey: "test-key",
            models: [{ id: "fake-model", input: ["text"], contextWindow: 32_000, maxTokens: 1024 }],
          },
        },
      }),
    );
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          echo: {
            command: process.execPath,
            args: [FIXTURE],
            env: { MCP_ECHO_MARKER: marker },
            exposure: "direct",
          },
        },
      }),
    );
    // A normally discovered permission-style hook that records every tool_call.
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    writeFileSync(
      join(agentDir, "extensions", "observer.ts"),
      `import { appendFileSync } from "node:fs";
export default function (pi) {
  pi.on("tool_call", async (event) => {
    appendFileSync(${JSON.stringify(observed)}, event.toolName + "\\n");
  });
}
`,
    );
  });

  afterEach(async () => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    for (const backend of backends.splice(0)) await backend.dispose();
    fakeModel.server.close();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
  });

  async function create(options: {
    agentDefinition?: AgentDefinition;
    onEvent?: SdkBackendConfig["onEvent"];
    onUIBridgeReady?: SdkBackendConfig["onUIBridgeReady"];
    hasUI?: SdkBackendConfig["hasUI"];
  }): Promise<SdkBackend> {
    const backend = await SdkBackend.create({
      session: makeSession(),
      workspace: {
        id: "workspace-1",
        name: "Host MCP",
        runtime: "host",
        hostMount: cwd,
      } as Workspace,
      onEvent: vi.fn(),
      onEnd: vi.fn(),
      ...options,
    });
    backends.push(backend);
    return backend;
  }

  const loaderOf = (backend: SdkBackend): ResourceLoader =>
    (backend as unknown as { runtime: { services: { resourceLoader: ResourceLoader } } }).runtime
      .services.resourceLoader;
  const sessionOf = (backend: SdkBackend): AgentSession =>
    (backend as unknown as { runtime: { session: AgentSession } }).runtime.session;
  const extensionPaths = (backend: SdkBackend): string[] =>
    loaderOf(backend)
      .getExtensions()
      .extensions.map((extension) => extension.path);

  it("connects Pi's mcp.json servers and routes a model tool call through tool_call hooks", async () => {
    const onEvent = vi.fn();
    const backend = await create({ onEvent, hasUI: () => true });
    expect(
      onEvent.mock.calls.some(
        ([event]) => event.type === "extension_ui_request" && event.method === "select",
      ),
    ).toBe(false);
    expect(extensionPaths(backend)).toEqual(
      expect.arrayContaining(["builtin:mcp", "builtin:codemode", "builtin:tool-search"]),
    );

    await waitFor(() => existsSync(marker), "MCP server spawn");
    await waitFor(
      () => sessionOf(backend).getActiveToolNames().includes("mcp__echo__echo"),
      "mcp__echo__echo to be exposed directly",
    );

    await backend.prompt("call the echo tool");
    await waitFor(
      () => existsSync(marker) && readFileSync(marker, "utf8").includes("call echo"),
      "MCP tools/call",
    );
    expect(readFileSync(marker, "utf8")).toContain('call echo {"text":"hi"}');
    expect(readFileSync(observed, "utf8").split("\n")).toContain("mcp__echo__echo");
    const pid = Number(readFileSync(marker, "utf8").match(/^spawn (\d+)/)?.[1]);
    expect(pid).toBeGreaterThan(0);
    await backend.dispose();
    await waitFor(() => {
      try {
        process.kill(pid, 0);
        return false;
      } catch {
        return true;
      }
    }, "echo child to exit after dispose");
  });

  it("honors Pi's -builtin:<name> setting ", async () => {
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ extensions: ["-builtin:mcp"] }),
    );
    const backend = await create({});
    expect(extensionPaths(backend)).not.toContain("builtin:mcp");
    expect(extensionPaths(backend)).toContain("builtin:codemode");
    expect(existsSync(marker)).toBe(false);
  });

  it("runs only owner-picked global servers in a sandbox, with stdio inside the VM", async () => {
    // The agent can write the sandbox's own .pi/mcp.json; it must never load.
    mkdirSync(join(cwd, ".pi"), { recursive: true });
    writeFileSync(
      join(cwd, ".pi", "mcp.json"),
      JSON.stringify({ mcpServers: { planted: { command: process.execPath, args: [FIXTURE] } } }),
    );
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          echo: { command: "node", args: ["echo.mjs"], exposure: "direct" },
          // Default (codemode) exposure: reached through tool_search, since sandboxes
          // run no model-written codemode scripts on the host.
          searchable: { command: "node", args: ["search.mjs"] },
          unpicked: { command: "node", args: ["other.mjs"], exposure: "direct" },
          secretive: {
            command: "node",
            args: ["echo.mjs"],
            env: { TOKEN: "${HOST_TOKEN}" },
            exposure: "direct",
          },
        },
      }),
    );
    const qemuSpy = vi.spyOn(GondolinManagerModule, "isQemuAvailable").mockResolvedValue(true);
    const execResult = { exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0), ok: true };
    const mcpExecs: Array<{ argv: string[]; cwd?: string; env?: Record<string, string> }> = [];
    const toolCalls: unknown[] = [];
    // Plays the in-VM echo server over the transport's stdin/stdout pipes.
    const vm = {
      fs: {
        access: vi.fn(async () => undefined),
        mkdir: vi.fn(async () => undefined),
        readFile: vi.fn(async () => Buffer.alloc(0)),
        writeFile: vi.fn(async () => undefined),
      },
      exec: vi.fn(
        (
          argv: string[] | string,
          options?: { stdin?: boolean; cwd?: string; env?: Record<string, string> },
        ) => {
          if (!options?.stdin)
            return Object.assign(Promise.resolve(execResult), {
              output: async function* () {},
              write: () => {},
              end: () => {},
            });
          mcpExecs.push({ argv: argv as string[], cwd: options.cwd, env: options.env });
          const queue: Buffer[] = [];
          let wake: (() => void) | undefined;
          let ended = false;
          let exit: (() => void) | undefined;
          const exited = new Promise<typeof execResult>((resolve) => {
            exit = () => resolve(execResult);
          });
          const push = (message: object): void => {
            queue.push(Buffer.from(JSON.stringify(message) + "\n"));
            wake?.();
          };
          return Object.assign(exited, {
            write: (data: string) => {
              for (const line of data.split("\n").filter(Boolean)) {
                const message = JSON.parse(line) as {
                  id?: number;
                  method: string;
                  params?: { arguments?: unknown; protocolVersion?: string };
                };
                if (message.id === undefined) continue;
                if (message.method === "tools/call") toolCalls.push(message.params?.arguments);
                if (message.method === "initialize")
                  push({
                    jsonrpc: "2.0",
                    method: "notifications/message",
                    params: { level: "info", data: "hello from the VM" },
                  });
                const result =
                  message.method === "initialize"
                    ? {
                        protocolVersion: message.params?.protocolVersion,
                        capabilities: { tools: {} },
                        serverInfo: { name: "echo", version: "1" },
                      }
                    : message.method === "tools/list"
                      ? {
                          tools: [
                            {
                              name: "echo",
                              inputSchema: {
                                type: "object",
                                properties: { text: { type: "string" } },
                              },
                            },
                          ],
                        }
                      : message.method === "tools/call"
                        ? { content: [{ type: "text", text: "hi" }] }
                        : {};
                push({ jsonrpc: "2.0", id: message.id, result });
              }
            },
            end: () => {
              ended = true;
              wake?.();
              exit?.();
            },
            output: async function* () {
              while (!ended || queue.length) {
                if (!queue.length) await new Promise<void>((resolve) => (wake = resolve));
                const data = queue.shift();
                if (data) yield { stream: "stdout" as const, data };
              }
            },
          });
        },
      ),
    };
    const sdkBackendType = SdkBackend as unknown as {
      _gondolinManager?: { ensureWorkspaceVm: () => Promise<typeof vm> };
    };
    const previousManager = sdkBackendType._gondolinManager;
    const ensureWorkspaceVm = vi.fn(async () => vm);
    sdkBackendType._gondolinManager = { ensureWorkspaceVm };
    const session = makeSession();
    try {
      const backend = await SdkBackend.create({
        session,
        workspace: {
          id: "workspace-1",
          name: "Host MCP Sandbox",
          runtime: "sandbox",
          hostMount: cwd,
          sandboxConfig: {
            allowedHosts: [],
            mcpServers: ["echo", "searchable", "secretive", "gone"],
          },
        } as Workspace,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });
      backends.push(backend);
      const builtins = extensionPaths(backend).filter((path) => path.startsWith("builtin:"));
      expect(builtins.sort()).toEqual(["builtin:mcp", "builtin:tool-search"]);
      await waitFor(
        () => sessionOf(backend).getActiveToolNames().includes("mcp__echo__echo"),
        "sandboxed mcp__echo__echo",
      );
      // The default-exposure server is reachable through tool_search, never codemode.
      const active = sessionOf(backend).getActiveToolNames();
      expect(active).toContain("tool_search");
      expect(active).not.toContain("codemode");
      await waitFor(
        () =>
          sessionOf(backend)
            .getAllTools()
            .some((tool) => tool.name === "mcp__searchable__echo"),
        "searchable server tools",
      );
      // Only the picked, eligible servers started, in the VM, at the guest workspace.
      expect(mcpExecs.map(({ argv }) => argv).sort()).toEqual([
        ["node", "echo.mjs"],
        ["node", "search.mjs"],
      ]);
      for (const exec of mcpExecs) {
        expect(exec.cwd).toMatch(/^\/workspace/);
        expect(exec.env).toEqual({});
      }
      // An in-VM server logs to this sandbox's own file, not the shared host mcp.log.
      const sandboxLog = join(agentDir, "oppi", "sandbox-mcp-logs", "workspace-1.log");
      await waitFor(() => existsSync(sandboxLog), "sandbox MCP log");
      expect(readFileSync(sandboxLog, "utf8")).toContain("hello from the VM");
      expect(existsSync(join(agentDir, "mcp.log"))).toBe(false);
      const names = sessionOf(backend)
        .getAllTools()
        .map((tool) => tool.name);
      expect(names).not.toContainEqual(
        expect.stringMatching(/^mcp__(planted|unpicked|secretive)__/),
      );

      await backend.prompt("call the echo tool");
      await waitFor(() => toolCalls.length > 0, "in-VM tools/call");
      expect(toolCalls).toEqual([{ text: "hi" }]);
      // MCP uses this session's VM; ensuring another could stop a newer session's VM.
      expect(ensureWorkspaceVm).toHaveBeenCalledTimes(1);
      expect(readFileSync(observed, "utf8").split("\n")).toContain("mcp__echo__echo");
      // No host process ever ran for any server.
      expect(existsSync(marker)).toBe(false);
      expect(session.warnings ?? []).toEqual([]);

      // A workspace Tools list admits tools by exact name, so MCP tools cannot pass it.
      const limitedSession = { ...makeSession(), id: "limited" };
      const limited = SdkBackend.create({
        session: limitedSession,
        workspace: {
          id: "workspace-1",
          name: "Host MCP Sandbox",
          runtime: "sandbox",
          hostMount: cwd,
          tools: ["read", "bash"],
          sandboxConfig: { allowedHosts: [], mcpServers: ["echo"] },
        } as Workspace,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });
      backends.push(await limited);
      expect(limitedSession.warnings).toEqual([
        expect.stringContaining("Tools list hides its MCP servers"),
      ]);
    } finally {
      sdkBackendType._gondolinManager = previousManager;
      qemuSpy.mockRestore();
    }
  });

  it("runs a picked stdio MCP server inside a real Gondolin VM", { timeout: 150_000 }, async () => {
    if (
      GondolinManagerModule.sandboxUnsupportedNodeMessage() ||
      !(await GondolinManagerModule.isQemuAvailable())
    )
      return; // Like gondolin-live.test.ts: needs QEMU on this host.
    const workspace = {
      id: "workspace-1",
      name: "Sandbox MCP Live",
      runtime: "sandbox",
      hostMount: cwd,
      sandboxConfig: { allowedHosts: [], mcpServers: ["echo"] },
    } as Workspace;
    const guest = resolveSandboxGuestCwd(workspace);
    writeFileSync(join(cwd, "echo-server.mjs"), readFileSync(FIXTURE));
    writeFileSync(
      join(agentDir, "mcp.json"),
      JSON.stringify({
        mcpServers: {
          echo: {
            command: "node",
            args: [`${guest}/echo-server.mjs`],
            env: { MCP_ECHO_MARKER: `${guest}/marker.log` },
            exposure: "direct",
          },
        },
      }),
    );
    const sdkBackendType = SdkBackend as unknown as { _gondolinManager?: unknown };
    const previousManager = sdkBackendType._gondolinManager;
    const manager = new GondolinManagerModule.GondolinManager();
    sdkBackendType._gondolinManager = manager;
    const inVmMarker = join(cwd, "marker.log");
    try {
      const backend = await SdkBackend.create({
        session: makeSession(),
        workspace,
        onEvent: vi.fn(),
        onEnd: vi.fn(),
      });
      backends.push(backend);
      await waitFor(
        () => sessionOf(backend).getActiveToolNames().includes("mcp__echo__echo"),
        "in-VM mcp__echo__echo",
        60_000,
      );
      await backend.prompt("call the echo tool");
      await waitFor(
        () => existsSync(inVmMarker) && readFileSync(inVmMarker, "utf8").includes("call echo"),
        "in-VM tools/call",
        30_000,
      );
      // The server ran in the guest (Linux pid namespace), writing through the mount.
      expect(readFileSync(inVmMarker, "utf8")).toContain('call echo {"text":"hi"}');
      expect(existsSync(marker)).toBe(false);
    } finally {
      for (const backend of backends.splice(0)) await backend.dispose();
      await manager.stopAll();
      sdkBackendType._gondolinManager = previousManager;
    }
  });

  it("keeps saved Agents exact: builtins load only when explicitly selected", async () => {
    const unselected = await create({
      agentDefinition: { name: "Exact", resources: { extensionIds: [] } },
    });
    expect(extensionPaths(unselected).filter((path) => path.startsWith("builtin:"))).toEqual([]);
    expect(existsSync(marker)).toBe(false);
    await unselected.dispose();
    backends.length = 0;

    const selected = await create({
      agentDefinition: { name: "Exact", resources: { extensionIds: ["builtin:mcp"] } },
    });
    expect(extensionPaths(selected).filter((path) => path.startsWith("builtin:"))).toEqual([
      "builtin:mcp",
    ]);
    expect(extensionPaths(selected).some((path) => path.includes("observer.ts"))).toBe(false);
    await waitFor(() => existsSync(marker), "selected MCP server spawn");
  });

  function projectMcp(): void {
    mkdirSync(join(cwd, ".pi"), { recursive: true });
    writeFileSync(join(cwd, ".pi", "mcp.json"), readFileSync(join(agentDir, "mcp.json")));
    rmSync(join(agentDir, "mcp.json"));
  }

  async function expectEcho(backend: SdkBackend): Promise<void> {
    await waitFor(
      () => sessionOf(backend).getActiveToolNames().includes("mcp__echo__echo"),
      "project echo tool",
    );
    expect(readFileSync(marker, "utf8")).toContain("spawn ");
  }

  it.each([false, true])(
    "honors saved project trust %s before project MCP session_start",
    async (trusted) => {
      projectMcp();
      new ProjectTrustStore(agentDir).set(cwd, trusted);
      const onEvent = vi.fn();
      const backend = await create({ hasUI: () => true, onEvent });
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(trusted);
      expect(
        onEvent.mock.calls.some(
          ([event]) => event.type === "extension_ui_request" && event.method === "select",
        ),
      ).toBe(false);
      if (trusted) await expectEcho(backend);
      else {
        expect(sessionOf(backend).getActiveToolNames()).not.toContain("mcp__echo__echo");
        expect(existsSync(marker)).toBe(false);
      }
    },
  );

  it.each([0, 1, 2, "dismiss"] as const)(
    "resolves an unanswered project's phone choice %s through the real dialog bridge",
    async (choice) => {
      projectMcp();
      let bridge: Parameters<NonNullable<SdkBackendConfig["onUIBridgeReady"]>>[0];
      let prompts = 0;
      const backend = await create({
        hasUI: () => true,
        onUIBridgeReady: (ready) => {
          if (ready) bridge = ready;
        },
        onEvent: (event) => {
          if (event.type !== "extension_ui_request" || event.method !== "select") return;
          prompts++;
          expect(existsSync(marker)).toBe(false);
          expect(event.title).toContain("Trust project folder?");
          expect(event.options).toEqual(PROJECT_TRUST_OPTIONS);
          expect(event.timeout).toBe(PROJECT_TRUST_TIMEOUT_MS);
          expect(
            bridge?.respond({
              id: event.id,
              ...(choice === "dismiss"
                ? { cancelled: true }
                : { value: PROJECT_TRUST_OPTIONS[choice] }),
            }),
          ).toBe(true);
        },
      });
      expect(prompts).toBe(1);
      const trusted = choice !== 2;
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(trusted);
      expect(new ProjectTrustStore(agentDir).get(cwd)).toBe(
        choice === 0 ? true : choice === 2 ? false : null,
      );
      if (trusted) await expectEcho(backend);
      else expect(existsSync(marker)).toBe(false);
      if (choice === 1) {
        await backend.reloadResources();
        await expectEcho(backend);
        expect(prompts).toBe(1);
        expect(new ProjectTrustStore(agentDir).get(cwd)).toBeNull();
      }
    },
    30_000,
  );

  it.each([
    ["default", undefined],
    ["select", 0],
    ["select", -1],
    ["confirm", 0],
    ["confirm", -1],
    ["input", 0],
    ["input", -1],
  ] as const)("bounds unanswered trust UI %s timeout %s at 15 seconds", async (method, timeout) => {
    projectMcp();
    if (method !== "default")
      writeFileSync(
        join(agentDir, "extensions", "trust.ts"),
        `
      export default function(pi) {
        pi.on("project_trust", async (_event, ctx) => {
          await ctx.ui.${method}("Handler trust?", ${method === "select" ? '["yes", "no"]' : '"details"'}, { timeout: ${timeout} });
          return { trusted: "undecided" };
        });
      }`,
      );
    let requested!: () => void;
    const request = new Promise<void>((resolve) => {
      requested = resolve;
    });
    let settled = false;
    let firstId: string | undefined;
    let bridge: Parameters<NonNullable<SdkBackendConfig["onUIBridgeReady"]>>[0];
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    const starting = create({
      hasUI: () => true,
      onUIBridgeReady: (ready) => {
        if (ready) bridge = ready;
      },
      onEvent: (event) => {
        if (event.type === "extension_ui_request" && !firstId) {
          firstId = event.id;
          expect(event.timeout).toBe(PROJECT_TRUST_TIMEOUT_MS);
          requested();
        } else if (event.type === "extension_ui_request") {
          expect(bridge?.respond({ id: event.id, cancelled: true })).toBe(true);
        } else if (event.type === "extension_ui_request_settled" && event.id === firstId)
          settled = true;
      },
    });
    await request;
    vi.advanceTimersByTime(PROJECT_TRUST_TIMEOUT_MS - 1);
    expect(settled).toBe(false);
    expect(existsSync(marker)).toBe(false);
    vi.advanceTimersByTime(1);
    expect(settled).toBe(true);
    vi.useRealTimers();
    const backend = await starting;
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(true);
    expect(new ProjectTrustStore(agentDir).get(cwd)).toBeNull();
    await expectEcho(backend);
  });

  it.each([true, false])(
    "hands project_trust handlers only Pi's declared ui methods (hasUI %s)",
    async (hasUI) => {
      projectMcp();
      const seen = join(agentDir, "trust-ui-keys.json");
      writeFileSync(
        join(agentDir, "extensions", "trust.ts"),
        `import { writeFileSync } from "node:fs";
      export default function(pi) {
        pi.on("project_trust", async (_event, ctx) => {
          writeFileSync(${JSON.stringify(seen)}, JSON.stringify(Object.keys(ctx.ui).sort()));
          return { trusted: "yes" };
        });
      }`,
      );
      await create({ hasUI: () => hasUI });
      expect(JSON.parse(readFileSync(seen, "utf8"))).toEqual([
        "confirm",
        "input",
        "notify",
        "select",
      ]);
    },
  );

  it("resolves trust dialogs immediately without a UI, like Pi's CLI context", async () => {
    projectMcp();
    const answers = join(agentDir, "trust-headless.json");
    writeFileSync(
      join(agentDir, "extensions", "trust.ts"),
      `import { writeFileSync } from "node:fs";
      export default function(pi) {
        pi.on("project_trust", async (_event, ctx) => {
          const select = await ctx.ui.select("Trust?", ["yes", "no"]);
          const confirm = await ctx.ui.confirm("Trust?", "details");
          const input = await ctx.ui.input("Trust?", "placeholder");
          writeFileSync(${JSON.stringify(answers)}, JSON.stringify({ hasUI: ctx.hasUI, select: select ?? null, confirm, input: input ?? null }));
          return { trusted: "undecided" };
        });
      }`,
    );
    const onEvent = vi.fn();
    // Real timers: a regression would wait the 15 s bound and fail the test timeout.
    const backend = await create({ hasUI: () => false, onEvent });
    expect(JSON.parse(readFileSync(answers, "utf8"))).toEqual({
      hasUI: false,
      select: null,
      confirm: false,
      input: null,
    });
    expect(onEvent.mock.calls.some(([event]) => event.type === "extension_ui_request")).toBe(false);
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(true);
  }, 10_000);

  it.each(["deny", "allow"] as const)(
    "asks for trust when protected files appear after a clean start and reload (%s)",
    async (answer) => {
      // Only a project MCP server exists, and only after startup.
      const mcpJson = readFileSync(join(agentDir, "mcp.json"));
      rmSync(join(agentDir, "mcp.json"));
      let bridge: Parameters<NonNullable<SdkBackendConfig["onUIBridgeReady"]>>[0];
      let prompts = 0;
      const backend = await create({
        hasUI: () => true,
        onUIBridgeReady: (ready) => {
          if (ready) bridge = ready;
        },
        onEvent: (event) => {
          if (event.type !== "extension_ui_request" || event.method !== "select") return;
          prompts++;
          // The decision must come before any project MCP server can spawn.
          expect(existsSync(marker)).toBe(false);
          expect(
            bridge?.respond({
              id: event.id,
              value: PROJECT_TRUST_OPTIONS[answer === "deny" ? 2 : 1],
            }),
          ).toBe(true);
        },
      });
      expect(prompts).toBe(0);
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(true);

      mkdirSync(join(cwd, ".pi"), { recursive: true });
      writeFileSync(join(cwd, ".pi", "mcp.json"), mcpJson);
      await backend.reloadResources();

      expect(prompts).toBe(1);
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(answer === "allow");
      if (answer === "allow") await expectEcho(backend);
      else expect(existsSync(marker)).toBe(false);
    },
  );

  it.each(["real cwd, symlinked skill path", "symlinked cwd, real skill path"] as const)(
    "rejects an explicit Skill inside a denied project's .pi through a symlink (%s)",
    async (shape) => {
      const skill = join(cwd, ".pi", "skills", "s");
      mkdirSync(skill, { recursive: true });
      writeFileSync(
        join(skill, "SKILL.md"),
        "---\nname: s\ndescription: Project skill.\n---\nBody.\n",
      );
      new ProjectTrustStore(agentDir).set(cwd, false);
      const link = `${cwd}-link`;
      symlinkSync(realpathSync(cwd), link);
      try {
        const symlinkedCwd = shape.startsWith("symlinked cwd");
        const attempt = SdkBackend.create({
          session: makeSession(),
          workspace: {
            id: "workspace-1",
            name: "Host MCP",
            runtime: "host",
            hostMount: symlinkedCwd ? link : realpathSync(cwd),
          } as Workspace,
          agentDefinition: {
            name: "Skill",
            resources: {
              skillPaths: [
                symlinkedCwd
                  ? join(realpathSync(cwd), ".pi", "skills", "s")
                  : join(link, ".pi", "skills", "s"),
              ],
            },
          },
          onEvent: vi.fn(),
          onEnd: vi.fn(),
        });
        await expect(attempt).rejects.toMatchObject({ code: "agent_skills_unavailable" });
      } finally {
        rmSync(link, { force: true });
      }
    },
  );

  it.each(["path through the .pi symlink", "real symlink target"] as const)(
    "rejects an explicit Skill in a denied project whose .pi is a symlink (%s)",
    async (shape) => {
      const target = `${cwd}-pi-target`;
      const skill = join(target, "skills", "s");
      mkdirSync(skill, { recursive: true });
      writeFileSync(
        join(skill, "SKILL.md"),
        "---\nname: s\ndescription: Project skill.\n---\nBody.\n",
      );
      symlinkSync(target, join(cwd, ".pi"));
      new ProjectTrustStore(agentDir).set(cwd, false);
      try {
        const attempt = SdkBackend.create({
          session: makeSession(),
          workspace: {
            id: "workspace-1",
            name: "Host MCP",
            runtime: "host",
            hostMount: cwd,
          } as Workspace,
          agentDefinition: {
            name: "Skill",
            resources: {
              skillPaths: [
                shape === "real symlink target"
                  ? join(realpathSync(target), "skills", "s")
                  : join(cwd, ".pi", "skills", "s"),
              ],
            },
          },
          onEvent: vi.fn(),
          onEnd: vi.fn(),
        });
        await expect(attempt).rejects.toMatchObject({ code: "agent_skills_unavailable" });
      } finally {
        rmSync(target, { recursive: true, force: true });
      }
    },
  );

  it("routes startup phone answers through SessionManager before the backend is active", async () => {
    projectMcp();
    const storage = new Storage(join(agentDir, "oppi"));
    const workspace = {
      id: "workspace-1",
      name: "Trust",
      runtime: "host",
      hostMount: cwd,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    } as Workspace;
    storage.saveWorkspace(workspace);
    const session = storage.createSession("Trust", "fake/fake-model");
    session.workspaceId = workspace.id;
    storage.saveSession(session);
    const rendererLoad = vi
      .spyOn(MobileRendererRegistry.prototype, "loadAllRenderers")
      .mockResolvedValue({ loaded: [], errors: [] });
    const manager = new ManagedSessions(storage);
    let requests = 0;
    const detach = manager.subscribeStartupUI(session.id, (event) => {
      if (event.type !== "extension_ui_request") return;
      requests++;
      expect(manager.getActiveSession(session.id)).toBeUndefined();
      expect(existsSync(marker)).toBe(false);
      expect(
        manager.respondToUIRequest(session.id, {
          type: "extension_ui_response",
          id: event.id,
          value: PROJECT_TRUST_OPTIONS[2],
        }),
      ).toBe(true);
    });
    try {
      const ready = await manager.startSession(session.id, workspace);
      expect(ready.status).toBe("ready");
      expect(requests).toBe(1);
      expect(new ProjectTrustStore(agentDir).get(cwd)).toBe(false);
      expect(existsSync(marker)).toBe(false);
    } finally {
      detach();
      await manager.stopAll();
      rendererLoad.mockRestore();
    }
  });

  it("inherits a parent-only saved decision", async () => {
    projectMcp();
    new ProjectTrustStore(agentDir).set(tmpdir(), false);
    const backend = await create({});
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(false);
    expect(existsSync(marker)).toBe(false);
  });

  it.each([false, true])(
    "a saved decision %s beats the opposite defaultProjectTrust",
    async (trusted) => {
      projectMcp();
      new ProjectTrustStore(agentDir).set(cwd, trusted);
      writeFileSync(
        join(agentDir, "settings.json"),
        JSON.stringify({ defaultProjectTrust: trusted ? "never" : "always" }),
      );
      const backend = await create({});
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(trusted);
      if (trusted) await expectEcho(backend);
      else expect(existsSync(marker)).toBe(false);
    },
  );

  it("uses the closest saved parent decision", async () => {
    projectMcp();
    const store = new ProjectTrustStore(agentDir);
    store.set(tmpdir(), true);
    store.set(cwd, false);
    const backend = await create({});
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(false);
    expect(existsSync(marker)).toBe(false);
  });

  it.each([false, true])(
    "gates all protected project resources before session_start (%s)",
    async (trusted) => {
      const pi = join(cwd, ".pi");
      for (const directory of ["extensions", "skills/project", "prompts", "themes"]) {
        mkdirSync(join(pi, directory), { recursive: true });
      }
      mkdirSync(join(cwd, ".agents/skills/agents-project"), { recursive: true });
      writeFileSync(
        join(pi, "settings.json"),
        JSON.stringify({ shellCommandPrefix: "PROJECT_SETTING" }),
      );
      writeFileSync(
        join(pi, "extensions/project.ts"),
        `import { appendFileSync } from "node:fs";
      export default function(pi) { appendFileSync(${JSON.stringify(marker)}, "project factory\\n"); }`,
      );
      writeFileSync(
        join(pi, "skills/project/SKILL.md"),
        "---\nname: project\ndescription: Project skill\n---\nProject skill",
      );
      writeFileSync(
        join(cwd, ".agents/skills/agents-project/SKILL.md"),
        "---\nname: agents-project\ndescription: Agents project skill\n---\nAgents skill",
      );
      writeFileSync(join(pi, "prompts/project.md"), "Project prompt");
      const theme = JSON.parse(
        readFileSync(
          new URL(
            "../node_modules/@earendil-works/pi-coding-agent/dist/modes/interactive/theme/dark.json",
            import.meta.url,
          ),
          "utf8",
        ),
      );
      writeFileSync(join(pi, "themes/project.json"), JSON.stringify({ ...theme, name: "project" }));
      writeFileSync(join(cwd, "AGENTS.md"), "PROJECT_CONTEXT");
      writeFileSync(join(pi, "SYSTEM.md"), "PROJECT_SYSTEM");
      writeFileSync(join(pi, "APPEND_SYSTEM.md"), "PROJECT_APPEND");
      new ProjectTrustStore(agentDir).set(cwd, trusted);
      const backend = await create({});
      expect(
        loaderOf(backend)
          .getAgentsFiles()
          .agentsFiles.some((file) => file.content.includes("PROJECT_CONTEXT")),
      ).toBe(true);
      expect(extensionPaths(backend).some((path) => path.includes("project.ts"))).toBe(trusted);
      expect(existsSync(marker)).toBe(trusted);
      expect(
        sessionOf(backend).settingsManager.getShellCommandPrefix()?.includes("PROJECT_SETTING") ??
          false,
      ).toBe(trusted);
      expect(
        loaderOf(backend)
          .getSkills()
          .skills.some((skill) => skill.name === "project"),
      ).toBe(trusted);
      expect(
        loaderOf(backend)
          .getSkills()
          .skills.some((skill) => skill.name === "agents-project"),
      ).toBe(trusted);
      expect(
        loaderOf(backend)
          .getPrompts()
          .prompts.some((prompt) => prompt.name === "project"),
      ).toBe(trusted);
      expect(
        loaderOf(backend)
          .getThemes()
          .themes.some((theme) => theme.name === "project"),
      ).toBe(trusted);
      expect(loaderOf(backend).getSystemPrompt()?.includes("PROJECT_SYSTEM") ?? false).toBe(
        trusted,
      );
      expect(
        loaderOf(backend)
          .getAppendSystemPrompt()
          .some((prompt) => prompt.includes("PROJECT_APPEND")),
      ).toBe(trusted);
    },
  );

  it("allows an unanswered project immediately without an attached UI", async () => {
    projectMcp();
    const onEvent = vi.fn();
    const backend = await create({ onEvent });
    await expectEcho(backend);
    expect(new ProjectTrustStore(agentDir).get(cwd)).toBeNull();
    expect(
      onEvent.mock.calls.some(
        ([event]) => event.type === "extension_ui_request" && event.method === "select",
      ),
    ).toBe(false);
  });

  it.each(["always", "never"])("respects explicit agent defaultProjectTrust %s", async (policy) => {
    projectMcp();
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ defaultProjectTrust: policy }));
    const backend = await create({});
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(policy === "always");
    if (policy === "always") await expectEcho(backend);
    else expect(existsSync(marker)).toBe(false);
  });

  it("gives user project_trust handlers precedence over a closer saved denial", async () => {
    projectMcp();
    new ProjectTrustStore(agentDir).set(cwd, false);
    writeFileSync(
      join(agentDir, "extensions", "trust.ts"),
      `export default function(pi) {
      pi.on("project_trust", () => ({ trusted: "undecided" }));
      pi.on("project_trust", () => ({ trusted: "yes", remember: true }));
    }`,
    );
    const backend = await create({});
    await expectEcho(backend);
    expect(new ProjectTrustStore(agentDir).get(cwd)).toBe(true);
  });

  it("denies a handler result other than yes/no/undecided instead of falling through", async () => {
    projectMcp();
    new ProjectTrustStore(agentDir).set(cwd, true);
    writeFileSync(
      join(agentDir, "extensions", "trust.ts"),
      `export default function(pi) {
      pi.on("project_trust", () => ({ trusted: "maybe" }));
      pi.on("project_trust", () => ({ trusted: "yes" }));
    }`,
    );
    const backend = await create({});
    expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(false);
    expect(existsSync(marker)).toBe(false);
  });

  it("surfaces a failed remember without discarding the handler's explicit decision", async () => {
    projectMcp();
    new ProjectTrustStore(agentDir).set(cwd, true);
    writeFileSync(
      join(agentDir, "extensions", "trust.ts"),
      `export default function(pi) {
      pi.on("project_trust", () => ({ trusted: "no", remember: true }));
    }`,
    );
    vi.spyOn(ProjectTrustStore.prototype, "set").mockImplementation(() => {
      throw new Error("trust write denied");
    });
    const onEvent = vi.fn();
    await expect(create({ onEvent })).rejects.toThrow("trust write denied");
    expect(onEvent.mock.calls.some(([event]) => event.type === "extension_error")).toBe(false);
    expect(existsSync(marker)).toBe(false);
  });

  it.each([false, true])(
    "bootstrap honors an exact Agent's selected user trust handler (%s)",
    async (selected) => {
      projectMcp();
      const trustPath = join(agentDir, "extensions", "trust.ts");
      const factoryMarker = join(agentDir, "trust-factory.marker");
      writeFileSync(
        trustPath,
        `import { writeFileSync } from "node:fs";
      export default function(pi) {
        writeFileSync(${JSON.stringify(factoryMarker)}, "executed");
        pi.on("project_trust", () => ({ trusted: "no" }));
      }`,
      );
      const backend = await create({
        agentDefinition: {
          name: "Exact trust",
          resources: { extensionIds: selected ? [serverResourceId("extension", trustPath)] : [] },
        },
      });
      expect(sessionOf(backend).settingsManager.isProjectTrusted()).toBe(!selected);
      expect(existsSync(factoryMarker)).toBe(selected);
    },
  );

  it("keeps an unawaited session_start dialog answerable after activation", async () => {
    const answered = join(agentDir, "late-answer.marker");
    writeFileSync(
      join(agentDir, "extensions", "late-ui.ts"),
      `import { writeFileSync } from "node:fs";
      export default function(pi) {
        pi.on("session_start", (_event, ctx) => {
          void ctx.ui.input("Late startup answer").then(value => writeFileSync(${JSON.stringify(answered)}, value ?? "dismissed"));
        });
      }`,
    );
    const storage = new Storage(join(agentDir, "oppi"));
    const workspace = {
      id: "workspace-1",
      name: "Late UI",
      runtime: "host",
      hostMount: cwd,
    } as Workspace;
    storage.saveWorkspace(workspace);
    const session = storage.createSession("Late UI", "fake/fake-model");
    session.workspaceId = workspace.id;
    storage.saveSession(session);
    vi.spyOn(MobileRendererRegistry.prototype, "loadAllRenderers").mockResolvedValue({
      loaded: [],
      errors: [],
    });
    const manager = new ManagedSessions(storage);
    const received: string[] = [];
    const detach = manager.subscribeStartupUI(session.id, (event) => {
      if (event.type === "extension_ui_request" && event.method === "input")
        received.push(event.id);
    });
    try {
      await manager.startSession(session.id, workspace);
      expect(received).toHaveLength(1);
      expect(manager.getPendingUIRequestMessages(session.id)).toEqual(
        expect.arrayContaining([expect.objectContaining({ id: received[0] })]),
      );
      expect(
        manager.respondToUIRequest(session.id, {
          type: "extension_ui_response",
          id: received[0],
          value: "late answer",
        }),
      ).toBe(true);
      await waitFor(() => existsSync(answered), "late startup answer");
      expect(readFileSync(answered, "utf8")).toBe("late answer");
      expect(manager.getPendingUIRequestMessages(session.id)).toEqual([]);
    } finally {
      detach();
      await manager.stopAll();
    }
  });

  it("a denying tool_call hook prevents the MCP call reaching the child", async () => {
    writeFileSync(
      join(agentDir, "extensions", "deny.ts"),
      `import { appendFileSync } from "node:fs";
      export default function(pi) {
        pi.on("tool_call", (event) => {
          if (event.toolName !== "mcp__echo__echo") return;
          appendFileSync(${JSON.stringify(observed)}, event.toolName + "\\n");
          return { block: true, reason: "denied" };
        });
      }`,
    );
    const backend = await create({});
    await expectEcho(backend);
    await backend.prompt("call the echo tool");
    await waitFor(() => !sessionOf(backend).isStreaming, "denied turn completion");
    expect(readFileSync(observed, "utf8")).toContain("mcp__echo__echo");
    expect(readFileSync(marker, "utf8")).not.toContain("call echo");
  });
});

describe("builtin extension availability boundaries", () => {
  it("never offers builtins to terminal-owned mirrors, nor codemode to sandboxes", () => {
    expect(availableMcpBuiltinNames({ managed: false, sandbox: false })).toEqual([]);
    expect(availableMcpBuiltinNames({ managed: true, sandbox: false })).toEqual([
      "mcp",
      "codemode",
      "tool-search",
    ]);
    expect(availableMcpBuiltinNames({ managed: true, sandbox: true })).toEqual([
      "mcp",
      "tool-search",
    ]);
  });

  it("resolves builtin selections only for available names", async () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-host-mcp-select-"));
    try {
      const { SettingsManager } = await import("@earendil-works/pi-coding-agent");
      const settings = SettingsManager.inMemory({}, { projectTrusted: false });
      await expect(
        resolveSelectedAgentExtensionPaths(["builtin:mcp"], dir, dir, settings, ["mcp"]),
      ).resolves.toEqual(["builtin:mcp"]);
      // Sandbox and mirror runtimes pass no names; unknown names are never accepted.
      await expect(
        resolveSelectedAgentExtensionPaths(["builtin:mcp"], dir, dir, settings, []),
      ).rejects.toMatchObject({ code: "agent_extensions_unavailable" });
      await expect(
        resolveSelectedAgentExtensionPaths(["builtin:nope"], dir, dir, settings, ["mcp"]),
      ).rejects.toMatchObject({ code: "agent_extensions_unavailable" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
