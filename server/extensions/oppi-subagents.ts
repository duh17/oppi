import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export interface OppiSubagentsApiDescriptor {
  version: 1;
  baseUrl: string;
  token?: string;
  originSessionId?: string;
  workspaceId?: string;
  runtime?: "oppi" | "pi-tui";
  canSpawn?: boolean;
  defaultWaitTimeoutMs?: number;
}

interface SessionSummary {
  id: string;
  name?: string;
  status: "starting" | "ready" | "busy" | "stopping" | "stopped" | "error";
  workspaceId?: string;
  parentSessionId?: string;
  piSessionId?: string;
  runtime?: "oppi" | "pi-tui";
  createdAt: number;
  lastActivity: number;
  currentTurnStartedAt?: number;
  messageCount: number;
  tokens?: {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
  };
  contextTokens?: number;
  contextWindow?: number;
  cost?: number;
  model?: string;
  thinkingLevel?: string;
  firstMessage?: string;
  lastMessage?: string;
  lastAgentReplyAt?: number;
  warnings?: string[];
}

interface CreateSessionResponse {
  session: SessionSummary;
}

interface SessionsResponse {
  sessions?: SessionSummary[];
  active?: SessionSummary[];
  stopped?: SessionSummary[];
}

interface SessionResponse {
  session: SessionSummary;
  trace?: TraceEvent[];
}

interface CommandResponse {
  messages?: Array<{
    type?: string;
    requestId?: string;
    command?: string;
    success?: boolean;
    error?: string;
    message?: string;
  }>;
}

interface TraceEvent {
  type?: string;
  role?: string;
  text?: string;
  content?: unknown;
  message?: unknown;
  name?: string;
  toolName?: string;
  tool_call_id?: string;
  toolCallId?: string;
  input?: unknown;
  args?: unknown;
  arguments?: unknown;
  output?: unknown;
  result?: unknown;
  isError?: boolean;
}

interface ApiRequestOptions {
  method?: "GET" | "POST";
  body?: unknown;
  signal?: AbortSignal;
}

interface OppiSubagentsExtensionOptions {
  descriptor?: OppiSubagentsApiDescriptor;
  descriptorPath?: string;
}

interface ActiveApi {
  descriptor: OppiSubagentsApiDescriptor;
  ctx: ExtensionContext;
  origin?: SessionSummary;
}

interface SubagentsConfig {
  enabled?: boolean;
  maxDepth?: number;
  defaultWaitTimeoutMs?: number;
}

const POLL_INTERVAL_MS = 2_000;
const STARTUP_RESOLVE_RETRY_MS = 2_000;
const DEFAULT_WAIT_TIMEOUT_MS = 30 * 60_000;
const RECENT_SESSION_LOOKUP_DAYS = 30;
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
  id: Type.String({ description: "Session ID of the target session to inspect." }),
  turn: Type.Optional(Type.Number({ description: "Turn number to drill into (1-based)." })),
  tool: Type.Optional(Type.Number({ description: "Tool index within the turn (1-based)." })),
  response: Type.Optional(
    Type.Boolean({
      description:
        "If true, return the assistant response. Defaults to true when no turn or tool is specified.",
    }),
  ),
});

const sendMessageParams = Type.Object({
  id: Type.String({ description: "Session ID of the target agent." }),
  message: Type.String({ description: "Message to send." }),
  behavior: Type.Optional(
    Type.Union([
      Type.Literal("auto"),
      Type.Literal("steer"),
      Type.Literal("followUp"),
      Type.Literal("follow_up"),
      Type.Literal("prompt"),
    ]),
  ),
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

interface TraceToolCall {
  index: number;
  id?: string;
  name: string;
  input?: unknown;
  output?: unknown;
  isError?: boolean;
}

interface TraceTurn {
  index: number;
  user?: string;
  assistant: string[];
  tools: TraceToolCall[];
}

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

function objectValue(value: unknown, key: string): unknown {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  return (value as Record<string, unknown>)[key];
}

function localHostForConfig(host: unknown): string {
  const value = typeof host === "string" ? host.trim() : "";
  if (!value || value === "0.0.0.0" || value === "::" || value === "[::]") return "127.0.0.1";
  return value;
}

function normalizeBaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, "");
}

function discoverDescriptorFromEnv(): OppiSubagentsApiDescriptor | undefined {
  const file = process.env.OPPI_SUBAGENTS_API_FILE?.trim();
  if (file) {
    const parsed = readJsonFile(resolve(expandHomePath(file)));
    const descriptor = normalizeDescriptor(parsed);
    if (descriptor) return descriptor;
  }

  const baseUrl = process.env.OPPI_SERVER_URL?.trim() || process.env.OPPI_SUBAGENTS_API_URL?.trim();
  if (!baseUrl) return undefined;
  return {
    version: 1,
    baseUrl: normalizeBaseUrl(baseUrl),
    token: process.env.OPPI_TOKEN || process.env.OPPI_SUBAGENTS_API_TOKEN,
    originSessionId: process.env.OPPI_SESSION_ID,
    workspaceId: process.env.OPPI_WORKSPACE_ID,
    canSpawn: process.env.OPPI_SUBAGENTS_CAN_SPAWN !== "false",
  };
}

function discoverDescriptorFromConfig(): OppiSubagentsApiDescriptor | undefined {
  const config = readJsonFile(oppiConfigPath()) as {
    host?: unknown;
    port?: unknown;
    tls?: { mode?: unknown };
    token?: unknown;
    serverUrl?: unknown;
  };
  const token = typeof config.token === "string" ? config.token.trim() : "";

  const directServerUrl = typeof config.serverUrl === "string" ? config.serverUrl.trim() : "";
  if (directServerUrl) {
    return {
      version: 1,
      baseUrl: normalizeBaseUrl(directServerUrl),
      token: token || undefined,
      canSpawn: true,
      defaultWaitTimeoutMs: readSubagentsConfig(config).defaultWaitTimeoutMs,
    };
  }

  const port =
    typeof config.port === "number" || typeof config.port === "string" ? String(config.port) : "";
  if (!token || !port) return undefined;

  const scheme = config.tls?.mode === "disabled" ? "http" : "https";
  const host = localHostForConfig(config.host);
  return {
    version: 1,
    baseUrl: `${scheme}://${host}:${port}`,
    token,
    canSpawn: true,
    defaultWaitTimeoutMs: readSubagentsConfig(config).defaultWaitTimeoutMs,
  };
}

function readSubagentsConfig(
  config: Record<string, unknown> = readJsonFile(oppiConfigPath()),
): SubagentsConfig {
  const extensions = objectValue(config, "extensions");
  const subagents = objectValue(extensions, "subagents") ?? objectValue(config, "subagents");
  if (!subagents || typeof subagents !== "object" || Array.isArray(subagents)) return {};
  const value = subagents as Record<string, unknown>;
  return {
    enabled: typeof value.enabled === "boolean" ? value.enabled : undefined,
    maxDepth:
      typeof value.maxDepth === "number" && Number.isFinite(value.maxDepth)
        ? value.maxDepth
        : undefined,
    defaultWaitTimeoutMs:
      typeof value.defaultWaitTimeoutMs === "number" && Number.isFinite(value.defaultWaitTimeoutMs)
        ? value.defaultWaitTimeoutMs
        : undefined,
  };
}

function normalizeDescriptor(value: unknown): OppiSubagentsApiDescriptor | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const obj = value as Record<string, unknown>;
  if (typeof obj.baseUrl !== "string" || obj.baseUrl.trim().length === 0) return undefined;
  return {
    version: 1,
    baseUrl: normalizeBaseUrl(obj.baseUrl),
    token: typeof obj.token === "string" ? obj.token : undefined,
    originSessionId: typeof obj.originSessionId === "string" ? obj.originSessionId : undefined,
    workspaceId: typeof obj.workspaceId === "string" ? obj.workspaceId : undefined,
    runtime: obj.runtime === "oppi" || obj.runtime === "pi-tui" ? obj.runtime : undefined,
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
  descriptor: OppiSubagentsApiDescriptor,
  path: string,
  options: ApiRequestOptions = {},
): Promise<T> {
  const base = descriptor.baseUrl.replace(/\/+$/, "");
  const url = new URL(path.startsWith("/") ? `${base}${path}` : `${base}/${path}`);
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
            req.destroy(new Error("Oppi session API response exceeded size limit"));
            return;
          }
          chunks.push(chunk);
        });
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let payload: unknown = {};
          if (text) {
            try {
              payload = JSON.parse(text);
            } catch (error) {
              reject(error instanceof Error ? error : new Error(String(error)));
              return;
            }
          }
          if ((res.statusCode ?? 500) >= 400) {
            const message =
              payload &&
              typeof payload === "object" &&
              typeof (payload as { error?: unknown }).error === "string"
                ? (payload as { error: string }).error
                : text || `Oppi session API returned ${res.statusCode}`;
            reject(new Error(message));
            return;
          }
          resolvePromise(payload as T);
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

function pathSegment(value: string): string {
  return encodeURIComponent(value);
}

async function fetchRecentSessions(
  descriptor: OppiSubagentsApiDescriptor,
  piSessionId?: string,
): Promise<SessionSummary[]> {
  const search = new URLSearchParams({ recentDays: String(RECENT_SESSION_LOOKUP_DAYS) });
  if (piSessionId) search.set("piSessionId", piSessionId);
  const result = await requestJson<SessionsResponse>(descriptor, `/sessions/recent?${search}`);
  return result.sessions ?? [];
}

async function fetchWorkspaceSessions(
  descriptor: OppiSubagentsApiDescriptor,
  workspaceId: string,
): Promise<SessionSummary[]> {
  const result = await requestJson<SessionsResponse>(
    descriptor,
    `/workspaces/${pathSegment(workspaceId)}/sessions?status=active`,
  );
  return [...(result.active ?? []), ...(result.sessions ?? [])];
}

async function fetchSession(
  descriptor: OppiSubagentsApiDescriptor,
  workspaceId: string,
  sessionId: string,
  trace = false,
): Promise<SessionResponse> {
  return requestJson<SessionResponse>(
    descriptor,
    `/workspaces/${pathSegment(workspaceId)}/sessions/${pathSegment(sessionId)}${trace ? "?view=full" : ""}`,
  );
}

async function sendCommand(
  descriptor: OppiSubagentsApiDescriptor,
  workspaceId: string,
  sessionId: string,
  body: Record<string, unknown>,
): Promise<void> {
  const requestId = `subagents-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const result = await requestJson<CommandResponse>(
    descriptor,
    `/workspaces/${pathSegment(workspaceId)}/sessions/${pathSegment(sessionId)}/command`,
    {
      method: "POST",
      body: { ...body, requestId },
    },
  );
  const commandResult = result.messages?.find(
    (message) => message.type === "command_result" && message.requestId === requestId,
  );
  if (commandResult?.success === false) {
    throw new Error(commandResult.error || commandResult.message || "Session command failed");
  }
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

function unavailableText(): string {
  return "Oppi subagents are unavailable. Start or mirror this Pi session from Oppi, then retry.";
}

function isBusy(session: SessionSummary | undefined): boolean {
  return (
    session?.status === "starting" || session?.status === "busy" || session?.status === "stopping"
  );
}

function isTerminal(session: SessionSummary | undefined): boolean {
  return (
    session?.status === "ready" || session?.status === "stopped" || session?.status === "error"
  );
}

function subagentStatusLabel(session: SessionSummary): string {
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
  status: SessionSummary["status"],
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

function compactNumber(value: number): string {
  if (value >= 1_000_000) return `${Math.round(value / 100_000) / 10}m`;
  if (value >= 1_000) return `${Math.round(value / 100) / 10}k`;
  return String(Math.round(value));
}

function contextUsageLabel(session: SessionSummary): string | undefined {
  if (typeof session.contextTokens === "number" && typeof session.contextWindow === "number") {
    return `${compactNumber(session.contextTokens)}/${compactNumber(session.contextWindow)} ctx`;
  }
  const tokens = session.tokens;
  if (!tokens) return undefined;
  const total = tokens.input + tokens.output + tokens.cacheRead + tokens.cacheWrite;
  return total > 0 ? `${compactNumber(total)} tokens` : undefined;
}

function costOrContextLabel(session: SessionSummary): string | undefined {
  if ((session.cost ?? 0) > 0) return `$${(session.cost ?? 0).toFixed(4)}`;
  return contextUsageLabel(session);
}

function subagentSubtitle(session: SessionSummary): string {
  return [subagentStatusLabel(session), costOrContextLabel(session)].filter(Boolean).join(" · ");
}

function sessionLink(session: SessionSummary, workspaceId?: string): string {
  const base = `oppi://session/${encodeURIComponent(session.id)}`;
  const ws = session.workspaceId ?? workspaceId;
  return ws ? `${base}?workspaceId=${encodeURIComponent(ws)}` : base;
}

function completionText(session: SessionSummary, fallbackLastMessage?: string): string {
  const name = session.name ?? session.id;
  const status =
    session.status === "error" ? "error" : session.status === "stopped" ? "stopped" : "complete";
  const last = session.lastMessage ?? fallbackLastMessage;
  const lines = [`Subagent ${status}: ${name} (${session.id})`];
  const meta = [costOrContextLabel(session)].filter(Boolean).join(" · ");
  if (meta) lines.push(meta);
  if (session.warnings?.length) lines.push("", session.warnings.join("\n"));
  if (last?.trim()) lines.push("", last.trim());
  return lines.join("\n");
}

function getCurrentPiSessionId(ctx: ExtensionContext): string | undefined {
  const sessionManager = ctx.sessionManager as { getSessionId?: () => string };
  return sessionManager.getSessionId?.();
}

function sessionDepth(session: SessionSummary, sessions: SessionSummary[]): number {
  const byId = new Map(sessions.map((item) => [item.id, item]));
  let depth = 0;
  let current: SessionSummary | undefined = session;
  const seen = new Set<string>();
  while (current?.parentSessionId && !seen.has(current.parentSessionId)) {
    seen.add(current.parentSessionId);
    current = byId.get(current.parentSessionId);
    if (current) depth += 1;
  }
  return depth;
}

function hasNewOutput(baseline: SessionSummary, latest: SessionSummary): boolean {
  if (latest.status === "error") return true;
  if (latest.messageCount > baseline.messageCount) return true;
  if ((latest.tokens?.output ?? 0) > (baseline.tokens?.output ?? 0)) return true;
  if ((latest.lastAgentReplyAt ?? 0) > (baseline.lastAgentReplyAt ?? 0)) return true;
  return false;
}

function textFromUnknown(value: unknown): string | undefined {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return undefined;
  return value
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      const candidate = block as { type?: unknown; text?: unknown };
      return candidate.type === "text" && typeof candidate.text === "string" ? candidate.text : "";
    })
    .filter(Boolean)
    .join("\n");
}

function eventText(event: TraceEvent): string | undefined {
  return event.text ?? textFromUnknown(event.content) ?? textFromUnknown(event.message);
}

function parseTraceTurns(trace: TraceEvent[]): TraceTurn[] {
  const turns: TraceTurn[] = [];
  let current: TraceTurn | undefined;
  const toolsById = new Map<string, TraceToolCall>();

  const ensureTurn = (): TraceTurn => {
    if (!current) {
      current = { index: turns.length + 1, assistant: [], tools: [] };
      turns.push(current);
    }
    return current;
  };

  for (const event of trace) {
    const type = event.type ?? event.role;
    const text = eventText(event);
    if (type === "user" || type === "message:user") {
      current = { index: turns.length + 1, user: text, assistant: [], tools: [] };
      turns.push(current);
      continue;
    }
    if (type === "assistant" || type === "assistant_message" || type === "message:assistant") {
      if (text) ensureTurn().assistant.push(text);
      continue;
    }
    if (type === "toolCall" || type === "tool_call" || type === "function_call") {
      const turn = ensureTurn();
      const id = event.toolCallId ?? event.tool_call_id;
      const tool: TraceToolCall = {
        index: turn.tools.length + 1,
        id,
        name: event.toolName ?? event.name ?? "tool",
        input: event.input ?? event.args ?? event.arguments,
      };
      turn.tools.push(tool);
      if (id) toolsById.set(id, tool);
      continue;
    }
    if (type === "toolResult" || type === "tool_result" || type === "function_result") {
      const id = event.toolCallId ?? event.tool_call_id;
      const tool = (id && toolsById.get(id)) || ensureTurn().tools.at(-1);
      if (tool) {
        tool.output = event.output ?? event.result ?? text;
        tool.isError = event.isError;
      }
    }
  }

  return turns;
}

function stringifyValue(value: unknown): string {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function renderTraceOverview(session: SessionSummary, turns: TraceTurn[]): string {
  const lines = [
    `${session.name ?? `Session ${session.id.slice(0, 8)}`} (${session.id})`,
    `Status: ${session.status}`,
    costOrContextLabel(session),
    `Turns: ${turns.length}`,
  ].filter(Boolean) as string[];
  const latest = [...turns].reverse().find((turn) => turn.assistant.length || turn.user);
  if (latest?.user) lines.push(`Latest user: ${latest.user.slice(0, 240)}`);
  if (latest?.assistant.length)
    lines.push(`Latest response: ${latest.assistant.join("\n").slice(0, 1000)}`);
  return lines.join("\n");
}

function renderTraceTurn(turn: TraceTurn): string {
  const lines = [`Turn ${turn.index}`];
  if (turn.user) lines.push("", "User:", turn.user);
  if (turn.assistant.length) lines.push("", "Assistant:", turn.assistant.join("\n"));
  for (const tool of turn.tools) {
    lines.push("", `Tool ${tool.index}: ${tool.name}`);
    const input = stringifyValue(tool.input);
    if (input) lines.push("Input:", input);
    const output = stringifyValue(tool.output);
    if (output) lines.push(tool.isError ? "Error:" : "Output:", output);
  }
  return lines.join("\n");
}

function renderTraceTool(turn: TraceTurn, toolIndex: number): string {
  const tool = turn.tools[toolIndex - 1];
  if (!tool) throw new Error(`Tool ${toolIndex} not found in turn ${turn.index}`);
  const lines = [`Turn ${turn.index} · Tool ${tool.index}: ${tool.name}`];
  const input = stringifyValue(tool.input);
  if (input) lines.push("", "Input:", input);
  const output = stringifyValue(tool.output);
  if (output) lines.push("", tool.isError ? "Error:" : "Output:", output);
  return lines.join("\n");
}

function renderTraceResponse(turns: TraceTurn[], turnNumber?: number): string {
  const turn =
    turnNumber !== undefined
      ? turns.find((item) => item.index === turnNumber)
      : [...turns].reverse().find((item) => item.assistant.length);
  if (!turn)
    return turnNumber !== undefined
      ? `Turn ${turnNumber} not found.`
      : "No assistant response found.";
  const response = turn.assistant.join("\n").trim();
  return response || `Turn ${turn.index} has no assistant response text.`;
}

function commandTypeForBehavior(
  behavior: Static<typeof sendMessageParams>["behavior"],
  target: SessionSummary,
): "prompt" | "steer" | "follow_up" {
  if (behavior === "prompt") return "prompt";
  if (behavior === "followUp" || behavior === "follow_up") return "follow_up";
  if (behavior === "steer") return "steer";
  return isBusy(target) ? "steer" : "prompt";
}

function originPrefix(
  origin: SessionSummary | undefined,
  originSessionId: string | undefined,
): string {
  if (origin?.name) return `[From agent "${origin.name}" (${origin.id})]`;
  if (origin?.id) return `[From agent ${origin.id}]`;
  if (originSessionId) return `[From agent ${originSessionId}]`;
  return "[From another Oppi session]";
}

export function createOppiSubagentsExtension(
  pi: ExtensionAPI,
  options: OppiSubagentsExtensionOptions = {},
): void {
  let activeApi: ActiveApi | undefined;
  let resolveTimer: ReturnType<typeof setTimeout> | undefined;
  let widgetPollTimer: ReturnType<typeof setTimeout> | undefined;
  const trackedSessionIds = new Set<string>();
  const lastAssistantMessages = new Map<string, string>();
  const completionWatchers = new Map<string, { baseline: SessionSummary; name: string }>();
  const widgetSessions = new Map<string, SessionSummary>();
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

  function initialDescriptor(): OppiSubagentsApiDescriptor | undefined {
    const config = readSubagentsConfig();
    if (config.enabled === false) return undefined;
    const descriptor =
      options.descriptor ??
      (options.descriptorPath
        ? normalizeDescriptor(readJsonFile(options.descriptorPath))
        : undefined) ??
      discoverDescriptorFromEnv() ??
      discoverDescriptorFromConfig();
    if (!descriptor) return undefined;
    return {
      ...descriptor,
      defaultWaitTimeoutMs: descriptor.defaultWaitTimeoutMs ?? config.defaultWaitTimeoutMs,
    };
  }

  async function resolveApi(ctx: ExtensionContext): Promise<ActiveApi | undefined> {
    const descriptor = initialDescriptor();
    if (!descriptor) return undefined;

    if (descriptor.originSessionId && descriptor.workspaceId) {
      let origin: SessionSummary | undefined;
      try {
        origin = (
          await fetchSession(descriptor, descriptor.workspaceId, descriptor.originSessionId)
        ).session;
      } catch {
        origin = undefined;
      }
      return { descriptor, ctx, origin };
    }

    const piSessionId = getCurrentPiSessionId(ctx);
    if (!piSessionId) return undefined;
    try {
      const sessions = await fetchRecentSessions(descriptor, piSessionId);
      const origin = sessions.find((session) => session.piSessionId === piSessionId);
      if (!origin?.workspaceId) return undefined;
      const config = readSubagentsConfig();
      const maxDepth = config.maxDepth ?? 1;
      const canSpawn = descriptor.canSpawn ?? sessionDepth(origin, sessions) < maxDepth;
      return {
        descriptor: {
          ...descriptor,
          originSessionId: origin.id,
          workspaceId: origin.workspaceId,
          runtime: origin.runtime,
          canSpawn,
        },
        ctx,
        origin,
      };
    } catch {
      return undefined;
    }
  }

  async function ensureApi(): Promise<ActiveApi> {
    if (activeApi) return activeApi;
    if (latestCtx) {
      activeApi = await resolveApi(latestCtx);
    }
    if (!activeApi) throw new Error(unavailableText());
    return activeApi;
  }

  async function listSessions(): Promise<SessionSummary[]> {
    const api = await ensureApi();
    const workspaceId = api.descriptor.workspaceId;
    if (!workspaceId) return [];

    const active = await fetchWorkspaceSessions(api.descriptor, workspaceId);
    const byId = new Map(active.map((session) => [session.id, session]));

    for (const id of trackedSessionIds) {
      if (byId.has(id)) continue;
      try {
        const fetched = (await fetchSession(api.descriptor, workspaceId, id)).session;
        byId.set(id, fetched);
      } catch {
        trackedSessionIds.delete(id);
        widgetSessions.delete(id);
      }
    }

    const sessions = Array.from(byId.values()).filter(
      (session) =>
        session.parentSessionId === api.descriptor.originSessionId ||
        trackedSessionIds.has(session.id),
    );
    widgetSessions.clear();
    for (const session of sessions) widgetSessions.set(session.id, session);
    return sessions;
  }

  function syncActiveToolsForApi(api: ActiveApi | undefined): void {
    if (api?.descriptor.canSpawn !== false) return;
    const activeNames = pi.getActiveTools();
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
    if (!activeApi) return;
    try {
      const sessions = await listSessions();
      for (const session of sessions) {
        const last = session.lastMessage;
        if (last) lastAssistantMessages.set(session.id, last);
        const watcher = completionWatchers.get(session.id);
        if (!watcher) continue;
        if (isTerminal(session) && hasNewOutput(watcher.baseline, session)) {
          completionWatchers.delete(session.id);
          const parent = activeApi.origin;
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
                contextTokens: session.contextTokens,
                contextWindow: session.contextWindow,
              },
            },
            isBusy(parent) ? { deliverAs: "followUp", triggerTurn: true } : { triggerTurn: true },
          );
        }
      }
      widgetRender?.();
    } catch {
      // Keep terminal and mobile UI quiet; the next poll may succeed after reconnects.
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
        const maxTitle = Math.max(12, Math.min(38, width - 24));
        return [
          "Agents",
          ...sessions.map((session) => {
            const name = session.name ?? `Agent ${session.id.slice(0, 8)}`;
            const title = name.length > maxTitle ? `${name.slice(0, maxTitle - 1)}…` : name;
            const meta = costOrContextLabel(session);
            return `  ${subagentStatusLabel(session).padEnd(8)} ${title}${meta ? ` · ${meta}` : ""}`;
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
                state: subagentState(session.status),
                link: sessionLink(session, activeApi?.descriptor.workspaceId),
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
    void resolveApi(ctx).then((api) => {
      activeApi = api;
      syncActiveToolsForApi(api);
      if (!api) {
        resolveTimer = setTimeout(() => {
          if (activeApi) return;
          void resolveApi(ctx).then((retry) => {
            activeApi = retry;
            syncActiveToolsForApi(retry);
            if (!retry) return;
            ctx.ui.notify("Oppi subagents connected", "info");
            void pollWidget();
          });
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
    const api = await ensureApi().catch(() => undefined);
    syncActiveToolsForApi(api);
  });

  pi.on("session_shutdown", () => {
    clearResolveTimer();
    clearWidgetPollTimer();
    activeApi = undefined;
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
        const api = await ensureApi();
        const workspaceId = api.descriptor.workspaceId;
        if (!workspaceId) throw new Error("Current workspace is unknown.");
        let target = widgetSessions.get(params.id);
        if (!target) target = (await fetchSession(api.descriptor, workspaceId, params.id)).session;
        if (target.status === "stopped") {
          target = (
            await requestJson<SessionResponse>(
              api.descriptor,
              `/workspaces/${pathSegment(workspaceId)}/sessions/${pathSegment(target.id)}/resume`,
              { method: "POST" },
            )
          ).session;
        }
        const type = commandTypeForBehavior(params.behavior, target);
        await sendCommand(api.descriptor, workspaceId, target.id, {
          type,
          message: `${originPrefix(api.origin, api.descriptor.originSessionId)}\n\n${params.message}`,
        });
        trackedSessionIds.add(target.id);
        widgetSessions.set(target.id, target);
        widgetRender?.();
        return {
          content: [{ type: "text" as const, text: `Message sent to ${target.id}.` }],
          details: { agentId: target.id, status: "sent", command: type },
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
        const api = await ensureApi();
        const workspaceId = api.descriptor.workspaceId;
        if (!workspaceId) throw new Error("Current workspace is unknown.");
        const result = await fetchSession(api.descriptor, workspaceId, params.id, true);
        const turns = parseTraceTurns(result.trace ?? []);
        let text: string;
        if (params.turn !== undefined && params.tool !== undefined) {
          const turn = turns.find((item) => item.index === params.turn);
          if (!turn) throw new Error(`Turn ${params.turn} not found.`);
          text = renderTraceTool(turn, params.tool);
        } else if (
          params.response === true ||
          (params.turn === undefined && params.tool === undefined && params.response !== false)
        ) {
          text = renderTraceResponse(turns, params.turn);
        } else if (params.turn !== undefined) {
          const turn = turns.find((item) => item.index === params.turn);
          if (!turn) throw new Error(`Turn ${params.turn} not found.`);
          text = renderTraceTurn(turn);
        } else {
          text = renderTraceOverview(result.session, turns);
        }
        return {
          content: [{ type: "text" as const, text }],
          details: { sessionId: params.id, status: result.session.status },
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
        const api = await ensureApi().catch(() => undefined);
        if (!api) {
          return {
            content: [{ type: "text" as const, text: unavailableText() }],
            details: {
              agentId: "",
              name: params.name ?? params.message.slice(0, 80),
              status: "error",
            },
            isError: true,
          };
        }
        if (api.descriptor.canSpawn === false) {
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
        const workspaceId = api.descriptor.workspaceId;
        if (!workspaceId) {
          return {
            content: [{ type: "text" as const, text: "Current workspace is unknown." }],
            details: { agentId: "", status: "error" },
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
          const spawned = await requestJson<CreateSessionResponse>(
            api.descriptor,
            `/workspaces/${pathSegment(workspaceId)}/sessions`,
            {
              method: "POST",
              body: {
                name,
                prompt: buildProfilePrompt(params.message, profile),
                model: params.model,
                thinking: params.thinking,
                ...(params.detached ? {} : { parentSessionId: api.descriptor.originSessionId }),
              },
              signal,
            },
          );
          const session = spawned.session;
          trackedSessionIds.add(session.id);
          widgetSessions.set(session.id, session);
          widgetRender?.();

          if (!params.wait) {
            if (!params.detached) {
              completionWatchers.set(session.id, { baseline: session, name });
              scheduleWidgetPoll();
            }
            return {
              content: [
                {
                  type: "text" as const,
                  text:
                    `Spawned ${params.detached ? "detached " : ""}agent "${session.name ?? name}" (${session.id}).\n` +
                    `Status: ${session.status}${costOrContextLabel(session) ? ` · ${costOrContextLabel(session)}` : ""}`,
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
              : (api.descriptor.defaultWaitTimeoutMs ?? DEFAULT_WAIT_TIMEOUT_MS);
          const startedAt = Date.now();
          while (Date.now() - startedAt < timeoutMs) {
            if (signal?.aborted) throw new Error("spawn_agent wait aborted");
            const sessions = await listSessions();
            const latest = sessions.find((item) => item.id === session.id) ?? session;
            onUpdate?.({
              content: [
                {
                  type: "text",
                  text: `${subagentStatusLabel(latest)} ${latest.name ?? name}${costOrContextLabel(latest) ? ` · ${costOrContextLabel(latest)}` : ""}`,
                },
              ],
              details: { agentId: latest.id, status: latest.status },
            });
            if (isTerminal(latest) && hasNewOutput(session, latest)) {
              await requestJson<SessionResponse>(
                api.descriptor,
                `/workspaces/${pathSegment(workspaceId)}/sessions/${pathSegment(latest.id)}/stop`,
                { method: "POST" },
              ).catch(() => undefined);
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
