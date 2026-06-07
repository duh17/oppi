import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export interface OppiSubagentsBridgeDescriptor {
  version: 1;
  baseUrl: string;
  token?: string;
  originSessionId?: string;
  workspaceId?: string;
  runtime?: "sdk" | "pi-tui";
  canSpawn?: boolean;
  defaultWaitTimeoutMs?: number;
}

interface BridgeSessionSummary {
  id: string;
  name?: string;
  status: "starting" | "ready" | "busy" | "stopping" | "stopped" | "error";
  workspaceId?: string;
  parentSessionId?: string;
  createdAt: number;
  lastActivity: number;
  messageCount: number;
  tokens?: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  };
  cost?: number;
  model?: string;
  firstMessage?: string;
  lastMessage?: string;
  lastAgentReplyAt?: number;
}

interface SpawnResponse {
  session: BridgeSessionSummary;
}

interface SessionsResponse {
  sessions: BridgeSessionSummary[];
}

interface InspectResponse {
  text: string;
  details?: Record<string, unknown>;
}

interface ResolveResponse {
  descriptor: OppiSubagentsBridgeDescriptor;
}

interface BridgeRequestOptions {
  method?: "GET" | "POST";
  body?: unknown;
  signal?: AbortSignal;
}

interface OppiSubagentsExtensionOptions {
  descriptor?: OppiSubagentsBridgeDescriptor;
  descriptorPath?: string;
}

interface ActiveBridge {
  descriptor: OppiSubagentsBridgeDescriptor;
  ctx: ExtensionContext;
}

const POLL_INTERVAL_MS = 2_000;
const STARTUP_RESOLVE_RETRY_MS = 2_000;
const DEFAULT_WAIT_TIMEOUT_MS = 30 * 60_000;
const MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024;

const spawnAgentParams = Type.Object({
  message: Type.String({ description: "The task prompt for the child agent." }),
  name: Type.Optional(Type.String({ description: "Display name for the child session." })),
  profile: Type.Optional(
    Type.String({ description: "Built-in profile: default, discovery, coding, review, research." }),
  ),
  model: Type.Optional(Type.String({ description: "Model override for the child session." })),
  thinking: Type.Optional(
    Type.String({
      description: "Thinking level override: off, minimal, low, medium, high, xhigh.",
    }),
  ),
  detached: Type.Optional(Type.Boolean({ description: "Create an independent session." })),
  wait: Type.Optional(Type.Boolean({ description: "Wait for completion before returning." })),
  timeout_seconds: Type.Optional(Type.Number({ minimum: 1 })),
});

const inspectAgentParams = Type.Object({
  id: Type.String({ description: "Session ID of the child agent to inspect." }),
  turn: Type.Optional(Type.Number({ description: "Turn number to drill into (1-based)." })),
  tool: Type.Optional(Type.Number({ description: "Tool index within the turn (1-based)." })),
  response: Type.Optional(
    Type.Boolean({
      description:
        "If true, return the full assistant response. Defaults to true when no turn or tool is specified.",
    }),
  ),
});

const sendMessageParams = Type.Object({
  id: Type.String({ description: "Session ID of the target agent." }),
  message: Type.String({ description: "Message to send." }),
  behavior: Type.Optional(Type.Union([Type.Literal("steer"), Type.Literal("followUp")])),
});

const BUILT_IN_PROFILES: Record<string, { description?: string; guidelines?: string[] }> = {
  default: { description: "Default subagent profile. Use when no specialized focus is needed." },
  discovery: {
    description: "Fast codebase discovery for bounded questions and source inspection.",
    guidelines: [
      "Search and read before summarizing; do not edit files unless explicitly asked.",
      "Return concrete findings with file paths, uncertainty, and the next useful action.",
      "Stay scoped to the delegated question and avoid broad refactors.",
    ],
  },
  coding: {
    description: "Focused implementation in a clear ownership area.",
    guidelines: [
      "Edit only the files or modules assigned to you unless nearby support code must change.",
      "Do not revert unrelated work.",
      "Validate changes with the narrowest reliable check and report changed files.",
    ],
  },
  review: {
    description: "Correctness, regression, and risk review.",
    guidelines: [
      "Review evidence from diffs, tests, and relevant source before concluding.",
      "Prioritize correctness, data loss, security, concurrency, and protocol drift.",
      "Return findings with severity, confidence, file paths, and concrete fixes.",
    ],
  },
  research: {
    description: "Documentation, web/source discovery, and synthesis.",
    guidelines: [
      "Prefer primary sources and cite named sources for external claims.",
      "Separate confirmed facts from uncertainty and avoid broad summaries.",
      "Return concise recommendations tied to the parent task.",
    ],
  },
};

function expandHomePath(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}

function readJsonFile(path: string): Record<string, unknown> {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function oppiConfigPath(): string {
  if (process.env.OPPI_CONFIG_PATH) return process.env.OPPI_CONFIG_PATH;
  const dataDir = process.env.OPPI_DATA_DIR || join(homedir(), ".config", "oppi");
  return join(dataDir, "config.json");
}

function localHostForConfig(host: unknown): string {
  const value = typeof host === "string" ? host.trim() : "";
  if (!value || value === "0.0.0.0" || value === "::" || value === "[::]") return "127.0.0.1";
  return value;
}

function discoverDescriptorFromEnv(): OppiSubagentsBridgeDescriptor | undefined {
  const file = process.env.OPPI_SUBAGENTS_BRIDGE_FILE?.trim();
  if (file) {
    const parsed = readJsonFile(resolve(expandHomePath(file)));
    const descriptor = normalizeDescriptor(parsed);
    if (descriptor) return descriptor;
  }

  const baseUrl = process.env.OPPI_SUBAGENTS_BRIDGE_URL?.trim();
  if (!baseUrl) return undefined;
  return {
    version: 1,
    baseUrl,
    token: process.env.OPPI_SUBAGENTS_BRIDGE_TOKEN,
    originSessionId: process.env.OPPI_SUBAGENTS_SESSION_ID,
    workspaceId: process.env.OPPI_SUBAGENTS_WORKSPACE_ID,
    canSpawn: process.env.OPPI_SUBAGENTS_CAN_SPAWN !== "false",
  };
}

function discoverDescriptorFromConfig(): OppiSubagentsBridgeDescriptor | undefined {
  const config = readJsonFile(oppiConfigPath()) as {
    host?: unknown;
    port?: unknown;
    tls?: { mode?: unknown };
    token?: unknown;
  };
  const token = typeof config.token === "string" ? config.token.trim() : "";
  const port =
    typeof config.port === "number" || typeof config.port === "string" ? String(config.port) : "";
  if (!token || !port) return undefined;

  const scheme = config.tls?.mode === "disabled" ? "http" : "https";
  const host = localHostForConfig(config.host);
  return {
    version: 1,
    baseUrl: `${scheme}://${host}:${port}/subagents/bridge`,
    token,
    canSpawn: true,
  };
}

function normalizeDescriptor(value: unknown): OppiSubagentsBridgeDescriptor | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const obj = value as Record<string, unknown>;
  if (typeof obj.baseUrl !== "string" || obj.baseUrl.trim().length === 0) return undefined;
  return {
    version: 1,
    baseUrl: obj.baseUrl.trim(),
    token: typeof obj.token === "string" ? obj.token : undefined,
    originSessionId: typeof obj.originSessionId === "string" ? obj.originSessionId : undefined,
    workspaceId: typeof obj.workspaceId === "string" ? obj.workspaceId : undefined,
    runtime: obj.runtime === "sdk" || obj.runtime === "pi-tui" ? obj.runtime : undefined,
    canSpawn: typeof obj.canSpawn === "boolean" ? obj.canSpawn : undefined,
    defaultWaitTimeoutMs:
      typeof obj.defaultWaitTimeoutMs === "number" &&
      Number.isFinite(obj.defaultWaitTimeoutMs) &&
      obj.defaultWaitTimeoutMs >= 1
        ? obj.defaultWaitTimeoutMs
        : undefined,
  };
}

function isLocalUrl(url: URL): boolean {
  return ["localhost", "127.0.0.1", "::1", "[::1]"].includes(url.hostname);
}

function requestJson<T>(
  descriptor: OppiSubagentsBridgeDescriptor,
  path: string,
  options: BridgeRequestOptions = {},
): Promise<T> {
  const base = descriptor.baseUrl.replace(/\/+$/, "");
  const url = new URL(`${base}${path.startsWith("/") ? path : `/${path}`}`);
  const bodyText = options.body === undefined ? undefined : JSON.stringify(options.body);
  const requestImpl = url.protocol === "https:" ? httpsRequest : httpRequest;

  return new Promise<T>((resolvePromise, reject) => {
    const req = requestImpl(
      url,
      {
        method: options.method ?? (bodyText === undefined ? "GET" : "POST"),
        headers: {
          ...(descriptor.token ? { Authorization: `Bearer ${descriptor.token}` } : {}),
          ...(bodyText
            ? { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(bodyText) }
            : {}),
        },
        ...(url.protocol === "https:" ? { rejectUnauthorized: !isLocalUrl(url) } : {}),
      },
      (res) => {
        const chunks: Buffer[] = [];
        let total = 0;
        res.on("data", (chunk: Buffer) => {
          total += chunk.length;
          if (total > MAX_HTTP_RESPONSE_BYTES) {
            req.destroy(new Error("Oppi subagents bridge response exceeded size limit"));
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          if ((res.statusCode ?? 500) >= 400) {
            reject(new Error(text || `Oppi subagents bridge returned ${res.statusCode}`));
            return;
          }
          try {
            resolvePromise((text ? JSON.parse(text) : {}) as T);
          } catch (error) {
            reject(error instanceof Error ? error : new Error(String(error)));
          }
        });
      },
    );
    req.on("error", reject);
    if (options.signal) {
      if (options.signal.aborted) {
        req.destroy(new Error("aborted"));
      } else {
        options.signal.addEventListener("abort", () => req.destroy(new Error("aborted")), {
          once: true,
        });
      }
    }
    if (bodyText) req.write(bodyText);
    req.end();
  });
}

function normalizeProfileName(value: string): string {
  return value.trim().toLowerCase();
}

function buildProfilePrompt(message: string, profileName: string | undefined): string {
  if (!profileName) return message;
  const profile = BUILT_IN_PROFILES[normalizeProfileName(profileName)];
  if (!profile) return message;
  const canonicalName = normalizeProfileName(profileName);
  const lines = [`[Subagent profile: ${canonicalName}]`];
  if (profile.description) lines.push(profile.description);
  if (profile.guidelines?.length) {
    lines.push("Guidelines:");
    for (const guideline of profile.guidelines) lines.push(`- ${guideline}`);
  }
  lines.push("", message);
  return lines.join("\n");
}

function bridgeUnavailableText(): string {
  return "Oppi subagents bridge is unavailable. Start or mirror this Pi session from Oppi, then retry.";
}

function isBusy(session: BridgeSessionSummary | undefined): boolean {
  return (
    session?.status === "starting" || session?.status === "busy" || session?.status === "stopping"
  );
}

function isTerminal(session: BridgeSessionSummary | undefined): boolean {
  return (
    session?.status === "ready" || session?.status === "stopped" || session?.status === "error"
  );
}

function subagentStatusLabel(session: BridgeSessionSummary): string {
  switch (session.status) {
    case "starting":
      return "Starting";
    case "ready":
      return session.lastAgentReplyAt ? "Ready" : "Idle";
    case "busy":
      return "Running";
    case "stopping":
      return "Stopping";
    case "stopped":
      return "Stopped";
    case "error":
      return "Error";
  }
}

function subagentState(
  status: BridgeSessionSummary["status"],
): "queued" | "running" | "success" | "warning" | "error" | "inactive" {
  switch (status) {
    case "starting":
    case "busy":
    case "stopping":
      return "running";
    case "ready":
      return "success";
    case "error":
      return "error";
    case "stopped":
      return "inactive";
  }
}

function subagentSubtitle(session: BridgeSessionSummary): string {
  const parts = [subagentStatusLabel(session)];
  if (session.messageCount > 0) {
    parts.push(`${session.messageCount} message${session.messageCount === 1 ? "" : "s"}`);
  }
  const tokens = session.tokens;
  const totalTokens = tokens
    ? tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite
    : 0;
  if (totalTokens > 0) parts.push(`${Math.round(totalTokens / 100) / 10}k tokens`);
  if ((session.cost ?? 0) > 0) parts.push(`$${(session.cost ?? 0).toFixed(4)}`);
  return parts.join(" · ");
}

function subagentDetail(session: BridgeSessionSummary): string | undefined {
  return [session.lastMessage, session.firstMessage].find((value) => value?.trim());
}

function sessionLink(session: BridgeSessionSummary, workspaceId?: string): string {
  const base = `oppi://session/${encodeURIComponent(session.id)}`;
  const ws = session.workspaceId ?? workspaceId;
  return ws ? `${base}?workspaceId=${encodeURIComponent(ws)}` : base;
}

function completionText(session: BridgeSessionSummary, fallbackLastMessage?: string): string {
  const name = session.name ?? session.id;
  const status =
    session.status === "error" ? "error" : session.status === "stopped" ? "stopped" : "complete";
  const last = session.lastMessage ?? fallbackLastMessage;
  const lines = [`Subagent ${status}: ${name} (${session.id})`];
  if (last?.trim()) lines.push("", last.trim());
  return lines.join("\n");
}

export function createOppiSubagentsExtension(
  pi: ExtensionAPI,
  options: OppiSubagentsExtensionOptions = {},
): void {
  let activeBridge: ActiveBridge | undefined;
  let resolveTimer: ReturnType<typeof setTimeout> | undefined;
  let widgetPollTimer: ReturnType<typeof setTimeout> | undefined;
  const trackedSessionIds = new Set<string>();
  const lastAssistantMessages = new Map<string, string>();
  const completionWatchers = new Map<
    string,
    { baselineMessages: number; baselineOutput: number; name: string }
  >();
  const widgetSessions = new Map<string, BridgeSessionSummary>();
  let widgetRender: (() => void) | undefined;
  let latestCtx: ExtensionContext | undefined;

  function clearResolveTimer(): void {
    if (resolveTimer) clearTimeout(resolveTimer);
    resolveTimer = undefined;
  }

  function clearWidgetPollTimer(): void {
    if (widgetPollTimer) clearTimeout(widgetPollTimer);
    widgetPollTimer = undefined;
  }

  function initialDescriptor(): OppiSubagentsBridgeDescriptor | undefined {
    return (
      options.descriptor ??
      (options.descriptorPath
        ? normalizeDescriptor(readJsonFile(options.descriptorPath))
        : undefined) ??
      discoverDescriptorFromEnv() ??
      discoverDescriptorFromConfig()
    );
  }

  async function resolveBridge(ctx: ExtensionContext): Promise<ActiveBridge | undefined> {
    const descriptor = initialDescriptor();
    if (!descriptor) return undefined;
    if (descriptor.originSessionId && descriptor.workspaceId) {
      return { descriptor, ctx };
    }

    const sessionManager = ctx.sessionManager as {
      getSessionId?: () => string;
      getSessionFile?: () => string | undefined;
    };
    try {
      const resolved = await requestJson<ResolveResponse>(descriptor, "/resolve", {
        method: "POST",
        body: {
          piSessionId: sessionManager.getSessionId?.(),
          piSessionFile: sessionManager.getSessionFile?.(),
          cwd: ctx.cwd,
        },
      });
      return { descriptor: { ...descriptor, ...resolved.descriptor }, ctx };
    } catch {
      return undefined;
    }
  }

  async function ensureBridge(): Promise<ActiveBridge> {
    if (activeBridge) return activeBridge;
    if (latestCtx) {
      activeBridge = await resolveBridge(latestCtx);
    }
    if (!activeBridge) throw new Error(bridgeUnavailableText());
    return activeBridge;
  }

  async function bridgeRequest<T>(path: string, opts: BridgeRequestOptions = {}): Promise<T> {
    const bridge = await ensureBridge();
    const body =
      opts.body && typeof opts.body === "object" && !Array.isArray(opts.body)
        ? { originSessionId: bridge.descriptor.originSessionId, ...opts.body }
        : opts.body;
    return requestJson<T>(bridge.descriptor, path, { ...opts, body });
  }

  async function listSessions(): Promise<BridgeSessionSummary[]> {
    const bridge = await ensureBridge();
    const params = new URLSearchParams();
    if (bridge.descriptor.originSessionId) {
      params.set("originSessionId", bridge.descriptor.originSessionId);
    }
    const ids = Array.from(trackedSessionIds).join(",");
    if (ids) params.set("ids", ids);
    const query = params.toString() ? `?${params.toString()}` : "";
    const result = await bridgeRequest<SessionsResponse>(`/sessions${query}`);
    widgetSessions.clear();
    for (const session of result.sessions) widgetSessions.set(session.id, session);
    return result.sessions;
  }

  function syncActiveToolsForBridge(bridge: ActiveBridge | undefined): void {
    if (bridge?.descriptor.canSpawn !== false) return;
    const activeTools = pi.getActiveTools() as unknown as Array<string | { name: string }>;
    const activeNames = activeTools.map((tool) => (typeof tool === "string" ? tool : tool.name));
    if (!activeNames.includes("spawn_agent")) return;
    pi.setActiveTools(activeNames.filter((name) => name !== "spawn_agent"));
  }

  function scheduleWidgetPoll(): void {
    clearWidgetPollTimer();
    widgetPollTimer = setTimeout(() => {
      void pollWidget();
    }, POLL_INTERVAL_MS);
  }

  async function pollWidget(): Promise<void> {
    if (!activeBridge) return;
    try {
      const sessions = await listSessions();
      for (const session of sessions) {
        const last = session.lastMessage;
        if (last) lastAssistantMessages.set(session.id, last);
        const watcher = completionWatchers.get(session.id);
        if (!watcher) continue;
        const producedOutput =
          session.messageCount > watcher.baselineMessages ||
          (session.tokens?.output ?? 0) > watcher.baselineOutput ||
          Boolean(last);
        if (isTerminal(session) && producedOutput) {
          completionWatchers.delete(session.id);
          const parent = activeBridge.descriptor.originSessionId
            ? widgetSessions.get(activeBridge.descriptor.originSessionId)
            : undefined;
          pi.sendMessage(
            {
              customType: "subagent_result",
              content: completionText(session, lastAssistantMessages.get(session.id)),
              display: true,
              details: {
                agentId: session.id,
                name: session.name ?? watcher.name,
                status: session.status,
                cost: session.cost,
              },
            },
            isBusy(parent) ? { deliverAs: "followUp", triggerTurn: true } : { triggerTurn: true },
          );
        }
      }
      widgetRender?.();
    } catch {
      // Keep terminal and mobile UI quiet; the next poll may succeed after mirror reconnects.
    } finally {
      if (widgetRender) scheduleWidgetPoll();
    }
  }

  function createWidget(): {
    render(width: number): string[];
    renderNative(): unknown;
    invalidate(): void;
    dispose(): void;
  } {
    return {
      render(width: number): string[] {
        const sessions = Array.from(widgetSessions.values()).sort(
          (a, b) => b.lastActivity - a.lastActivity || a.id.localeCompare(b.id),
        );
        if (sessions.length === 0) return [];
        const maxTitle = Math.max(12, Math.min(36, width - 24));
        return [
          "● Agents",
          ...sessions.map((session) => {
            const name = session.name ?? `Agent ${session.id.slice(0, 8)}`;
            const title = name.length > maxTitle ? `${name.slice(0, maxTitle - 1)}…` : name;
            return `  ${subagentStatusLabel(session).padEnd(8)} ${title} · ${session.id.slice(0, 8)}`;
          }),
        ];
      },
      renderNative() {
        const sessions = Array.from(widgetSessions.values()).sort(
          (a, b) => b.lastActivity - a.lastActivity || a.id.localeCompare(b.id),
        );
        if (sessions.length === 0) return undefined;
        return {
          version: 1,
          id: "widget:subagents",
          source: "widget",
          presentation: {
            style: "surfacePanel",
            placement: "aboveEditor",
            title: "Agents",
          },
          lifecycle: {
            kind: "persistent",
            updateMode: "replace",
            clearOn: ["explicitClear", "sessionEnd", "sessionDelete", "runtimeDispose"],
          },
          blocks: [
            {
              type: "activityList",
              id: "agents",
              rows: sessions.map((session) => ({
                id: session.id,
                title: session.name ?? `Agent ${session.id.slice(0, 8)}`,
                subtitle: subagentSubtitle(session),
                detail: subagentDetail(session),
                state: subagentState(session.status),
                link: sessionLink(session, activeBridge?.descriptor.workspaceId),
              })),
            },
          ],
          fallback: { lines: this.render(88) },
        };
      },
      invalidate() {
        widgetRender?.();
      },
      dispose() {
        widgetRender = undefined;
        clearWidgetPollTimer();
      },
    };
  }

  pi.on("session_start", (_event, ctx) => {
    latestCtx = ctx;
    clearResolveTimer();
    void resolveBridge(ctx).then((bridge) => {
      activeBridge = bridge;
      syncActiveToolsForBridge(bridge);
      if (!bridge) {
        resolveTimer = setTimeout(() => {
          const current = activeBridge;
          if (!current) {
            void resolveBridge(ctx).then((retry) => {
              activeBridge = retry;
              syncActiveToolsForBridge(retry);
              if (!retry) return;
              ctx.ui.notify("Oppi subagents bridge connected", "info");
              void pollWidget();
            });
          }
        }, STARTUP_RESOLVE_RETRY_MS);
        return;
      }
      void pollWidget();
    });

    ctx.ui.setWidget(
      "subagents",
      (tui: unknown) => {
        widgetRender = (tui as { requestRender?: () => void }).requestRender;
        void pollWidget();
        return createWidget();
      },
      { placement: "aboveEditor" },
    );
  });

  pi.on("before_agent_start", async () => {
    const bridge = await ensureBridge().catch(() => undefined);
    syncActiveToolsForBridge(bridge);
  });

  pi.on("session_shutdown", () => {
    clearResolveTimer();
    clearWidgetPollTimer();
    activeBridge = undefined;
    latestCtx = undefined;
    widgetSessions.clear();
    trackedSessionIds.clear();
    completionWatchers.clear();
    widgetRender = undefined;
  });

  pi.registerTool<typeof sendMessageParams>({
    name: "send_message",
    label: "Send Message",
    description: "Send a message to another Oppi/Pi session in the same workspace.",
    parameters: sendMessageParams,
    async execute(_toolCallId, params: Static<typeof sendMessageParams>) {
      try {
        await bridgeRequest("/send", {
          method: "POST",
          body: {
            targetSessionId: params.id,
            message: params.message,
            behavior: params.behavior,
          },
        });
        return {
          content: [{ type: "text" as const, text: `Message sent to ${params.id}.` }],
          details: { agentId: params.id, status: "sent" },
        };
      } catch (error) {
        return {
          content: [
            { type: "text" as const, text: error instanceof Error ? error.message : String(error) },
          ],
          details: { agentId: params.id, status: "error" },
          isError: true,
        };
      }
    },
  });

  pi.registerTool<typeof inspectAgentParams>({
    name: "inspect_agent",
    label: "Inspect Agent",
    description: "Inspect another Oppi/Pi session trace.",
    parameters: inspectAgentParams,
    async execute(_toolCallId, params: Static<typeof inspectAgentParams>) {
      try {
        const result = await bridgeRequest<InspectResponse>("/inspect", {
          method: "POST",
          body: {
            targetSessionId: params.id,
            turn: params.turn,
            tool: params.tool,
            response: params.response,
          },
        });
        return {
          content: [{ type: "text" as const, text: result.text }],
          details: { sessionId: params.id, ...(result.details ?? {}) },
        };
      } catch (error) {
        return {
          content: [
            { type: "text" as const, text: error instanceof Error ? error.message : String(error) },
          ],
          details: { sessionId: params.id, status: "error" },
          isError: true,
        };
      }
    },
  });

  if (initialDescriptor()?.canSpawn !== false) {
    pi.registerTool<typeof spawnAgentParams>({
      name: "spawn_agent",
      label: "Spawn Agent",
      description:
        "Create a child Oppi/Pi session in the current workspace. The child runs independently and reports back with subagent_result when it finishes.",
      promptSnippet:
        "spawn_agent(message, name?, profile?, model?, thinking?, detached?, wait?, timeout_seconds?) — spawn a child agent session",
      promptGuidelines: [
        "Give each spawned agent a clear, self-contained task description with all needed context.",
        "The child agent cannot see the parent's conversation history — include relevant context in the message.",
        "Use fire-and-forget for independent work; use wait=true only for sequential dependencies.",
        "Before spawning a new child for follow-up work, prefer send_message to the existing subagent that already investigated the area.",
      ],
      parameters: spawnAgentParams,
      async execute(
        _toolCallId,
        params: Static<typeof spawnAgentParams>,
        signal: AbortSignal | undefined,
        onUpdate,
      ) {
        const bridge = await ensureBridge().catch(() => undefined);
        if (!bridge) {
          return {
            content: [{ type: "text" as const, text: bridgeUnavailableText() }],
            details: {
              agentId: "",
              name: params.name ?? params.message.slice(0, 80),
              status: "error",
            },
            isError: true,
          };
        }
        if (bridge.descriptor.canSpawn === false) {
          return {
            content: [{ type: "text" as const, text: "This session cannot spawn subagents." }],
            details: {
              agentId: "",
              name: params.name ?? params.message.slice(0, 80),
              status: "error",
            },
            isError: true,
          };
        }
        const profile = params.profile ? normalizeProfileName(params.profile) : undefined;
        if (profile && !BUILT_IN_PROFILES[profile]) {
          const available = Object.keys(BUILT_IN_PROFILES)
            .sort()
            .map((name) => `  - ${name}`)
            .join("\n");
          return {
            content: [
              {
                type: "text" as const,
                text: `Unknown subagent profile "${params.profile}". Available profiles:\n${available}`,
              },
            ],
            details: {
              agentId: "",
              name: params.name ?? params.message.slice(0, 80),
              status: "error",
            },
            isError: true,
          };
        }

        const name = params.name ?? params.message.slice(0, 80);
        onUpdate?.({
          content: [{ type: "text", text: `Creating session "${name}"...` }],
          details: { name },
        });
        try {
          const spawned = await bridgeRequest<SpawnResponse>("/spawn", {
            method: "POST",
            body: {
              name,
              prompt: buildProfilePrompt(params.message, profile),
              model: params.model,
              thinking: params.thinking,
              detached: params.detached ?? false,
            },
            signal,
          });
          const session = spawned.session;
          trackedSessionIds.add(session.id);
          widgetSessions.set(session.id, session);
          widgetRender?.();

          if (!params.wait) {
            if (!params.detached) {
              completionWatchers.set(session.id, {
                baselineMessages: session.messageCount,
                baselineOutput: session.tokens?.output ?? 0,
                name,
              });
              scheduleWidgetPoll();
            }
            return {
              content: [
                {
                  type: "text" as const,
                  text:
                    `Spawned ${params.detached ? "detached " : ""}agent "${session.name ?? name}" (${session.id}).\n` +
                    `Status: ${session.status}, Model: ${session.model ?? params.model ?? "inherited"}\n` +
                    (params.detached
                      ? "This is an independent session."
                      : "The session is now running independently. You'll get a subagent_result message when it finishes."),
                },
              ],
              details: {
                agentId: session.id,
                name: session.name ?? name,
                status: session.status,
                model: session.model ?? params.model,
                detached: params.detached ?? false,
              },
            };
          }

          const timeoutMs =
            params.timeout_seconds !== undefined
              ? params.timeout_seconds * 1000
              : (bridge.descriptor.defaultWaitTimeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS);
          const startedAt = Date.now();
          while (Date.now() - startedAt < timeoutMs) {
            if (signal?.aborted) throw new Error("spawn_agent wait aborted");
            const sessions = await listSessions();
            const latest = sessions.find((item) => item.id === session.id) ?? session;
            onUpdate?.({
              content: [
                { type: "text", text: `${subagentStatusLabel(latest)} ${latest.name ?? name}...` },
              ],
              details: { agentId: latest.id, status: latest.status },
            });
            const producedOutput =
              latest.messageCount > session.messageCount ||
              (latest.tokens?.output ?? 0) > (session.tokens?.output ?? 0) ||
              Boolean(latest.lastMessage);
            if (isTerminal(latest) && producedOutput) {
              await bridgeRequest("/stop", {
                method: "POST",
                body: { targetSessionId: latest.id },
              }).catch(() => undefined);
              return {
                content: [{ type: "text" as const, text: completionText(latest) }],
                details: {
                  agentId: latest.id,
                  name: latest.name ?? name,
                  status: latest.status,
                  waited: true,
                  cost: latest.cost,
                  durationMs: Date.now() - startedAt,
                },
              };
            }
            await new Promise((resolvePromise) => setTimeout(resolvePromise, 1_000));
          }
          return {
            content: [{ type: "text" as const, text: `Timed out waiting for ${session.id}.` }],
            details: { agentId: session.id, name, status: "timeout", waited: true },
            isError: true,
          };
        } catch (error) {
          return {
            content: [
              {
                type: "text" as const,
                text: `Failed to spawn agent: ${error instanceof Error ? error.message : String(error)}`,
              },
            ],
            details: { agentId: "", name, status: "error" },
            isError: true,
          };
        }
      },
    });
  }
}

export default function oppiSubagents(pi: ExtensionAPI): void {
  createOppiSubagentsExtension(pi);
}
