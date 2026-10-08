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
 * - `direct` tools are appended to the conversation's explicit tool list. `deferred` tools
 *   (and `codemode` ones: durable has no codemode, see `withoutCodemode`) stay unoffered until
 *   `tool_search` returns them in `control.addTools`, which pi-durable commits with the round.
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
import { Type } from "typebox";
import {
  AgentDoc,
  section,
  type Conversation,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { createLogger } from "./logger.js";
import {
  loadPiMcpInternals,
  type McpOAuthCredentialStore,
  type McpServerConnection,
  type McpTool,
  type PiMcpInternals,
  type ToolSearchDocument,
} from "./pi-mcp-internals.js";
import { withoutCodemode, type SandboxMcpOptions } from "./sandbox-mcp.js";
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
  /** Host cwd: Pi's connections and the project `.pi/mcp.json` resolve from it. */
  cwd: string;
  agentDir: string;
  /** Host sessions only; a sandbox never loads the project's `mcp.json`. */
  projectTrusted: boolean;
  /** A sandbox workspace's servers, transports, and log; host Pi defaults when absent. */
  sandbox?: SandboxMcpOptions;
  policy: ToolPolicy | undefined;
  providerToken: (provider: string) => Promise<string | undefined>;
  install: (extension: Extension) => void;
  uninstall: (extension: Extension) => void;
}

function exposureOf(entry: McpServerEntry): McpExposure {
  return entry.config.exposure ?? "deferred";
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

/** A classic Pi tool definition as a pi-durable tool. MCP definitions use only signal and onUpdate. */
function durableTool(definition: ToolDefinition): ToolRegistration {
  return {
    name: definition.name,
    description: definition.description,
    // MCP input schemas are JSON Schema; pi-durable validates them with TypeBox, which accepts it.
    parameters: definition.parameters,
    replay: replayOf(definition),
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
        content: result.content,
        details: JSON.parse(JSON.stringify(result.details ?? null)) as JsonValue,
        ...(isError ? { isError } : {}),
      };
    },
  };
}

export class DurableMcp {
  readonly extensionName: string;
  private readonly servers: Server[];
  private readonly configErrors: string[];
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

  /** Undefined when no server is enabled, no config error needs reporting, or the policy allows no tools. */
  static async open(options: DurableMcpOptions): Promise<DurableMcp | undefined> {
    if (options.policy?.noTools === "all") return undefined;
    const internals = await loadPiMcpInternals();
    const loaded = options.sandbox
      ? // The sandbox loader reads only `ctx.cwd` of Pi's extension context.
        options.sandbox.loadConfig({ cwd: options.cwd } as never)
      : internals.loadMcpConfig({
          agentDir: options.agentDir,
          cwd: options.cwd,
          projectTrusted: options.projectTrusted,
        });
    const entries = loaded.servers
      .filter((entry) => entry.config.enabled !== false)
      .map(withoutCodemode);
    if (!entries.length && !loaded.errors.length) return undefined;
    const mcp = new DurableMcp(internals, options, entries, loaded.errors);
    mcp.publish();
    return mcp;
  }

  private constructor(
    private readonly internals: PiMcpInternals,
    private readonly options: DurableMcpOptions,
    entries: McpServerEntry[],
    configErrors: string[],
  ) {
    this.extensionName = `${DURABLE_MCP_EXTENSION_PREFIX}${options.sessionId}`;
    this.servers = entries.map((entry) => ({ entry }));
    this.configErrors = configErrors;
    this.credentials = new internals.McpOAuthCredentialStore();
    this.serverLog = new internals.McpServerLog(
      options.sandbox?.logPath ?? join(options.agentDir, "mcp.log"),
    );
    this.toolSearch =
      this.servers.some((server) => configuredExposures(server.entry).has("deferred")) &&
      this.permitted(DURABLE_TOOL_SEARCH_NAME)
        ? this.createToolSearch()
        : undefined;
    this.extension = this.buildExtension();
  }

  /** The extension to select on the conversation; the same name across reinstalls. */
  get selection(): Extension {
    return this.extension;
  }

  /** Tools a conversation offers before any server connects. */
  get initialTools(): ToolRegistration[] {
    return this.toolSearch ? [this.toolSearch] : [];
  }

  /** Start connecting. Direct tools are appended to the conversation's tool list as servers connect. */
  attach(conversation: Conversation): void {
    if (this.conversation) throw new Error("Durable MCP is already attached");
    this.conversation = conversation;
    this.offerTools(this.initialTools.map((tool) => tool.name));
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
      server.ready = connection.getClient().then(
        () => undefined,
        () => undefined,
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
   * conversation already offers MCP or resource tools (loaded by `tool_search` before a
   * restart). A name cannot be mapped back to its server: Pi shortens long names with a hash,
   * and resource tools reach every server with resources.
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
    const offered = await conversation.commit(async (tx) => {
      const tools = (await tx.doc(AgentDoc, conversation.id)).tools;
      return Array.isArray(tools) ? [...tools] : [];
    }, BACKGROUND_CONTEXT);
    const resourceTools = new Set(this.internals.MCP_RESOURCE_TOOL_NAMES);
    const loadedBefore = offered.some(
      (name) => name.startsWith("mcp__") || resourceTools.has(name),
    );
    await this.waitFor(
      loadedBefore
        ? this.servers
        : this.servers.filter((server) => configuredExposures(server.entry).has("direct")),
      DURABLE_MCP_STARTUP_WAIT_MS,
    );
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.options.uninstall(this.extension);
    await Promise.allSettled(this.servers.map((server) => server.connection?.close()));
  }

  private permitted(name: string): boolean {
    const policy = this.options.policy;
    return (!policy?.allowed || policy.allowed.includes(name)) && !policy?.excluded?.includes(name);
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
        getClient: async () => connection,
        readableResources: () => this.resourceConnections().includes(connection),
      });
      current.set(name, {
        tool: durableTool(definition),
        exposure,
        document: this.internals.createToolSearchDocument(definition, namespace),
      });
    }
    this.serverTools.set(server, current);
    this.syncResourceTools();
    this.publish();
    this.offerTools(this.directToolNames());
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
    const exposure = (["direct", "deferred"] as const).find((candidate) =>
      exposures.has(candidate),
    );
    if (!exposure) {
      this.resourceTools = [];
      return;
    }
    if (this.resourceTools[0]?.exposure === exposure) return;
    this.resourceTools = this.internals
      .createMcpResourceToolDefinitions({ exposure, servers: () => this.resourceConnections() })
      .map((definition) => ({
        tool: durableTool(definition),
        exposure,
        document: this.internals.createToolSearchDocument(definition),
      }));
  }

  private registered(): Registered[] {
    return [
      ...[...this.serverTools.values()].flatMap((tools) => [...tools.values()]),
      ...this.resourceTools,
    ];
  }

  private directToolNames(): string[] {
    return this.registered()
      .filter((item) => item.exposure === "direct" && this.permitted(item.tool.name))
      .map((item) => item.tool.name);
  }

  private buildExtension(): Extension {
    const listings = this.servers.map((server) => ({
      entry: server.entry,
      ...(server.connection ? { connection: server.connection } : {}),
    }));
    return {
      name: this.extensionName,
      tools: [
        ...this.registered().map((item) => item.tool),
        ...(this.toolSearch ? [this.toolSearch] : []),
      ],
      sections: [section("mcp_servers", () => this.internals.renderServersSection(listings))],
    };
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

  private createToolSearch(): ToolRegistration {
    const parameters = Type.Object({
      query: Type.String({ description: "Search query for deferred tools." }),
      limit: Type.Optional(
        Type.Number({
          description: `Maximum number of tools to return. Defaults to ${this.internals.DEFAULT_TOOL_SEARCH_LIMIT}.`,
        }),
      ),
    });
    return {
      name: DURABLE_TOOL_SEARCH_NAME,
      description: this.internals.TOOL_SEARCH_DESCRIPTION,
      parameters,
      // Loading the same tools again is harmless.
      replay: "safe",
      execute: async (args, api, context: Context) => {
        const { query, limit } = args as { query: string; limit?: number };
        if (query.trim() === "") throw new Error("query must not be empty");
        const max = limit ?? this.internals.DEFAULT_TOOL_SEARCH_LIMIT;
        if (!Number.isInteger(max) || max <= 0) throw new Error("limit must be a positive integer");
        await this.reconnectSignedIn();
        await this.waitFor(
          this.servers.filter((server) => configuredExposures(server.entry).has("deferred")),
          Number.POSITIVE_INFINITY,
          context.abortSignal,
        );
        const offered = new Set((await api.agent(context)).tools.map((tool) => tool.name));
        const candidates = this.registered().filter(
          (item) =>
            item.exposure === "deferred" &&
            !offered.has(item.tool.name) &&
            this.permitted(item.tool.name),
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
          content: [{ type: "text", text }],
          details: { loaded: loaded.map((tool) => tool.name) },
          ...(loaded.length ? { control: { addTools: loaded.map((tool) => tool.name) } } : {}),
        };
      },
    };
  }
}
