/**
 * Pi's MCP servers for host server-durable sessions.
 *
 * Pi's built-in MCP extension is classic Pi code (`pi.registerTool`, exposure modes), which
 * a pi-durable registry cannot load. This module keeps Pi's config, connections, credentials,
 * naming, and result conversion, and only replaces the glue:
 *
 * - One pi-durable extension per session, `oppi.mcp/<sessionId>`, rebuilt and reinstalled in
 *   place whenever a server's tool list changes. Conversations store extension and tool
 *   names, so a reinstall reaches the next request while running calls finish on old code.
 * - Exposure as in Pi (default `codemode`). Every tool but a `hidden` one is appended to the
 *   conversation's explicit tool list, so codemode scripts can call it. `direct` tools are
 *   offered to the model; `codemode` and `deferred` ones are pi-durable `deferred` tools, not
 *   offered until `tool_search` returns them in `control.addTools`, which pi-durable commits
 *   with the round. As Pi does, a `codemode` server turns codemode on (unless `mcp.json` sets
 *   `autoEnableCodemode: false`) and a `deferred` one turns `tool_search` on.
 * - Each connected server is a codemode namespace (`describeNamespace()`), reported through
 *   `options.namespaces` to the one codemode extension of every durable session. A namespace
 *   carries only the owner's configured `description`, never the server's own instructions
 *   (the session's `mcp_servers` section has those): the extension is shared, and a sandbox
 *   server's instructions are guest-written text.
 * - A tool reruns after a crash only when the server marks it read-only or idempotent.
 * - Sign-in stays in Oppi's MCP settings. Problems are reported once after startup, and a
 *   server whose stored credentials changed since it needed sign-in reconnects before the
 *   next prompt.
 * - In a sandbox workspace, `sandbox` (from `sandboxMcpForWorkspace`) replaces config
 *   loading, transports, and the log, so the classic sandbox boundary applies unchanged.
 */
import { join } from "node:path";
import type { Context, JsonValue } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { McpExposure, McpServerEntry, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { num, obj, opt, str } from "@earendil-works/pi-schema";
import {
  AgentDoc,
  section,
  type Conversation,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { createLogger } from "./logger.js";
import { recordMcpConnect } from "./mcp-connect-metrics.js";
import type { ServerTelemetry } from "./telemetry/server-telemetry.js";
import {
  loadPiMcpInternals,
  type McpOAuthCredentialStore,
  type McpServerConnection,
  type McpTool,
  type PiMcpInternals,
  type ToolSearchDocument,
} from "./pi-mcp-internals.js";
import { CODEMODE_TOOL_NAME, type CodemodeNamespace } from "@earendil-works/pi-durable/codemode";
import type { SandboxMcpOptions } from "./sandbox-mcp.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "durable_mcp" } });

/** How long the first prompt waits for servers with direct tools, like Pi's MCP extension. */
export const DURABLE_MCP_STARTUP_WAIT_MS = 10_000;
export const DURABLE_TOOL_SEARCH_NAME = "tool_search";
/** Per-session MCP extension names start with this; a child conversation must not keep its parent's. */
export const DURABLE_MCP_EXTENSION_PREFIX = "oppi.mcp/";

type ToolPolicy = NonNullable<NonNullable<Session["launch"]>["tools"]>;

interface Server {
  entry: McpServerEntry;
  connection?: McpServerConnection;
  /** Settles when the first connection attempt connected or failed. */
  ready?: Promise<void>;
}

interface Registered {
  tool: ToolRegistration;
  exposure: McpExposure;
  document: ToolSearchDocument;
}

export interface DurableMcpOptions {
  sessionId: string;
  /**
   * The MCP root every server sees (`roots/list`), and the base the host project
   * `.pi/mcp.json` resolves from. Sandbox callers MUST pass the guest path, never the
   * host mount: a sandbox loads no project file, and its servers must not learn host paths.
   */
  cwd: string;
  agentDir: string;
  /** Host sessions only; a sandbox never loads the project's `mcp.json`. */
  projectTrusted: boolean;
  /** A sandbox workspace's servers, transports, and log; host Pi defaults when absent. */
  sandbox?: SandboxMcpOptions;
  policy: ToolPolicy | undefined;
  /** The Pi Tools setting's tools (`piDefaultTools`), which can turn `tool_search` on. */
  piTools: ReadonlySet<string>;
  providerToken: (provider: string) => Promise<string | undefined>;
  install: (extension: Extension) => void;
  uninstall: (extension: Extension) => void;
  /** This session's connected servers as codemode namespaces; undefined once it closes. */
  namespaces: (namespaces: readonly CodemodeNamespace[] | undefined) => void;
  metrics?: ServerTelemetry;
}

function exposureOf(entry: McpServerEntry): McpExposure {
  return entry.config.exposure ?? "codemode";
}

/** Exposures the server's tools can have, known from its config before it connects. */
function configuredExposures(entry: McpServerEntry): Set<McpExposure> {
  return new Set([exposureOf(entry), ...Object.values(entry.config.toolExposure ?? {})]);
}

function replayOf(definition: ToolDefinition): "safe" | "unsafe" {
  const hints = definition.annotations;
  return hints?.readOnlyHint === true || hints?.idempotentHint === true ? "safe" : "unsafe";
}

function firstLine(text: string): string {
  return text.split("\n", 1)[0] ?? "";
}

/**
 * A classic Pi tool definition as a pi-durable tool. MCP definitions use only signal and
 * onUpdate. Only a `direct` tool is offered to the model before `tool_search` loads it.
 */
function durableTool(definition: ToolDefinition, exposure: McpExposure): ToolRegistration {
  return {
    name: definition.name,
    description: definition.description,
    // MCP input schemas are JSON Schema; pi-durable validates them with pi-schema, through pi-ai.
    parameters: definition.parameters,
    replay: replayOf(definition),
    ...(exposure === "direct" ? {} : { deferred: true }),
    async execute(args, api, context) {
      const result = await definition.execute(
        api.callId,
        args,
        context.abortSignal,
        (partial) => {
          const text = partial.content
            .flatMap((block) => (block.type === "text" ? [block.text] : []))
            .join("");
          if (text) api.output(`${text}\n`);
        },
        // Pi's MCP tool and resource definitions never read the extension context.
        undefined as never,
      );
      const isError = (result as { isError?: boolean }).isError === true;
      return {
        output: result.content,
        details: JSON.parse(JSON.stringify(result.details ?? null)) as JsonValue,
        ...(isError ? { isError } : {}),
      };
    },
  };
}

type ToolSearchArgs = { query: string; limit?: number };

/** What a published extension may use of its session while the session is open. */
interface LiveMcp {
  connectionOf(server: string): McpServerConnection | undefined;
  resourceConnections(): McpServerConnection[];
  renderServersSection(): string | undefined;
  searchTools(
    args: ToolSearchArgs,
    api: Parameters<ToolRegistration["execute"]>[1],
    context: Context,
  ): ReturnType<ToolRegistration["execute"]>;
}

/**
 * The only way the published extensions reach their session: their tools and section read it at
 * each call, and `DurableMcp.close()` empties it. Registry snapshots outlive an uninstall (a
 * running task invocation keeps the snapshot it was reserved with), so an extension that held the session
 * or a connection kept the whole stopped session alive; one that holds this cell keeps only its
 * tool definitions, and a call on it after close fails like a shut-down server.
 *
 * The closures an extension holds are made by the functions below, never in a `DurableMcp`
 * method: V8 gives all closures of one function call a shared context, so a closure made next to
 * one that uses `this` holds `this` as well.
 */
interface LiveCell {
  mcp?: LiveMcp;
}

function liveToolClient(
  live: LiveCell,
  server: string,
): { getClient: () => Promise<McpServerConnection>; readableResources: () => boolean } {
  return {
    getClient: async () => {
      const connection = live.mcp?.connectionOf(server);
      if (!connection) throw new Error(`MCP server "${server}" is shut down`);
      return connection;
    },
    readableResources: () =>
      live.mcp?.resourceConnections().some((connection) => connection.name === server) ?? false,
  };
}

function liveResourceServers(live: LiveCell): () => McpServerConnection[] {
  return () => live.mcp?.resourceConnections() ?? [];
}

function liveServersSection(live: LiveCell): ReturnType<typeof section> {
  return section("mcp_servers", () => live.mcp?.renderServersSection());
}

function liveToolSearch(live: LiveCell, internals: PiMcpInternals): ToolRegistration {
  const parameters = obj({
    query: str({ description: "Search query for deferred tools." }),
    limit: opt(
      num({
        description: `Maximum number of tools to return. Defaults to ${internals.DEFAULT_TOOL_SEARCH_LIMIT}.`,
      }),
    ),
  });
  return {
    name: DURABLE_TOOL_SEARCH_NAME,
    description: internals.TOOL_SEARCH_DESCRIPTION,
    parameters,
    // Loading the same tools again is harmless.
    replay: "safe",
    execute: (args, api, context: Context) => {
      const mcp = live.mcp;
      if (!mcp) throw new Error("MCP tool search is shut down with its session");
      return mcp.searchTools(args as ToolSearchArgs, api, context);
    },
  };
}

export class DurableMcp {
  readonly extensionName: string;
  private readonly live: LiveCell = {};
  private readonly servers: Server[];
  private readonly configErrors: string[];
  /** Tool names the conversation offers once it attaches: codemode and tool search as needed. */
  private readonly discoveryTools: string[];
  /** Connected servers by name, as codemode namespaces. */
  private readonly namespaces = new Map<string, CodemodeNamespace>();
  private conversation?: Conversation;
  private startup?: Promise<void>;
  private waitedForStartup = false;
  private offers: Promise<void> = Promise.resolve();
  private offerError?: Error;
  private closed = false;
  private extension: Extension;
  /** Pi tool name to the `<server>\0<tool>` it was assigned to, so names stay unique and stable. */
  private readonly toolOwners = new Map<string, string>();
  private readonly serverTools = new Map<string, Map<string, Registered>>();
  private resourceTools: Registered[] = [];
  /** Stored tokens of servers waiting for a sign-in, as they were when the sign-in was needed. */
  private readonly tokensAtSignIn = new Map<McpServerConnection, string>();
  private readonly credentials: McpOAuthCredentialStore;
  private readonly serverLog: object;
  private readonly toolSearch: ToolRegistration | undefined;
  private readonly excluded: ((name: string) => boolean) | undefined;
  private readonly allowed: ((name: string) => boolean) | undefined;
  /** An allow list that is empty or names `mcp__` entries filters MCP tools like any other. */
  private readonly allowlistFiltersMcp: boolean;

  /** Undefined when no server is enabled, no config error needs reporting, or the policy allows no tools. */
  static async open(options: DurableMcpOptions): Promise<DurableMcp | undefined> {
    // An allow list overrides `noTools` (`toolAllowed`); `builtin` never covers MCP tools.
    if (options.policy?.noTools === "all" && !options.policy.allowed) return undefined;
    const internals = await loadPiMcpInternals();
    const loaded = options.sandbox
      ? // The sandbox loader reads only `ctx.cwd` of Pi's extension context.
        options.sandbox.loadConfig({ cwd: options.cwd } as never)
      : internals.loadMcpConfig({
          agentDir: options.agentDir,
          cwd: options.cwd,
          projectTrusted: options.projectTrusted,
        });
    const entries = loaded.servers.filter((entry) => entry.config.enabled !== false);
    if (!entries.length && !loaded.errors.length) return undefined;
    const mcp = new DurableMcp(
      internals,
      options,
      entries,
      loaded.errors,
      loaded.autoEnableCodemode !== false,
    );
    mcp.publish();
    return mcp;
  }

  private constructor(
    private readonly internals: PiMcpInternals,
    private readonly options: DurableMcpOptions,
    entries: McpServerEntry[],
    configErrors: string[],
    autoEnableCodemode: boolean,
  ) {
    this.extensionName = `${DURABLE_MCP_EXTENSION_PREFIX}${options.sessionId}`;
    this.live.mcp = {
      connectionOf: (server) => this.connectionOf(server),
      resourceConnections: () => this.resourceConnections(),
      renderServersSection: () => this.renderServersSection(),
      searchTools: (args, api, context) => this.searchTools(args, api, context),
    };
    this.servers = entries.map((entry) => ({ entry }));
    this.configErrors = configErrors;
    this.credentials = new internals.McpOAuthCredentialStore();
    this.serverLog = new internals.McpServerLog(
      options.sandbox?.logPath ?? join(options.agentDir, "mcp.log"),
    );
    const { allowed, excluded } = options.policy ?? {};
    this.excluded = excluded ? internals.createToolNameMatcher(excluded) : undefined;
    this.allowed = allowed ? internals.createToolNameMatcher(allowed) : undefined;
    this.allowlistFiltersMcp =
      allowed !== undefined &&
      (allowed.length === 0 || allowed.some((entry) => entry.startsWith("mcp__")));
    const exposures = new Set(
      this.servers.flatMap((server) => [...configuredExposures(server.entry)]),
    );
    // Tool search reaches every tool the model is not offered: `codemode` and `deferred` ones.
    this.toolSearch =
      (exposures.has("deferred") || exposures.has("codemode")) &&
      this.permitted(DURABLE_TOOL_SEARCH_NAME, "direct")
        ? liveToolSearch(this.live, internals)
        : undefined;
    // Pi's `ensureDiscoveryActive`: the tool the servers' exposure asks for is on, as is one the
    // Pi Tools setting (or an allow list) enables.
    const enabled = (name: string): boolean =>
      this.allowed ? this.allowed(name) : options.piTools.has(name);
    this.discoveryTools = [
      ...(exposures.has("codemode") &&
      autoEnableCodemode &&
      this.permitted(CODEMODE_TOOL_NAME, "direct")
        ? [CODEMODE_TOOL_NAME]
        : []),
      ...(this.toolSearch && (exposures.has("deferred") || enabled(DURABLE_TOOL_SEARCH_NAME))
        ? [DURABLE_TOOL_SEARCH_NAME]
        : []),
    ];
    this.extension = this.buildExtension();
    if (configErrors.length > 0) {
      recordMcpConnect(options.metrics, {
        sessionId: options.sessionId,
        startedAt: Date.now(),
        configError: true,
      });
    }
  }

  /** The extension to select on the conversation; the same name across reinstalls. */
  get selection(): Extension {
    return this.extension;
  }

  /**
   * Start connecting. Codemode and tool search are offered as the servers' exposure asks, and
   * each server's tools are appended to the conversation's tool list as it connects.
   */
  attach(conversation: Conversation): void {
    if (this.conversation) throw new Error("Durable MCP is already attached");
    this.conversation = conversation;
    this.offerTools(this.discoveryTools);
    const readies = this.servers.map((server) => {
      const connection = new this.internals.McpServerConnection({
        entry: server.entry,
        cwd: this.options.cwd,
        createTransport:
          this.options.sandbox?.createTransport ?? this.internals.createDefaultTransport,
        credentials: this.credentials,
        providerToken: this.options.providerToken,
        log: this.serverLog,
        onTools: (changed) => this.registerTools(changed),
        onChange: (changed) => this.onConnectionChange(changed),
      });
      server.connection = connection;
      const startedAt = Date.now();
      server.ready = connection.getClient().then(
        () => {
          recordMcpConnect(this.options.metrics, {
            sessionId: this.options.sessionId,
            startedAt,
            state: "connected",
          });
        },
        () => {
          recordMcpConnect(this.options.metrics, {
            sessionId: this.options.sessionId,
            startedAt,
            state: connection.state,
          });
        },
      );
      return server.ready;
    });
    this.startup = Promise.all(readies).then(() => undefined);
  }

  /** Wait (bounded) until every server's first connection attempt settled, for crash recovery. */
  async waitForStartup(timeoutMs = DURABLE_MCP_STARTUP_WAIT_MS): Promise<void> {
    await this.waitFor(this.servers, timeoutMs);
  }

  /**
   * Startup problems for one report: config errors, servers needing sign-in, and failures.
   * Resolves after every first connection attempt settled.
   */
  async startupProblems(): Promise<string | undefined> {
    await this.startup;
    const lines = this.configErrors.map((error) => `config: ${error}`);
    for (const server of this.servers) {
      const connection = server.connection;
      if (connection?.state === "needs-auth") lines.push(`${server.entry.name}: needs sign-in`);
      else if (connection?.state === "failed")
        lines.push(
          `${server.entry.name}: failed: ${firstLine(connection.error ?? "unknown error")}`,
        );
    }
    if (!lines.length || this.closed) return undefined;
    return `MCP servers need attention:\n${lines.map((line) => `  ${line}`).join("\n")}\nSign in or fix them in Oppi's MCP settings.`;
  }

  /**
   * Before a prompt: surface a failed tool-list commit, reconnect servers whose credentials
   * were stored since they needed a sign-in, and on the first prompt wait (bounded) for the
   * servers whose tools the request offers. Direct servers always; every server when the
   * conversation already loaded MCP or resource tools (with `tool_search` before a restart).
   * A name cannot be mapped back to its server: Pi shortens long names with a hash, and
   * resource tools reach every server with resources.
   */
  async beforePrompt(): Promise<void> {
    await this.reconnectSignedIn();
    await this.waitForPromptTools();
    // Connections that settled during the waits chained their tool-list commits; land them
    // before admission so this request offers the tools.
    await this.offers;
    if (this.offerError) throw this.offerError;
  }

  private async waitForPromptTools(): Promise<void> {
    const conversation = this.conversation;
    if (this.waitedForStartup || !conversation) return;
    this.waitedForStartup = true;
    // Codemode and tool search, as `attach` offered them.
    await this.offers;
    // Loaded deferred tools are in `modelTools` (`control.addTools`), direct ones are not.
    const loaded = await conversation.commit(async (tx) => {
      const modelTools = (await tx.doc(AgentDoc, conversation.id)).modelTools;
      return Array.isArray(modelTools) ? [...modelTools] : [...(modelTools?.add ?? [])];
    }, BACKGROUND_CONTEXT);
    // Offered, not only named: an exact Agent selection may leave the extension out.
    const codemode = (await conversation.agent(BACKGROUND_CONTEXT)).tools.some(
      (tool) => tool.name === CODEMODE_TOOL_NAME,
    );
    const resourceTools = new Set(this.internals.MCP_RESOURCE_TOOL_NAMES);
    const loadedBefore = loaded.some((name) => name.startsWith("mcp__") || resourceTools.has(name));
    // A codemode script runs on the tools its call started with: a server that connects during
    // the call is too late for it. So with codemode, the first prompt waits for every server.
    await this.waitFor(
      loadedBefore || codemode
        ? this.servers
        : this.servers.filter((server) => configuredExposures(server.entry).has("direct")),
      DURABLE_MCP_STARTUP_WAIT_MS,
    );
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.live.mcp = undefined;
    this.options.namespaces(undefined);
    this.options.uninstall(this.extension);
    await Promise.allSettled(this.servers.map((server) => server.connection?.close()));
  }

  /**
   * Pi's tool policy (`AgentSession._isAllowedTool` and `_isActivatable`): exclusions and the
   * allow list match exact names or `*` patterns, and an allow list that names no `mcp__` entry
   * keeps the MCP tools codemode and tool search reach (not `direct` ones).
   */
  private permitted(name: string, exposure: McpExposure): boolean {
    if (this.excluded?.(name)) return false;
    if (!this.allowed || this.allowed(name)) return true;
    if (this.allowlistFiltersMcp || !this.internals.isMcpToolName(name)) return false;
    return exposure !== "direct";
  }

  private async waitFor(
    servers: readonly Server[],
    timeoutMs: number,
    signal?: AbortSignal,
  ): Promise<void> {
    const ready = servers.flatMap((server) => (server.ready ? [server.ready] : []));
    if (!ready.length || signal?.aborted) return;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let onAbort: (() => void) | undefined;
    await Promise.race([
      Promise.all(ready),
      new Promise<void>((resolve) => {
        if (Number.isFinite(timeoutMs)) timer = setTimeout(resolve, timeoutMs);
        onAbort = resolve;
        signal?.addEventListener("abort", onAbort, { once: true });
      }),
    ]);
    clearTimeout(timer);
    if (onAbort) signal?.removeEventListener("abort", onAbort);
  }

  private storedTokens(connection: McpServerConnection): string {
    const url = connection.oauthUrl;
    return url ? JSON.stringify(this.credentials.tokens(connection.name, url) ?? null) : "null";
  }

  private onConnectionChange(connection: McpServerConnection): void {
    if (connection.state !== "needs-auth") this.tokensAtSignIn.delete(connection);
    else if (!this.tokensAtSignIn.has(connection))
      this.tokensAtSignIn.set(connection, this.storedTokens(connection));
    // The `mcp_servers` section renders server instructions once a server connects.
    this.publish();
  }

  private async reconnectSignedIn(): Promise<void> {
    const signedIn = [...this.tokensAtSignIn].filter(
      ([connection, tokens]) => this.storedTokens(connection) !== tokens,
    );
    for (const [connection] of signedIn) this.tokensAtSignIn.delete(connection);
    await Promise.allSettled(signedIn.map(([connection]) => connection.reconnect()));
  }

  private registerTools(connection: McpServerConnection): void {
    if (this.closed) return;
    const server = connection.entry.name;
    const entry = this.servers.find((candidate) => candidate.entry.name === server)?.entry;
    if (!entry) return;
    const description = entry.config.description?.trim();
    const namespace = {
      name: this.internals.mcpNamespace(server),
      ...(description ? { description } : {}),
      ...(connection.instructions ? { instructions: connection.instructions } : {}),
    };
    // Tool names are `mcp__<server>__<tool>` with the server name sanitized like the namespace.
    this.namespaces.set(server, {
      name: namespace.name,
      ...(description ? { description } : {}),
      prefix: `${namespace.name}__`,
    });
    this.options.namespaces([...this.namespaces.values()]);
    const current = new Map<string, Registered>();
    // Like Pi: every tool whose name sanitizes to the same name gets the hash suffix, so which
    // one keeps the plain name does not depend on the order of the list.
    const plain = [...new Set(connection.tools.map((tool) => tool.name))].map((tool) =>
      this.internals.createMcpToolName(server, tool),
    );
    const assignName = (tool: McpTool): string => {
      const owner = `${server}\0${tool.name}`;
      const name = this.internals.createMcpToolName(server, tool.name, (candidate) => {
        const existing = this.toolOwners.get(candidate);
        return (
          (existing !== undefined && existing !== owner) ||
          current.has(candidate) ||
          plain.indexOf(candidate) !== plain.lastIndexOf(candidate)
        );
      });
      this.toolOwners.set(name, owner);
      return name;
    };
    for (const tool of connection.tools) {
      const name = assignName(tool);
      const exposure = this.internals.getMcpToolExposure(entry.config, tool.name);
      if (exposure === "hidden") continue;
      const definition = this.internals.createMcpToolDefinition({
        server,
        tool,
        name,
        exposure,
        namespace,
        timeoutMs: connection.timeoutMs,
        ...liveToolClient(this.live, server),
      });
      current.set(name, {
        tool: durableTool(definition, exposure),
        exposure,
        document: this.internals.createToolSearchDocument(definition, namespace),
      });
    }
    this.serverTools.set(server, current);
    this.syncResourceTools();
    this.publish();
    this.offerTools(this.enabledToolNames());
  }

  private connectionOf(server: string): McpServerConnection | undefined {
    return this.servers.find((candidate) => candidate.entry.name === server)?.connection;
  }

  /** Connected servers with resources whose exposure is not `hidden`, which the resource tools reach. */
  private resourceConnections(): McpServerConnection[] {
    return this.servers.flatMap((server) =>
      server.connection?.hasResources && exposureOf(server.entry) !== "hidden"
        ? [server.connection]
        : [],
    );
  }

  /** Resource tools take the widest exposure of the servers they reach; none without resources. */
  private syncResourceTools(): void {
    const exposures = new Set(
      this.servers
        .filter((server) => server.connection?.hasResources)
        .map((server) => exposureOf(server.entry)),
    );
    const exposure = (["direct", "codemode", "deferred"] as const).find((candidate) =>
      exposures.has(candidate),
    );
    if (!exposure) {
      this.resourceTools = [];
      return;
    }
    if (this.resourceTools[0]?.exposure === exposure) return;
    this.resourceTools = this.internals
      .createMcpResourceToolDefinitions({ exposure, servers: liveResourceServers(this.live) })
      .map((definition) => ({
        tool: durableTool(definition, exposure),
        exposure,
        document: this.internals.createToolSearchDocument(definition),
      }));
  }

  /** The server that offers `toolName`; undefined for tool search and the resource tools. */
  serverOf(toolName: string): string | undefined {
    for (const [server, tools] of this.serverTools) if (tools.has(toolName)) return server;
    return undefined;
  }

  private registered(): Registered[] {
    return [
      ...[...this.serverTools.values()].flatMap((tools) => [...tools.values()]),
      ...this.resourceTools,
    ];
  }

  /** Every tool the policy permits: offered when `direct`, else callable by scripts and loadable. */
  private enabledToolNames(): string[] {
    return this.registered()
      .filter((item) => this.permitted(item.tool.name, item.exposure))
      .map((item) => item.tool.name);
  }

  private buildExtension(): Extension {
    return {
      name: this.extensionName,
      tools: [
        ...this.registered().map((item) => item.tool),
        ...(this.toolSearch ? [this.toolSearch] : []),
      ],
      sections: [liveServersSection(this.live)],
    };
  }

  private renderServersSection(): string | undefined {
    return this.internals.renderServersSection(
      this.servers.map((server) => ({
        entry: server.entry,
        ...(server.connection ? { connection: server.connection } : {}),
      })),
    );
  }

  private publish(): void {
    if (this.closed) return;
    this.extension = this.buildExtension();
    this.options.install(this.extension);
  }

  /**
   * Append names to the conversation's explicit tool list; from the next request on. Runs
   * from connection callbacks, so a failure is kept and fails the next prompt instead of
   * letting it run without the tools.
   */
  private offerTools(names: readonly string[]): void {
    const conversation = this.conversation;
    if (!conversation || !names.length || this.closed) return;
    this.offers = this.offers.then(async () => {
      if (this.closed) return;
      try {
        await conversation.commit(async (tx) => {
          const agent = await tx.doc(AgentDoc, conversation.id);
          if (!Array.isArray(agent.tools)) return;
          for (const name of names) if (!agent.tools.includes(name)) agent.tools.push(name);
        }, BACKGROUND_CONTEXT);
      } catch (error) {
        if (this.closed) return;
        this.offerError = new Error(
          `Could not offer MCP tools to this session: ${error instanceof Error ? error.message : String(error)}`,
        );
        log.error("durable_mcp.offer_tools_failed", {
          sessionId: this.options.sessionId,
          error: this.offerError.message,
        });
      }
    });
  }

  private async searchTools(
    { query, limit }: ToolSearchArgs,
    api: Parameters<ToolRegistration["execute"]>[1],
    context: Context,
  ): ReturnType<ToolRegistration["execute"]> {
    if (query.trim() === "") throw new Error("query must not be empty");
    const max = limit ?? this.internals.DEFAULT_TOOL_SEARCH_LIMIT;
    if (!Number.isInteger(max) || max <= 0) throw new Error("limit must be a positive integer");
    await this.reconnectSignedIn();
    await this.waitFor(
      this.servers.filter((server) =>
        [...configuredExposures(server.entry)].some(
          (exposure) => exposure === "deferred" || exposure === "codemode",
        ),
      ),
      Number.POSITIVE_INFINITY,
      context.abortSignal,
    );
    const offered = new Set((await api.agent(context)).tools.map((tool) => tool.name));
    const candidates = this.registered().filter(
      (item) =>
        item.exposure !== "direct" &&
        !offered.has(item.tool.name) &&
        this.permitted(item.tool.name, item.exposure),
    );
    const matches = new this.internals.Bm25Ranker().rank(
      query,
      candidates.map((item) => item.document),
      max,
    );
    const loaded = matches.flatMap((match) => {
      const item = candidates.find((candidate) => candidate.tool.name === match.name);
      return item ? [item.tool] : [];
    });
    const text =
      loaded.length === 0
        ? "No matching tools found."
        : `Loaded ${loaded.length} tool${loaded.length === 1 ? "" : "s"}. They are available from your next call:\n${loaded
            .map((tool) => `- ${tool.name}: ${firstLine(tool.description.trim())}`)
            .join("\n")}`;
    return {
      output: [{ type: "text", text }],
      details: { loaded: loaded.map((tool) => tool.name) },
      ...(loaded.length ? { control: { addTools: loaded.map((tool) => tool.name) } } : {}),
    };
  }
}
