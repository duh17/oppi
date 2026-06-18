import {
  type AgentSessionEvent,
  type AgentToolResult,
  type ExtensionAPI,
  type ExtensionContext,
  type ExtensionUIDialogOptions,
  type ExtensionUIContext,
  type ToolDefinition,
  type ToolRenderResultOptions,
} from "@earendil-works/pi-coding-agent";
import { WebSocket, type RawData } from "ws";
import { appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { hostname } from "node:os";

import {
  isOppiMirrorBridgeCommand,
  OPPI_MIRROR_CAPABILITIES,
  type OppiMirrorBridgeCommand,
} from "./oppi-mirror-contract.ts";

type OppiMirrorWorkspaceCreationMode = "ask" | "always" | "never";

interface OppiMirrorSettings {
  serverUrl?: string;
  token?: string;
  autoStart?: boolean;
  workspaceCreation?: OppiMirrorWorkspaceCreationMode;
}

type MirrorLogLevel = "debug" | "info" | "warn" | "error";

export interface QueueImageContent {
  data: string;
  mimeType: string;
}

export interface MessageQueueDraftItem {
  id?: string;
  message: string;
  images?: QueueImageContent[];
  createdAt?: number;
}

export interface MessageQueueItem {
  id: string;
  message: string;
  images?: QueueImageContent[];
  createdAt: number;
}

export interface MessageQueueState {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

interface EditableAgentSession {
  sessionId?: string;
  sessionManager?: {
    getSessionId?: () => string;
    getHeader?: () => { cwd?: string } | null;
  };
  getToolDefinition?: (name: string) => ToolDefinition | undefined;
  _steeringMessages?: string[];
  _followUpMessages?: string[];
  _emitQueueUpdate?: () => void;
  getSteeringMessages?: () => readonly string[];
  getFollowUpMessages?: () => readonly string[];
  agent?: {
    clearAllQueues?: () => void;
    clearSteeringQueue?: () => void;
    clearFollowUpQueue?: () => void;
    steer?: (message: unknown) => void;
    followUp?: (message: unknown) => void;
  };
  reload?: () => Promise<void>;
  abortCompaction?: () => void;
  abortRetry?: () => void;
  abortBash?: () => void;
  setAutoCompactionEnabled?: (enabled: boolean) => void;
  setAutoRetryEnabled?: (enabled: boolean) => void;
  setSteeringMode?: (mode: "all" | "one-at-a-time") => void;
  setFollowUpMode?: (mode: "all" | "one-at-a-time") => void;
  getUserMessagesForForking?: () => Array<{ entryId: string; text: string }>;
  navigateTree?: (
    targetId: string,
    options?: {
      summarize?: boolean;
      customInstructions?: string;
      replaceInstructions?: boolean;
      label?: string;
    },
  ) => Promise<unknown>;
}

interface QueueUpdateEvent {
  steering: readonly string[];
  followUp: readonly string[];
  session?: EditableAgentSession;
  sessionId?: string;
}

type QueueUpdateListener = (event: QueueUpdateEvent) => void;
type AgentSessionPrototype = {
  bindExtensions?: (this: unknown, ...args: unknown[]) => unknown;
  _emit?: (this: unknown, event: unknown, ...args: unknown[]) => unknown;
  _emitQueueUpdate?: (this: unknown, ...args: unknown[]) => unknown;
};
type InternalAgentSessionEvent = Extract<
  AgentSessionEvent,
  | { type: "compaction_start" }
  | { type: "compaction_end" }
  | { type: "auto_retry_start" }
  | { type: "auto_retry_end" }
>;
type InternalAgentSessionEventListener = (
  event: InternalAgentSessionEvent,
) => void;

interface QueueUpdateBridge {
  listeners: Set<QueueUpdateListener>;
  internalEventListeners: Set<InternalAgentSessionEventListener>;
  sessions: Map<string, EditableAgentSession>;
  installed: boolean;
  internalEventInstalled?: boolean;
  last?: QueueUpdateEvent;
  lastSession?: EditableAgentSession;
}

const QUEUE_UPDATE_BRIDGE_KEY = "__oppiMirrorQueueUpdateBridge";

const EVENT_TYPES = [
  "agent_start",
  "agent_end",
  "turn_start",
  "turn_end",
  "message_start",
  "message_update",
  "message_end",
  "tool_execution_start",
  "tool_execution_update",
  "tool_execution_end",
] as const;

const INTERNAL_AGENT_SESSION_EVENT_TYPES = new Set<AgentSessionEvent["type"]>([
  "compaction_start",
  "compaction_end",
  "auto_retry_start",
  "auto_retry_end",
]);

function settingsPath(): string {
  return join(process.env.HOME || "", ".pi/agent/settings.json");
}

function oppiConfigPath(): string {
  if (process.env.OPPI_CONFIG_PATH) return process.env.OPPI_CONFIG_PATH;
  const dataDir =
    process.env.OPPI_DATA_DIR || join(process.env.HOME || "", ".config/oppi");
  return join(dataDir, "config.json");
}

function readJsonFile(path: string): Record<string, unknown> {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function expandHomePath(path: string): string {
  const home = process.env.HOME || "";
  if (path === "~") return home;
  if (path.startsWith("~/")) return join(home, path.slice(2));
  return path;
}

function oppiDataDir(): string {
  const configured = process.env.OPPI_DATA_DIR?.trim();
  if (configured) return resolve(expandHomePath(configured));

  const config = readJsonFile(oppiConfigPath()) as { dataDir?: unknown };
  const dataDir =
    typeof config.dataDir === "string" ? config.dataDir.trim() : "";
  if (dataDir) return resolve(expandHomePath(dataDir));

  return resolve(join(process.env.HOME || "", ".config/oppi"));
}

function mirrorLogPath(): string {
  const configured = process.env.OPPI_MIRROR_LOG_PATH?.trim();
  return resolve(
    expandHomePath(configured || join(oppiDataDir(), "oppi-mirror.log")),
  );
}

function redactLogText(text: string): string {
  return text
    .replace(/Bearer\s+[^\s"']+/gi, "Bearer [REDACTED]")
    .replace(/\bsk_[A-Za-z0-9._-]+\b/g, "[REDACTED_TOKEN]");
}

function sanitizedLogValue(
  value: unknown,
  depth = 0,
  seen: WeakSet<object> = new WeakSet<object>(),
): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return redactLogText(value).slice(0, 4_000);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "symbol" || typeof value === "function")
    return String(value);
  if (value instanceof Error) return errorLogValue(value, seen);
  if (depth >= 4) return "[truncated]";
  if (seen.has(value)) return "[circular]";
  seen.add(value);

  if (Array.isArray(value)) {
    return value
      .slice(0, 25)
      .map((item) => sanitizedLogValue(item, depth + 1, seen));
  }

  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    const lower = key.toLowerCase();
    if (
      lower.includes("token") ||
      lower.includes("authorization") ||
      lower === "data" ||
      lower === "images"
    ) {
      out[key] = "[REDACTED]";
      continue;
    }
    out[key] = sanitizedLogValue(item, depth + 1, seen);
  }
  return out;
}

function errorLogValue(
  error: Error,
  seen: WeakSet<object>,
): Record<string, unknown> {
  const record = error as Error & Record<string, unknown>;
  return sanitizedLogValue(
    {
      name: error.name,
      message: error.message,
      stack: error.stack,
      code: record.code,
      errno: record.errno,
      syscall: record.syscall,
      address: record.address,
      port: record.port,
    },
    0,
    seen,
  ) as Record<string, unknown>;
}

function writeMirrorLog(
  level: MirrorLogLevel,
  event: string,
  details: Record<string, unknown> = {},
) {
  try {
    const path = mirrorLogPath();
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    appendFileSync(
      path,
      `${JSON.stringify({
        ts: new Date().toISOString(),
        level,
        event,
        ...(sanitizedLogValue(details) as Record<string, unknown>),
      })}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
  } catch {
    // Logging must never leak into the TUI or affect the Pi session.
  }
}

function readSettingsFile(): Record<string, unknown> {
  return readJsonFile(settingsPath());
}

function localHostForConfig(host: unknown): string {
  const value = typeof host === "string" ? host.trim() : "";
  if (!value || value === "0.0.0.0" || value === "::" || value === "[::]") {
    return "127.0.0.1";
  }
  return value;
}

function normalizeWorkspaceCreationMode(
  value: unknown,
): OppiMirrorWorkspaceCreationMode | undefined {
  if (typeof value === "boolean") return value ? "always" : "never";
  if (typeof value !== "string") return undefined;
  const mode = value.trim().toLowerCase();
  if (mode === "ask" || mode === "always" || mode === "never") {
    return mode;
  }
  return undefined;
}

function autoDiscoverOppiSettings(): Partial<OppiMirrorSettings> {
  const config = readJsonFile(oppiConfigPath()) as {
    host?: unknown;
    port?: unknown;
    tls?: { mode?: unknown };
    token?: unknown;
  };
  const token = typeof config.token === "string" ? config.token.trim() : "";
  const port =
    typeof config.port === "number" || typeof config.port === "string"
      ? String(config.port)
      : "";
  if (!token || !port) return {};

  const scheme = config.tls?.mode === "disabled" ? "http" : "https";
  const host = localHostForConfig(config.host);
  return { serverUrl: `${scheme}://${host}:${port}`, token };
}

function loadSettings(): OppiMirrorSettings {
  const parsed = readSettingsFile() as { oppiMirror?: OppiMirrorSettings };
  const fileSettings = parsed.oppiMirror ?? {};
  const discovered = autoDiscoverOppiSettings();
  const autoStartEnv = process.env.OPPI_MIRROR_AUTO_START?.toLowerCase();
  const envAutoStart =
    autoStartEnv === undefined
      ? undefined
      : autoStartEnv === "1" ||
        autoStartEnv === "true" ||
        autoStartEnv === "yes";
  const workspaceCreation =
    normalizeWorkspaceCreationMode(
      process.env.OPPI_MIRROR_WORKSPACE_CREATION,
    ) ??
    normalizeWorkspaceCreationMode(fileSettings.workspaceCreation) ??
    "ask";

  return {
    serverUrl:
      process.env.OPPI_MIRROR_URL ||
      fileSettings.serverUrl ||
      discovered.serverUrl,
    token:
      process.env.OPPI_MIRROR_TOKEN || fileSettings.token || discovered.token,
    // Installing/enabling the extension is the opt-in. Mirror automatically unless explicitly disabled.
    autoStart: envAutoStart ?? fileSettings.autoStart !== false,
    workspaceCreation,
  };
}

function isLocalUrl(urlText: string): boolean {
  try {
    const host = new URL(urlText).hostname;
    return host === "localhost" || host === "127.0.0.1" || host === "::1";
  } catch {
    return false;
  }
}

function isInteractiveTerminalProcess(): boolean {
  return Boolean(process.stdin.isTTY && process.stdout.isTTY);
}

function bridgeUrl(serverUrl: string): string {
  const url = new URL(serverUrl);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.pathname = "/mirror/v1/bridge";
  url.search = "";
  return url.toString();
}

function modelWire(ctx: ExtensionContext) {
  const model = ctx.model;
  if (!model) return null;
  return { provider: model.provider, id: model.id };
}

function contextUsageWire(ctx: ExtensionContext) {
  const usage = ctx.getContextUsage();
  if (!usage) return null;
  return {
    tokens: usage.tokens,
    contextWindow: usage.contextWindow,
  };
}

type MirrorSessionTreeFilterMode =
  | "default"
  | "no-tools"
  | "user-only"
  | "labeled-only"
  | "all";

interface MirrorSessionTreeEntry {
  id: string;
  parentId?: string | null;
  type: string;
  timestamp?: string;
  message?: unknown;
  tokensBefore?: unknown;
  summary?: unknown;
  content?: unknown;
  name?: unknown;
  modelId?: unknown;
  thinkingLevel?: unknown;
  label?: unknown;
}

interface MirrorSessionTreeNode {
  entry: MirrorSessionTreeEntry;
  children: MirrorSessionTreeNode[];
  label?: string;
}

interface MirrorSessionTreeNodeSnapshot {
  id: string;
  parentId: string | null;
  type: string;
  timestamp: string;
  depth: number;
  isLeafPath: boolean;
  defaultVisible: boolean;
  matchesFilter: boolean;
  role?: string;
  textPreview?: string;
  label?: string;
}

interface MirrorSessionTreeContext {
  sessionManager: {
    getTree: () => MirrorSessionTreeNode[];
    getLeafId: () => string | null;
  };
}

interface MirrorTreeToolCallSnapshot {
  name: string;
  arguments: Record<string, unknown>;
}

const MIRROR_TREE_MAX_TEXT_PREVIEW_CHARS = 160;
const MIRROR_TREE_MAX_PREVIEW_SOURCE_CHARS = 4_000;
const MIRROR_TREE_DEFAULT_HIDDEN_ENTRY_TYPES = new Set([
  "label",
  "custom",
  "model_change",
  "thinking_level_change",
  "session_info",
]);

function treeRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : {};
}

function readOptionalTreeString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readMirrorSessionTreeFilterMode(
  value: unknown,
): MirrorSessionTreeFilterMode {
  switch (readOptionalTreeString(value)) {
    case undefined:
    case "default":
      return "default";
    case "no-tools":
      return "no-tools";
    case "user-only":
      return "user-only";
    case "labeled-only":
      return "labeled-only";
    case "all":
      return "all";
    default:
      throw new Error(
        "Invalid payload: expected filterMode to be one of default, no-tools, user-only, labeled-only, all",
      );
  }
}

function compareMirrorTreeNodes(
  left: MirrorSessionTreeNode,
  right: MirrorSessionTreeNode,
): number {
  const leftTimestamp = left.entry.timestamp ?? "";
  const rightTimestamp = right.entry.timestamp ?? "";
  const leftTime = Date.parse(leftTimestamp);
  const rightTime = Date.parse(rightTimestamp);

  if (
    !Number.isNaN(leftTime) &&
    !Number.isNaN(rightTime) &&
    leftTime !== rightTime
  ) {
    return leftTime - rightTime;
  }

  if (leftTimestamp !== rightTimestamp) {
    return leftTimestamp.localeCompare(rightTimestamp);
  }

  return left.entry.id.localeCompare(right.entry.id);
}

function sortMirrorTreeNodes(
  nodes: MirrorSessionTreeNode[],
  leafPathIds: Set<string>,
): MirrorSessionTreeNode[] {
  return [...nodes].sort((left, right) => {
    const leftOnActivePath = leafPathIds.has(left.entry.id) ? 1 : 0;
    const rightOnActivePath = leafPathIds.has(right.entry.id) ? 1 : 0;

    if (leftOnActivePath !== rightOnActivePath) {
      return rightOnActivePath - leftOnActivePath;
    }

    return compareMirrorTreeNodes(left, right);
  });
}

function collectMirrorTreeEntries(
  tree: MirrorSessionTreeNode[],
): Map<string, MirrorSessionTreeEntry> {
  const entries = new Map<string, MirrorSessionTreeEntry>();
  const stack = [...tree];
  while (stack.length > 0) {
    const node = stack.pop();
    if (!node) continue;
    entries.set(node.entry.id, node.entry);
    for (const child of node.children) stack.push(child);
  }
  return entries;
}

function collectMirrorLeafPathIds(
  entries: Map<string, MirrorSessionTreeEntry>,
  leafId: string | null,
): Set<string> {
  const pathIds = new Set<string>();
  let currentId = leafId;

  while (currentId) {
    if (pathIds.has(currentId)) break;
    pathIds.add(currentId);
    currentId = entries.get(currentId)?.parentId ?? null;
  }

  return pathIds;
}

function previewTreeText(rawText: string): string | undefined {
  const source = rawText.slice(0, MIRROR_TREE_MAX_PREVIEW_SOURCE_CHARS);
  const normalized = source.replace(/\s+/g, " ").trim();
  if (normalized.length === 0) return undefined;
  if (normalized.length <= MIRROR_TREE_MAX_TEXT_PREVIEW_CHARS)
    return normalized;
  return `${normalized.slice(0, MIRROR_TREE_MAX_TEXT_PREVIEW_CHARS - 1)}…`;
}

function extractMirrorDisplayTextFromContent(content: unknown): string {
  if (typeof content === "string") {
    return content.slice(0, MIRROR_TREE_MAX_PREVIEW_SOURCE_CHARS);
  }

  if (!Array.isArray(content)) return "";

  let text = "";
  for (const block of content) {
    const record = treeRecord(block);
    if (
      (record.type === "text" || record.type === "output_text") &&
      typeof record.text === "string"
    ) {
      text += `${record.text} `;
      if (text.length >= MIRROR_TREE_MAX_PREVIEW_SOURCE_CHARS) {
        return text.slice(0, MIRROR_TREE_MAX_PREVIEW_SOURCE_CHARS);
      }
    }
  }
  return text;
}

function hasMirrorDisplayTextContent(content: unknown): boolean {
  return (
    previewTreeText(extractMirrorDisplayTextFromContent(content)) !== undefined
  );
}

function shortenMirrorTreePath(path: string): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  if (home && path.startsWith(home)) return `~${path.slice(home.length)}`;
  return path;
}

function compactTreePreviewValue(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return value.slice(0, 120);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (depth >= 2) return "[truncated]";
  if (Array.isArray(value))
    return value
      .slice(0, 3)
      .map((item) => compactTreePreviewValue(item, depth + 1));
  if (typeof value !== "object") return String(value);

  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value).slice(0, 5)) {
    out[key] = compactTreePreviewValue(item, depth + 1);
  }
  return out;
}

function formatMirrorTreeToolCall(
  name: string,
  args: Record<string, unknown>,
): string {
  switch (name) {
    case "read": {
      const path = shortenMirrorTreePath(String(args.path || ""));
      const offset = args.offset;
      const limit = args.limit;
      let display = path;
      if (offset !== undefined || limit !== undefined) {
        const start = typeof offset === "number" ? offset : 1;
        const limitNumber = typeof limit === "number" ? limit : undefined;
        const end = limitNumber !== undefined ? start + limitNumber - 1 : "";
        display += `:${start}${end ? `-${end}` : ""}`;
      }
      return `[read: ${display}]`;
    }

    case "write":
      return `[write: ${shortenMirrorTreePath(String(args.path || ""))}]`;

    case "edit":
      return `[edit: ${shortenMirrorTreePath(String(args.path || ""))}]`;

    case "bash": {
      const rawCommand = String(args.command || "");
      const command = rawCommand
        .replace(/[\n\t]/g, " ")
        .trim()
        .slice(0, 50);
      return `[bash: ${command}${rawCommand.length > 50 ? "..." : ""}]`;
    }

    case "grep":
      return `[grep: /${String(args.pattern || "")}/ in ${shortenMirrorTreePath(String(args.path || "."))}]`;

    case "find":
      return `[find: ${String(args.pattern || "")} in ${shortenMirrorTreePath(String(args.path || "."))}]`;

    case "ls":
      return `[ls: ${shortenMirrorTreePath(String(args.path || "."))}]`;

    default: {
      const argsJson = JSON.stringify(compactTreePreviewValue(args));
      const preview = argsJson.slice(0, 40);
      return `[${name}: ${preview}${argsJson.length > 40 ? "..." : ""}]`;
    }
  }
}

function collectMirrorTreeToolCalls(
  tree: MirrorSessionTreeNode[],
): Map<string, MirrorTreeToolCallSnapshot> {
  const toolCalls = new Map<string, MirrorTreeToolCallSnapshot>();
  const stack = [...tree];

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    const entry = current.entry;
    if (entry.type === "message") {
      const message = treeRecord(entry.message);
      if (message.role === "assistant" && Array.isArray(message.content)) {
        for (const block of message.content) {
          const record = treeRecord(block);
          if (
            record.type === "toolCall" &&
            typeof record.id === "string" &&
            typeof record.name === "string"
          ) {
            toolCalls.set(record.id, {
              name: record.name,
              arguments: treeRecord(record.arguments),
            });
          }
        }
      }
    }

    for (const child of current.children) stack.push(child);
  }

  return toolCalls;
}

function isMirrorTreeEntryEligible(
  entry: MirrorSessionTreeEntry,
  leafId: string | null,
): boolean {
  if (entry.type !== "message" || entry.id === leafId) return true;

  const message = treeRecord(entry.message);
  if (message.role !== "assistant") return true;

  const hasText = hasMirrorDisplayTextContent(message.content);
  const stopReason =
    typeof message.stopReason === "string" ? message.stopReason : undefined;
  const isErrorOrAborted =
    stopReason !== undefined &&
    stopReason !== "stop" &&
    stopReason !== "toolUse";

  return hasText || isErrorOrAborted;
}

function isMirrorTreeEntryDefaultVisible(
  entry: MirrorSessionTreeEntry,
  leafId: string | null,
): boolean {
  return (
    isMirrorTreeEntryEligible(entry, leafId) &&
    !MIRROR_TREE_DEFAULT_HIDDEN_ENTRY_TYPES.has(entry.type)
  );
}

function mirrorTreeNodeMatchesFilter(
  node: MirrorSessionTreeNode,
  filterMode: MirrorSessionTreeFilterMode,
  leafId: string | null,
): boolean {
  if (!isMirrorTreeEntryEligible(node.entry, leafId)) return false;

  const entry = node.entry;
  const isSettingsEntry = MIRROR_TREE_DEFAULT_HIDDEN_ENTRY_TYPES.has(
    entry.type,
  );
  switch (filterMode) {
    case "user-only":
      return (
        entry.type === "message" && treeRecord(entry.message).role === "user"
      );
    case "no-tools":
      return (
        !isSettingsEntry &&
        !(
          entry.type === "message" &&
          treeRecord(entry.message).role === "toolResult"
        )
      );
    case "labeled-only":
      return node.label !== undefined;
    case "all":
      return true;
    case "default":
    default:
      return !isSettingsEntry;
  }
}

function extractMirrorTreeNodeSnapshot(
  entry: MirrorSessionTreeEntry,
  toolCalls: Map<string, MirrorTreeToolCallSnapshot>,
  leafId: string | null,
): { defaultVisible: boolean; role?: string; textPreview?: string } {
  const defaultVisible = isMirrorTreeEntryDefaultVisible(entry, leafId);

  switch (entry.type) {
    case "message": {
      const message = treeRecord(entry.message);
      const role = typeof message.role === "string" ? message.role : undefined;
      let textPreview: string | undefined;

      switch (role) {
        case "toolResult": {
          const toolCallId =
            typeof message.toolCallId === "string"
              ? message.toolCallId
              : undefined;
          const toolCall = toolCallId ? toolCalls.get(toolCallId) : undefined;
          textPreview = toolCall
            ? formatMirrorTreeToolCall(toolCall.name, toolCall.arguments)
            : typeof message.toolName === "string"
              ? `[${message.toolName}]`
              : undefined;
          break;
        }
        case "bashExecution":
          textPreview = previewTreeText(String(message.command || ""));
          break;
        default:
          textPreview = previewTreeText(
            extractMirrorDisplayTextFromContent(message.content),
          );
          break;
      }

      return {
        defaultVisible,
        ...(role ? { role } : {}),
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "compaction":
      return {
        defaultVisible,
        textPreview:
          typeof entry.tokensBefore === "number"
            ? `${Math.round(entry.tokensBefore / 1000)}k tokens`
            : undefined,
      };

    case "branch_summary": {
      const textPreview = previewTreeText(String(entry.summary || ""));
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    case "custom_message": {
      const rawContent =
        typeof entry.content === "string"
          ? entry.content
          : extractMirrorDisplayTextFromContent(entry.content);
      const textPreview = previewTreeText(rawContent);
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    case "session_info": {
      const textPreview = previewTreeText(String(entry.name || ""));
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    case "model_change": {
      const textPreview = previewTreeText(String(entry.modelId || ""));
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    case "thinking_level_change": {
      const textPreview = previewTreeText(String(entry.thinkingLevel || ""));
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    case "label": {
      const textPreview = previewTreeText(String(entry.label || ""));
      return { defaultVisible, ...(textPreview ? { textPreview } : {}) };
    }

    default:
      return { defaultVisible };
  }
}

export function sessionTreeWire(
  ctx: MirrorSessionTreeContext,
  filterModeValue: unknown = "default",
): { leafId: string | null; nodes: MirrorSessionTreeNodeSnapshot[] } {
  const filterMode = readMirrorSessionTreeFilterMode(filterModeValue);
  const tree = ctx.sessionManager.getTree();
  const leafId = ctx.sessionManager.getLeafId();
  const entries = collectMirrorTreeEntries(tree);
  const leafPathIds = collectMirrorLeafPathIds(entries, leafId);
  const toolCalls = collectMirrorTreeToolCalls(tree);
  const nodes: MirrorSessionTreeNodeSnapshot[] = [];
  const stack = sortMirrorTreeNodes(tree, leafPathIds)
    .reverse()
    .map((node) => ({ node, depth: 0 }));

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    const extracted = extractMirrorTreeNodeSnapshot(
      current.node.entry,
      toolCalls,
      leafId,
    );
    nodes.push({
      id: current.node.entry.id,
      parentId: current.node.entry.parentId ?? null,
      type: current.node.entry.type,
      timestamp: current.node.entry.timestamp ?? "",
      depth: current.depth,
      isLeafPath: leafPathIds.has(current.node.entry.id),
      matchesFilter: mirrorTreeNodeMatchesFilter(
        current.node,
        filterMode,
        leafId,
      ),
      ...extracted,
      ...(current.node.label ? { label: current.node.label } : {}),
    });

    const children = sortMirrorTreeNodes(current.node.children, leafPathIds);
    for (let i = children.length - 1; i >= 0; i -= 1) {
      const child = children[i];
      if (child) stack.push({ node: child, depth: current.depth + 1 });
    }
  }

  return { leafId, nodes };
}

function queueId(): string {
  return `mirror_q_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

function cloneQueueItem(item: MessageQueueItem): MessageQueueItem {
  return {
    id: item.id,
    message: item.message,
    ...(item.images
      ? { images: item.images.map((image) => ({ ...image })) }
      : {}),
    createdAt: item.createdAt,
  };
}

function cloneQueueState(queue: MessageQueueState): MessageQueueState {
  return {
    version: queue.version,
    steering: queue.steering.map(cloneQueueItem),
    followUp: queue.followUp.map(cloneQueueItem),
  };
}

function draftToItem(item: MessageQueueDraftItem): MessageQueueItem {
  return {
    id: item.id?.trim() || queueId(),
    message: item.message,
    ...(item.images
      ? { images: item.images.map((image) => ({ ...image })) }
      : {}),
    createdAt: item.createdAt ?? Date.now(),
  };
}

function itemsFromTexts(
  texts: readonly string[],
  previous: MessageQueueItem[],
): MessageQueueItem[] {
  const used = new Set<number>();
  return texts.map((message) => {
    const previousIndex = previous.findIndex(
      (item, index) => !used.has(index) && item.message === message,
    );
    if (previousIndex !== -1) {
      used.add(previousIndex);
      return cloneQueueItem(previous[previousIndex]!);
    }
    return draftToItem({ message });
  });
}

function queueTextMatches(
  queue: MessageQueueState,
  steering: readonly string[],
  followUp: readonly string[],
): boolean {
  const messagesMatch = (items: MessageQueueItem[], texts: readonly string[]) =>
    items.length === texts.length &&
    items.every((item, index) => item.message === texts[index]);
  return (
    messagesMatch(queue.steering, steering) &&
    messagesMatch(queue.followUp, followUp)
  );
}

type RuntimeQueueSnapshot = {
  steering: readonly string[];
  followUp: readonly string[];
};

type ProjectionChange = {
  changed: boolean;
  queue: MessageQueueState;
};

type ProjectionStartedItem = {
  kind: "steer" | "follow_up";
  item: MessageQueueItem;
  queueVersion: number;
  queue: MessageQueueState;
};

export class MirrorQueueProjection {
  private queue: MessageQueueState;

  constructor(
    initialQueue: MessageQueueState = {
      version: 0,
      steering: [],
      followUp: [],
    },
  ) {
    this.queue = cloneQueueState(initialQueue);
  }

  snapshot(): MessageQueueState {
    return cloneQueueState(this.queue);
  }

  pendingCount(): number {
    return this.queue.steering.length + this.queue.followUp.length;
  }

  reconcileRuntimeSnapshot(snapshot: RuntimeQueueSnapshot): ProjectionChange {
    if (queueTextMatches(this.queue, snapshot.steering, snapshot.followUp)) {
      return { changed: false, queue: this.snapshot() };
    }

    this.queue = {
      version: this.queue.version + 1,
      steering: itemsFromTexts(snapshot.steering, this.queue.steering),
      followUp: itemsFromTexts(snapshot.followUp, this.queue.followUp),
    };
    return { changed: true, queue: this.snapshot() };
  }

  replace(nextQueue: MessageQueueState): ProjectionChange {
    const changed = JSON.stringify(this.queue) !== JSON.stringify(nextQueue);
    this.queue = cloneQueueState(nextQueue);
    return { changed, queue: this.snapshot() };
  }

  clear(): ProjectionChange {
    if (this.queue.steering.length === 0 && this.queue.followUp.length === 0) {
      return { changed: false, queue: this.snapshot() };
    }

    this.queue = {
      version: this.queue.version + 1,
      steering: [],
      followUp: [],
    };
    return { changed: true, queue: this.snapshot() };
  }

  queueFromDrafts(
    baseVersion: number,
    steering: MessageQueueDraftItem[],
    followUp: MessageQueueDraftItem[],
  ): MessageQueueState {
    return {
      version:
        Math.max(
          this.queue.version,
          Number.isFinite(baseVersion) ? baseVersion : 0,
        ) + 1,
      steering: steering.map(draftToItem),
      followUp: followUp.map(draftToItem),
    };
  }

  enqueueOptimistic(
    kind: "steer" | "follow_up",
    message: string,
    images?: QueueImageContent[],
    options: { previousMatchingCount?: number } = {},
  ): ProjectionChange {
    const item: MessageQueueItem = {
      id: queueId(),
      message,
      ...(images?.length
        ? { images: images.map((image) => ({ ...image })) }
        : {}),
      createdAt: Date.now(),
    };
    const list = kind === "steer" ? this.queue.steering : this.queue.followUp;
    const matchingItems = list.filter(
      (candidate) => candidate.message === message,
    );
    const runtimeUpdateAlreadyAddedItem =
      options.previousMatchingCount !== undefined &&
      matchingItems.length > options.previousMatchingCount;

    if (runtimeUpdateAlreadyAddedItem) {
      const existing = matchingItems.at(-1);
      if (existing && images?.length && !existing.images?.length) {
        existing.images = images.map((image) => ({ ...image }));
        this.queue.version += 1;
        return { changed: true, queue: this.snapshot() };
      }
      return { changed: false, queue: this.snapshot() };
    }

    list.push(item);
    this.queue.version += 1;
    return { changed: true, queue: this.snapshot() };
  }

  markStarted(message: string | undefined): ProjectionStartedItem | null {
    const normalized = message?.trim();
    if (!normalized) return null;

    const dequeue = (
      kind: "steer" | "follow_up",
      list: MessageQueueItem[],
    ): ProjectionStartedItem | null => {
      const index = list.findIndex(
        (item) => item.message.trim() === normalized,
      );
      if (index === -1) return null;
      const [item] = list.splice(index, 1);
      if (!item) return null;
      this.queue.version += 1;
      return {
        kind,
        item: cloneQueueItem(item),
        queueVersion: this.queue.version,
        queue: this.snapshot(),
      };
    };

    return (
      dequeue("steer", this.queue.steering) ??
      dequeue("follow_up", this.queue.followUp)
    );
  }
}

function getQueueUpdateBridge(): QueueUpdateBridge {
  const globalRecord = globalThis as typeof globalThis & {
    [QUEUE_UPDATE_BRIDGE_KEY]?: QueueUpdateBridge;
  };
  globalRecord[QUEUE_UPDATE_BRIDGE_KEY] ??= {
    listeners: new Set<QueueUpdateListener>(),
    internalEventListeners: new Set<InternalAgentSessionEventListener>(),
    sessions: new Map<string, EditableAgentSession>(),
    installed: false,
  };
  const bridge = globalRecord[QUEUE_UPDATE_BRIDGE_KEY];
  bridge.internalEventListeners ??=
    new Set<InternalAgentSessionEventListener>();
  return bridge;
}

function sessionIdFromAgentSession(
  session: EditableAgentSession,
): string | undefined {
  return session.sessionId ?? session.sessionManager?.getSessionId?.();
}

function rememberAgentSession(
  bridge: QueueUpdateBridge,
  session: EditableAgentSession,
): string | undefined {
  bridge.lastSession = session;
  const sessionId = sessionIdFromAgentSession(session);
  if (sessionId) bridge.sessions.set(sessionId, session);
  return sessionId;
}

function isInternalAgentSessionEvent(
  event: unknown,
): event is InternalAgentSessionEvent {
  if (!event || typeof event !== "object") return false;
  const type = (event as { type?: AgentSessionEvent["type"] }).type;
  return type !== undefined && INTERNAL_AGENT_SESSION_EVENT_TYPES.has(type);
}

function userMessageFromQueueItem(item: MessageQueueItem) {
  const text = item.message || "(empty queued message)";
  return {
    role: "user" as const,
    content: [
      { type: "text" as const, text },
      ...(item.images ?? []).map((image) => ({
        type: "image" as const,
        data: image.data,
        mimeType: image.mimeType,
      })),
    ],
    timestamp: item.createdAt || Date.now(),
  };
}

function clearAgentSessionQueue(session: EditableAgentSession) {
  const agent = session.agent;
  const canClear =
    agent?.clearAllQueues ||
    (agent?.clearSteeringQueue && agent.clearFollowUpQueue);
  if (!agent || !canClear) {
    throw new Error("Terminal Pi runtime queue is not editable");
  }

  if (agent.clearAllQueues) {
    agent.clearAllQueues();
  } else {
    agent.clearSteeringQueue?.();
    agent.clearFollowUpQueue?.();
  }

  session._steeringMessages = [];
  session._followUpMessages = [];
  session._emitQueueUpdate?.();
}

function replaceAgentSessionQueue(
  session: EditableAgentSession,
  nextQueue: MessageQueueState,
) {
  const agent = session.agent;
  if (!agent?.steer || !agent.followUp) {
    throw new Error("Terminal Pi runtime queue is not editable");
  }

  clearAgentSessionQueue(session);

  session._steeringMessages = nextQueue.steering.map((item) => item.message);
  session._followUpMessages = nextQueue.followUp.map((item) => item.message);
  for (const item of nextQueue.steering) {
    agent.steer(userMessageFromQueueItem(item));
  }
  for (const item of nextQueue.followUp) {
    agent.followUp(userMessageFromQueueItem(item));
  }

  session._emitQueueUpdate?.();
}

function installQueueUpdateBridge(prototype: AgentSessionPrototype) {
  const bridge = getQueueUpdateBridge();

  // Pi updates the TUI queue through AgentSession listeners, but does not yet
  // expose queue_update as an extension event. Patch the internal emitter so
  // terminal-origin follow-up/steering edits reach the Oppi mirror immediately.

  if (!bridge.installed) {
    const originalBindExtensions = prototype.bindExtensions;
    if (typeof originalBindExtensions === "function") {
      prototype.bindExtensions = function patchedBindExtensions(
        this: unknown,
        ...args: unknown[]
      ) {
        rememberAgentSession(bridge, this as EditableAgentSession);
        return originalBindExtensions.apply(this, args);
      };
    }

    const original = prototype._emitQueueUpdate;
    if (typeof original === "function") {
      prototype._emitQueueUpdate = function patchedEmitQueueUpdate(
        this: unknown,
        ...args: unknown[]
      ) {
        const result = original.apply(this, args);
        const record = this as EditableAgentSession & {
          getSteeringMessages?: () => readonly string[];
          getFollowUpMessages?: () => readonly string[];
        };
        const steering = Array.from(
          record.getSteeringMessages?.() ?? record._steeringMessages ?? [],
        );
        const followUp = Array.from(
          record.getFollowUpMessages?.() ?? record._followUpMessages ?? [],
        );
        const sessionId = rememberAgentSession(bridge, record);
        const event = { steering, followUp, session: record, sessionId };
        bridge.last = event;
        for (const listener of bridge.listeners) {
          try {
            listener(event);
          } catch (error) {
            writeMirrorLog("warn", "queue_update_listener_failed", { error });
          }
        }
        return result;
      };
    }
    bridge.installed = true;
  }

  if (!bridge.internalEventInstalled) {
    const originalEmit = prototype._emit;
    if (typeof originalEmit === "function") {
      prototype._emit = function patchedEmit(
        this: unknown,
        event: unknown,
        ...args: unknown[]
      ) {
        const result = originalEmit.apply(this, [event, ...args]);
        if (isInternalAgentSessionEvent(event)) {
          rememberAgentSession(bridge, this as EditableAgentSession);
          for (const listener of bridge.internalEventListeners) {
            try {
              listener(event);
            } catch (error) {
              writeMirrorLog("warn", "internal_event_listener_failed", {
                error,
              });
            }
          }
        }
        return result;
      };
    }
    bridge.internalEventInstalled = true;
  }

  return bridge;
}

function textFromUserMessage(message: unknown): string | undefined {
  if (!message || typeof message !== "object") return undefined;
  const content = (message as { content?: unknown }).content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return undefined;
  return content
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      const item = block as { type?: unknown; text?: unknown };
      return item.type === "text" && typeof item.text === "string"
        ? item.text
        : "";
    })
    .join("")
    .trim();
}

function stateSnapshot(pi: ExtensionAPI, ctx: ExtensionContext) {
  return {
    cwd: ctx.cwd,
    sessionFile: ctx.sessionManager.getSessionFile(),
    piSessionId: ctx.sessionManager.getSessionId(),
    sessionName: ctx.sessionManager.getSessionName?.() ?? undefined,
    leafId: ctx.sessionManager.getLeafId(),
    model: modelWire(ctx),
    thinkingLevel: pi.getThinkingLevel(),
    isIdle: ctx.isIdle(),
    contextUsage: contextUsageWire(ctx),
  };
}

type MirrorStateSnapshot = ReturnType<typeof stateSnapshot>;

function isStaleExtensionContextError(error: unknown): boolean {
  return (
    error instanceof Error && error.message.includes("extension ctx is stale")
  );
}

function safeStateSnapshot(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
): MirrorStateSnapshot | undefined {
  try {
    return stateSnapshot(pi, ctx);
  } catch (error) {
    if (isStaleExtensionContextError(error)) return undefined;
    throw error;
  }
}

function commandError(message: string, id: string, error: unknown) {
  return {
    type: "command_result",
    id,
    success: false,
    error: error instanceof Error ? error.message : String(error),
  };
}

function commandLogDetails(
  command: Record<string, unknown>,
): Record<string, unknown> {
  const images = Array.isArray(command.images) ? command.images : [];
  return {
    commandType: typeof command.type === "string" ? command.type : "unknown",
    requestId:
      typeof command.requestId === "string" ? command.requestId : undefined,
    clientTurnId:
      typeof command.clientTurnId === "string"
        ? command.clientTurnId
        : undefined,
    messageChars:
      typeof command.message === "string" ? command.message.length : undefined,
    imageCount: images.length,
    streamingBehavior:
      typeof command.streamingBehavior === "string"
        ? command.streamingBehavior
        : undefined,
  };
}

function imagesFromCommand(value: unknown): QueueImageContent[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((image) => {
    const item = image as { data?: unknown; mimeType?: unknown };
    return typeof item.data === "string"
      ? [
          {
            data: item.data,
            mimeType:
              typeof item.mimeType === "string" ? item.mimeType : "image/png",
          },
        ]
      : [];
  });
}

function contentForMessage(message: string, images: QueueImageContent[]) {
  if (!images.length) return message;
  return [
    {
      type: "text" as const,
      text: message || "(see attached image)",
    },
    ...images.map((image) => ({
      type: "image" as const,
      data: image.data,
      mimeType: image.mimeType,
    })),
  ];
}

type MirrorIndicatorMode =
  | "connecting"
  | "live"
  | "reconnecting"
  | "blocked"
  | "error";
type MirrorIndicatorColor = "success" | "error" | "warning" | "muted";

type MirrorExtensionUIMethod =
  | "ask"
  | "select"
  | "confirm"
  | "input"
  | "editor";

interface NativeRenderContext {
  target: "oppi-native-v1";
  capabilities: string[];
  locale?: string;
}

interface MirrorWidgetComponent {
  render(width: number): string[];
  renderNative?(context: NativeRenderContext): unknown;
  invalidate?(): void;
  dispose?(): void;
}

export interface MirrorAskOption {
  value: string;
  label: string;
  description?: string;
}

export interface MirrorAskQuestion {
  id: string;
  question: string;
  options: MirrorAskOption[];
  multiSelect?: boolean;
}

export interface MirrorAskUIResult {
  answers: Record<string, string | string[]>;
  allIgnored: boolean;
}

export type MirrorAskFunction = (
  questions: MirrorAskQuestion[],
  allowCustom?: boolean,
  opts?: ExtensionUIDialogOptions,
) => Promise<MirrorAskUIResult>;

export type MirrorOptionalUIContext = Partial<ExtensionUIContext> & {
  ask?: MirrorAskFunction;
};

export function bindMirrorOptionalUIContext(ui: MirrorOptionalUIContext) {
  const originalSelect =
    typeof ui.select === "function" ? ui.select.bind(ui) : undefined;
  const originalInput =
    typeof ui.input === "function" ? ui.input.bind(ui) : undefined;
  return {
    ask:
      typeof ui.ask === "function"
        ? ui.ask.bind(ui)
        : originalSelect && originalInput
          ? (
              questions: MirrorAskQuestion[],
              allowCustom = true,
              opts?: ExtensionUIDialogOptions,
            ) =>
              terminalAskFallback(questions, allowCustom, opts, {
                select: originalSelect,
                input: originalInput,
              })
          : async () => ({ answers: {}, allIgnored: true }),
    select: originalSelect ?? (async () => undefined),
    confirm:
      typeof ui.confirm === "function"
        ? ui.confirm.bind(ui)
        : async () => false,
    input: originalInput ?? (async () => undefined),
    editor:
      typeof ui.editor === "function"
        ? ui.editor.bind(ui)
        : async () => undefined,
    notify: typeof ui.notify === "function" ? ui.notify.bind(ui) : undefined,
    setStatus:
      typeof ui.setStatus === "function" ? ui.setStatus.bind(ui) : undefined,
    setWidget:
      typeof ui.setWidget === "function"
        ? (ui.setWidget.bind(ui) as ExtensionUIContext["setWidget"])
        : undefined,
    setTitle:
      typeof ui.setTitle === "function" ? ui.setTitle.bind(ui) : undefined,
    setEditorText:
      typeof ui.setEditorText === "function"
        ? ui.setEditorText.bind(ui)
        : undefined,
    pasteToEditor:
      typeof ui.pasteToEditor === "function"
        ? ui.pasteToEditor.bind(ui)
        : undefined,
  };
}

const MIRROR_WIDGET_SNAPSHOT_WIDTH = 88;
const MIRROR_WIDGET_SNAPSHOT_MAX_LINES = 12;
const MIRROR_WIDGET_NATIVE_SURFACE_MAX_BYTES = 64 * 1024;

function stripAnsiCodes(input: string): string {
  return input.replace(
    // eslint-disable-next-line no-control-regex
    /[\u001b\u009b][[\]()#;?]*(?:(?:(?:[a-zA-Z\d]*(?:;[a-zA-Z\d]*)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g,
    "",
  );
}

function isMirrorWidgetComponent(
  value: unknown,
): value is MirrorWidgetComponent {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as { render?: unknown }).render === "function"
  );
}

export function snapshotMirrorWidgetLines(component: unknown): string[] {
  if (!isMirrorWidgetComponent(component)) return [];

  let lines: string[];
  try {
    lines = component.render(MIRROR_WIDGET_SNAPSHOT_WIDTH);
  } catch (error) {
    lines = [
      `[render error] ${error instanceof Error ? error.message : String(error)}`,
    ];
  }

  const safeLines = lines
    .map((line) => stripAnsiCodes(String(line)).trimEnd())
    .filter((line) => line.length > 0);
  const limited = safeLines.slice(0, MIRROR_WIDGET_SNAPSHOT_MAX_LINES);
  if (safeLines.length > MIRROR_WIDGET_SNAPSHOT_MAX_LINES) {
    limited.push(
      `… (${safeLines.length - MIRROR_WIDGET_SNAPSHOT_MAX_LINES} more lines)`,
    );
  }
  return limited;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function snapshotMirrorWidgetNativeSurface(
  component: unknown,
): Record<string, unknown> | undefined {
  if (!isMirrorWidgetComponent(component) || !component.renderNative)
    return undefined;

  let value: unknown;
  try {
    value = component.renderNative({
      target: "oppi-native-v1",
      capabilities: [
        "extension-native-ui:v1:text-fallback",
        "extension-native-ui:v1:surface-native",
      ],
    });
  } catch {
    return undefined;
  }

  let json: string | undefined;
  try {
    json = JSON.stringify(value);
  } catch {
    return undefined;
  }

  if (typeof json !== "string") {
    return undefined;
  }

  if (
    Buffer.byteLength(json, "utf8") > MIRROR_WIDGET_NATIVE_SURFACE_MAX_BYTES
  ) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(json);
    return isRecord(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export function createMirrorWidgetForwardingTui(
  tui: unknown,
  onRequestRender: () => void,
): unknown {
  if (typeof tui !== "object" || tui === null) return tui;

  return new Proxy(tui, {
    get(target, property, receiver) {
      if (property !== "requestRender") {
        return Reflect.get(target, property, receiver);
      }

      const originalRequestRender = Reflect.get(target, property, receiver);
      return (...args: unknown[]) => {
        if (typeof originalRequestRender === "function") {
          originalRequestRender.apply(target, args);
        }
        onRequestRender();
      };
    },
  });
}

export function createMirrorWidgetForwardingComponent(
  component: unknown,
  onInvalidate: () => void,
  onDispose: () => void,
): unknown {
  if (typeof component !== "object" || component === null) return component;

  return new Proxy(component, {
    get(target, property, receiver) {
      const original = Reflect.get(target, property, receiver);
      if (property === "invalidate") {
        return (...args: unknown[]) => {
          if (typeof original === "function") {
            original.apply(target, args);
          }
          onInvalidate();
        };
      }
      if (property === "dispose") {
        return (...args: unknown[]) => {
          try {
            if (typeof original === "function") {
              original.apply(target, args);
            }
          } finally {
            onDispose();
          }
        };
      }
      return original;
    },
  });
}

const TOOL_TUI_RENDER_VERSION = 1;
const TOOL_TUI_RENDER_SOURCE = "renderResult";
const TOOL_TUI_RENDER_WIDTH = 80;
const TOOL_TUI_RENDER_MAX_LINES = 500;
const TOOL_TUI_RENDER_MAX_CHARS = 80_000;
const TOOL_TUI_RENDER_NATIVE_TOOL_NAMES = new Set([
  "bash",
  "read",
  "write",
  "edit",
  "ask",
]);

interface ToolTuiRenderSnapshot {
  version: typeof TOOL_TUI_RENDER_VERSION;
  source: typeof TOOL_TUI_RENDER_SOURCE;
  width: number;
  expandedText: string;
  truncated?: boolean;
}

interface ToolTuiRenderContextSnapshot {
  args: Record<string, unknown>;
  toolCallId: string;
  invalidate: () => void;
  lastComponent: MirrorWidgetComponent | undefined;
  state: unknown;
  cwd: string;
  executionStarted: boolean;
  argsComplete: boolean;
  isPartial: boolean;
  expanded: boolean;
  showImages: boolean;
  isError: boolean;
}

type ToolTuiResultRenderer = (
  result: AgentToolResult<unknown>,
  options: ToolRenderResultOptions,
  theme: unknown,
  context: ToolTuiRenderContextSnapshot,
) => MirrorWidgetComponent;

function isToolTuiRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shouldAttachToolTuiRenderSnapshot(toolName: string): boolean {
  return !TOOL_TUI_RENDER_NATIVE_TOOL_NAMES.has(toolName.trim().toLowerCase());
}

function trimToolTuiRenderLines(lines: string[]): string[] {
  let start = 0;
  let end = lines.length;
  while (start < end && stripAnsiCodes(lines[start] ?? "").trim().length === 0)
    start++;
  while (
    end > start &&
    stripAnsiCodes(lines[end - 1] ?? "").trim().length === 0
  )
    end--;
  return lines.slice(start, end);
}

function limitToolTuiRenderLines(lines: string[]): {
  lines: string[];
  truncated: boolean;
} {
  if (lines.length <= TOOL_TUI_RENDER_MAX_LINES) {
    return { lines, truncated: false };
  }
  return {
    lines: [...lines.slice(0, TOOL_TUI_RENDER_MAX_LINES), "… truncated …"],
    truncated: true,
  };
}

function renderToolTuiResultSnapshot(options: {
  toolDefinition: Pick<ToolDefinition, "renderResult">;
  toolCallId?: string;
  content: unknown[];
  details: unknown;
  isError: boolean;
  args?: Record<string, unknown>;
  cwd: string;
  theme: unknown;
}): ToolTuiRenderSnapshot | undefined {
  const renderResult = options.toolDefinition.renderResult as
    | ToolTuiResultRenderer
    | undefined;
  if (!renderResult) return undefined;

  const agentToolResult = {
    content: options.content as AgentToolResult<unknown>["content"],
    details: options.details,
  } satisfies AgentToolResult<unknown>;
  const context: ToolTuiRenderContextSnapshot = {
    args: options.args ?? {},
    toolCallId: options.toolCallId ?? "",
    invalidate: () => {},
    lastComponent: undefined,
    state: {},
    cwd: options.cwd,
    executionStarted: true,
    argsComplete: true,
    isPartial: false,
    expanded: true,
    showImages: false,
    isError: options.isError,
  };
  const component = renderResult(
    agentToolResult,
    { expanded: true, isPartial: false },
    options.theme,
    context,
  );
  if (!isMirrorWidgetComponent(component)) return undefined;

  const limited = limitToolTuiRenderLines(
    trimToolTuiRenderLines(component.render(TOOL_TUI_RENDER_WIDTH)),
  );
  let expandedText = limited.lines.join("\n");
  let truncated = limited.truncated;
  if (expandedText.length > TOOL_TUI_RENDER_MAX_CHARS) {
    expandedText = `${expandedText.slice(0, TOOL_TUI_RENDER_MAX_CHARS)}\n… truncated …`;
    truncated = true;
  }
  if (!stripAnsiCodes(expandedText).trim()) return undefined;

  return {
    version: TOOL_TUI_RENDER_VERSION,
    source: TOOL_TUI_RENDER_SOURCE,
    width: TOOL_TUI_RENDER_WIDTH,
    expandedText,
    ...(truncated ? { truncated: true } : {}),
  };
}

function mergeToolTuiRenderSnapshot(
  details: unknown,
  snapshot: ToolTuiRenderSnapshot,
): Record<string, unknown> | undefined {
  if (!isToolTuiRecord(details)) {
    return undefined;
  }
  if (details.tuiRender !== undefined) return details;
  return { ...details, tuiRender: snapshot };
}

export interface MirrorExtensionUIResponse {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

interface PendingMirrorUIResponse<T> {
  resolve: (value: T) => void;
}

export interface MirrorTerminalDialogQueueRunOptions<T> {
  signal?: AbortSignal;
  defaultValue: T;
}

export interface MirrorTerminalDialogQueue {
  run<T>(
    task: () => Promise<T>,
    options: MirrorTerminalDialogQueueRunOptions<T>,
  ): Promise<T>;
}

export function createMirrorTerminalDialogQueue(): MirrorTerminalDialogQueue {
  let tail: Promise<void> = Promise.resolve();

  return {
    async run<T>(
      task: () => Promise<T>,
      options: MirrorTerminalDialogQueueRunOptions<T>,
    ): Promise<T> {
      const previous = tail.catch(() => {});
      let release = () => {};
      const currentDone = new Promise<void>((resolve) => {
        release = resolve;
      });
      tail = previous.then(() => currentDone);

      await previous;
      if (options.signal?.aborted) {
        release();
        return options.defaultValue;
      }

      try {
        return await task();
      } finally {
        release();
      }
    },
  };
}

function invalidMirrorAskResponse(message: string): Error {
  return new Error(`Malformed ask response: ${message}`);
}

export function normalizeMirrorAskAnswers(
  value: string | undefined,
): MirrorAskUIResult {
  if (!value) {
    return { answers: {}, allIgnored: true };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw invalidMirrorAskResponse(
      error instanceof Error ? error.message : String(error),
    );
  }

  if (!isRecord(parsed)) {
    throw invalidMirrorAskResponse("expected a JSON object");
  }

  const answers: Record<string, string | string[]> = {};
  for (const [key, answer] of Object.entries(parsed)) {
    if (typeof answer === "string") {
      answers[key] = answer;
      continue;
    }

    if (
      Array.isArray(answer) &&
      answer.every((item) => typeof item === "string")
    ) {
      answers[key] = answer;
      continue;
    }

    throw invalidMirrorAskResponse(`expected string or string[] for "${key}"`);
  }

  return { answers, allIgnored: Object.keys(answers).length === 0 };
}

export function parseMirrorAskUIResponse(
  response: MirrorExtensionUIResponse,
): MirrorAskUIResult {
  return response.cancelled
    ? { answers: {}, allIgnored: true }
    : normalizeMirrorAskAnswers(response.value);
}

export function parseMirrorSelectUIResponse(
  response: MirrorExtensionUIResponse,
): string | undefined {
  return response.cancelled ? undefined : response.value;
}

export function parseMirrorConfirmUIResponse(
  response: MirrorExtensionUIResponse,
): boolean {
  return response.cancelled ? false : (response.confirmed ?? false);
}

export function parseMirrorTextUIResponse(
  response: MirrorExtensionUIResponse,
): string | undefined {
  return response.cancelled ? undefined : response.value;
}

function formatTerminalAskOption(option: MirrorAskOption): string {
  return option.description
    ? `${option.label} — ${option.description}`
    : option.label;
}

function formatTerminalMultiAskOption(
  option: MirrorAskOption,
  selected: Set<string>,
): string {
  const mark = selected.has(option.value) ? "[x]" : "[ ]";
  return `${mark} ${formatTerminalAskOption(option)}`;
}

export async function terminalAskFallback(
  questions: MirrorAskQuestion[],
  allowCustom: boolean | undefined,
  opts: ExtensionUIDialogOptions | undefined,
  ui: Pick<ExtensionUIContext, "select" | "input">,
): Promise<MirrorAskUIResult> {
  const answers: Record<string, string | string[]> = {};
  const customAnswersAllowed = allowCustom !== false;

  for (const question of questions) {
    if (opts?.signal?.aborted) break;

    const id = question.id;
    if (!id) continue;

    const title = question.question || id;
    const options = Array.isArray(question.options) ? question.options : [];

    if (question.multiSelect) {
      const selected = new Set<string>();
      const customAnswers: string[] = [];

      if (options.length === 0) {
        if (!customAnswersAllowed) continue;
        const custom = await ui.input(
          title,
          "Type an answer, blank to skip",
          opts,
        );
        const trimmed = custom?.trim();
        if (trimmed) answers[id] = [trimmed];
        continue;
      }

      while (!opts?.signal?.aborted) {
        const optionChoices = options.map((option) =>
          formatTerminalMultiAskOption(option, selected),
        );
        const selectedCount = selected.size + customAnswers.length;
        const doneLabel =
          selectedCount > 0 ? `Done (${selectedCount} selected)` : "Done";
        const customLabel = "Custom answer";
        const skipLabel = "Skip";
        const choices = customAnswersAllowed
          ? [...optionChoices, customLabel, doneLabel, skipLabel]
          : [...optionChoices, doneLabel, skipLabel];
        const choice = await ui.select(title, choices, opts);
        if (!choice || choice === skipLabel) break;

        if (choice === doneLabel) {
          const selectedValues = options
            .filter((option) => selected.has(option.value))
            .map((option) => option.value);
          const values = [...selectedValues, ...customAnswers];
          if (values.length > 0) answers[id] = values;
          break;
        }

        if (choice === customLabel) {
          const custom = await ui.input(title, "Type a custom answer", opts);
          const trimmed = custom?.trim();
          if (trimmed) customAnswers.push(trimmed);
          continue;
        }

        const optionIndex = optionChoices.indexOf(choice);
        const option = optionIndex >= 0 ? options[optionIndex] : undefined;
        if (!option) continue;

        if (selected.has(option.value)) {
          selected.delete(option.value);
        } else {
          selected.add(option.value);
        }
      }
      continue;
    }

    if (options.length > 0) {
      const labels = options.map(formatTerminalAskOption);
      const customLabel = "Custom answer";
      const skipLabel = "Skip";
      const choices = customAnswersAllowed
        ? [...labels, customLabel, skipLabel]
        : [...labels, skipLabel];
      const selected = await ui.select(title, choices, opts);
      if (!selected || selected === skipLabel) continue;

      if (selected === customLabel) {
        const custom = await ui.input(title, "Type a custom answer", opts);
        const trimmed = custom?.trim();
        if (trimmed) answers[id] = trimmed;
        continue;
      }

      const index = labels.indexOf(selected);
      if (index >= 0) answers[id] = options[index]?.value ?? selected;
      continue;
    }

    if (!customAnswersAllowed) continue;
    const answer = await ui.input(title, "Type an answer, blank to skip", opts);
    const trimmed = answer?.trim();
    if (trimmed) answers[id] = trimmed;
  }

  return { answers, allIgnored: Object.keys(answers).length === 0 };
}

const DEFAULT_RECONNECT_DELAY_MS = 2_000;
const OPPI_RUNTIME_CONFLICT_NOTIFY_INTERVAL_MS = 60_000;
const MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES = 14 * 1024 * 1024;

export default async function oppiPiMirror(pi: ExtensionAPI) {
  let latestCtx: ExtensionContext | null = null;
  let ws: WebSocket | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  let indicatorMode: MirrorIndicatorMode | null = null;
  let indicatorLabel: string | undefined;
  let indicatorWidgetMounted = false;
  let requestIndicatorRender: (() => void) | null = null;
  let manualStop = false;
  const bridgeId = `pi-tui-${process.pid}`;
  let connectedSessionId: string | null = null;
  let connectedWorkspaceId: string | null = null;
  const queueProjection = new MirrorQueueProjection();
  const pendingUIResponses = new Map<
    string,
    PendingMirrorUIResponse<unknown>
  >();
  const terminalDialogQueue = createMirrorTerminalDialogQueue();
  const toolArgsByCallId = new Map<string, Record<string, unknown>>();
  const proxiedUIContexts = new WeakSet<object>();
  const widgetForwardingGenerations = new Map<string, number>();
  let suppressUIForwarding = false;
  let runtimeActive = true;
  let connectionSerial = 0;
  let nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
  let createWorkspaceOnNextConnect = false;
  let workspaceCreationPromptActive = false;
  let takeoverConfirmationSessionId: string | null = null;
  let takeoverPromptActive = false;
  let lastOppiRuntimeConflictSessionId: string | null = null;
  let lastOppiRuntimeConflictNotifiedAt = 0;

  let settings = loadSettings();

  const queueUpdateBridge = await (async () => {
    try {
      const { AgentSession } = await import("@earendil-works/pi-coding-agent");
      return installQueueUpdateBridge(
        AgentSession.prototype as AgentSessionPrototype,
      );
    } catch (error) {
      writeMirrorLog("error", "queue_update_bridge_install_failed", { error });
      return getQueueUpdateBridge();
    }
  })();
  const queueUpdateListener: QueueUpdateListener = ({ steering, followUp }) => {
    publishQueueIfChanged(steering, followUp);
  };
  const internalAgentEventListener: InternalAgentSessionEventListener = (
    event,
  ) => {
    const includeState =
      event.type === "compaction_end" || event.type === "auto_retry_end";
    const state =
      includeState && latestCtx ? safeStateSnapshot(pi, latestCtx) : undefined;
    send({
      type: "event",
      event,
      ...(state ? { state } : {}),
    });
  };
  queueUpdateBridge.listeners.add(queueUpdateListener);
  queueUpdateBridge.internalEventListeners.add(internalAgentEventListener);
  if (queueUpdateBridge.last) {
    publishQueueIfChanged(
      queueUpdateBridge.last.steering,
      queueUpdateBridge.last.followUp,
    );
  }

  function deactivateAfterStaleContext(scope: string) {
    if (!runtimeActive && !ws && !reconnectTimer && !heartbeatTimer) return;
    runtimeActive = false;
    manualStop = true;
    connectionSerial += 1;
    clearTimers();
    pendingUIResponses.clear();
    latestCtx = null;
    connectedSessionId = null;
    connectedWorkspaceId = null;

    const socket = ws;
    ws = null;
    if (
      socket &&
      (socket.readyState === WebSocket.OPEN ||
        socket.readyState === WebSocket.CONNECTING)
    ) {
      try {
        socket.close();
      } catch (error) {
        writeMirrorLog("warn", "stale_context_socket_close_failed", {
          scope,
          error,
        });
      }
    }

    writeMirrorLog("info", "stale_context_runtime_deactivated", { scope });
  }

  function logCallbackError(scope: string, error: unknown) {
    if (isStaleExtensionContextError(error)) {
      deactivateAfterStaleContext(scope);
      return;
    }
    writeMirrorLog("warn", "callback_error", { scope, error });
  }

  function truncatePlain(text: string, width: number): string {
    if (width <= 0) return "";
    return text.length > width ? text.slice(0, width) : text;
  }

  function indicatorColor(): MirrorIndicatorColor {
    if (indicatorMode === "live") return "success";
    if (indicatorMode === "error") return "error";
    if (indicatorMode === "reconnecting" || indicatorMode === "blocked") {
      return "warning";
    }
    return "muted";
  }

  function mountIndicatorWidget(ctx: ExtensionContext) {
    ctx.ui.setWidget(
      "oppi-mirror",
      (tui, theme) => {
        requestIndicatorRender = () => tui.requestRender();
        return {
          render(width: number): string[] {
            if (!indicatorLabel) return [];
            const maxTextWidth = Math.max(0, width - 2);
            const text = truncatePlain(indicatorLabel, maxTextWidth);
            const visibleWidth = text.length === 0 ? 1 : text.length + 2;
            const padding = " ".repeat(Math.max(0, width - visibleWidth));
            const dot = theme.fg(indicatorColor(), "●");
            return [`${padding}${text.length === 0 ? dot : `${dot} ${text}`}`];
          },
          invalidate(): void {},
        };
      },
      { placement: "belowEditor" },
    );
    indicatorWidgetMounted = true;
  }

  function safeSetIndicator(ctx: ExtensionContext, label: string | undefined) {
    indicatorLabel = label;
    try {
      withSuppressedUIForwarding(() => {
        if (!label) {
          ctx.ui.setWidget("oppi-mirror", undefined);
          indicatorWidgetMounted = false;
          requestIndicatorRender = null;
          return;
        }
        if (!indicatorWidgetMounted) {
          mountIndicatorWidget(ctx);
          return;
        }
        requestIndicatorRender?.();
      });
    } catch (error) {
      logCallbackError("failed to update status", error);
    }
  }

  function notify(
    ctx: ExtensionContext | null,
    message: string,
    type: "info" | "warning" | "error" = "info",
  ) {
    if (!ctx || !ctx.hasUI) {
      writeMirrorLog("info", "notification_skipped", { message, type });
      return;
    }
    try {
      withSuppressedUIForwarding(() => ctx.ui.notify(message, type));
    } catch (error) {
      logCallbackError("failed to notify", error);
    }
  }

  function serializeBridgePayload(
    payload: unknown,
  ): { json: string; bytes: number } | null {
    try {
      const json = JSON.stringify(payload);
      return { json, bytes: Buffer.byteLength(json, "utf8") };
    } catch (error) {
      writeMirrorLog("warn", "websocket_payload_serialize_failed", { error });
      return null;
    }
  }

  function oversizedCommandResultPayload(
    payload: Record<string, unknown>,
    bytes: number,
  ): Record<string, unknown> | null {
    if (payload.type !== "command_result" || typeof payload.id !== "string") {
      return null;
    }

    return {
      type: "command_result",
      id: payload.id,
      success: false,
      error: `Oppi Mirror response too large (${bytes} bytes > ${MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES} bytes); try a narrower request.`,
      ...(isRecord(payload.state) ? { state: payload.state } : {}),
    };
  }

  function send(payload: unknown) {
    if (ws?.readyState !== WebSocket.OPEN) return;
    try {
      let serialized = serializeBridgePayload(payload);
      if (!serialized) return;

      if (serialized.bytes > MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES) {
        const payloadRecord = isRecord(payload) ? payload : {};
        const replacement = oversizedCommandResultPayload(
          payloadRecord,
          serialized.bytes,
        );
        writeMirrorLog("warn", "websocket_payload_too_large", {
          payloadType:
            typeof payloadRecord.type === "string"
              ? payloadRecord.type
              : undefined,
          bytes: serialized.bytes,
          maxBytes: MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES,
          replacedWithError: replacement !== null,
        });
        if (!replacement) {
          try {
            ws.close(1009, "Oppi Mirror payload too large");
          } catch (error) {
            writeMirrorLog("warn", "websocket_oversized_close_failed", {
              error,
            });
          }
          return;
        }
        serialized = serializeBridgePayload(replacement);
        if (!serialized) return;
      }

      ws.send(serialized.json);
    } catch (error) {
      writeMirrorLog("warn", "websocket_send_failed", { error });
    }
  }

  function withSuppressedUIForwarding<T>(run: () => T): T {
    const previous = suppressUIForwarding;
    suppressUIForwarding = true;
    try {
      return run();
    } finally {
      suppressUIForwarding = previous;
    }
  }

  function nextUIRequestId(method: string): string {
    return `mirror_ui_${method}_${Date.now().toString(36)}_${Math.random()
      .toString(36)
      .slice(2, 10)}`;
  }

  function composeAbortSignals(
    first: AbortSignal | undefined,
    second: AbortSignal,
  ): AbortSignal {
    if (!first) return second;
    if (first.aborted) return first;

    const controller = new AbortController();
    const abort = () => controller.abort();
    first.addEventListener("abort", abort, { once: true });
    second.addEventListener("abort", abort, { once: true });
    return controller.signal;
  }

  function sendUIRequest(payload: Record<string, unknown>): void {
    send({ type: "extension_ui_request", ...payload });
  }

  function sendUISettled(id: string): void {
    send({ type: "extension_ui_request_settled", id });
  }

  async function raceMirrorDialog<T>(
    method: MirrorExtensionUIMethod,
    request: Record<string, unknown>,
    opts: ExtensionUIDialogOptions | undefined,
    defaultValue: T,
    terminalCall: (opts: ExtensionUIDialogOptions | undefined) => Promise<T>,
    parsePhoneResponse: (response: MirrorExtensionUIResponse) => T,
  ): Promise<T> {
    if (suppressUIForwarding || ws?.readyState !== WebSocket.OPEN) {
      return terminalCall(opts);
    }

    const id = nextUIRequestId(method);
    const localAbort = new AbortController();
    const terminalOpts = {
      ...opts,
      signal: composeAbortSignals(opts?.signal, localAbort.signal),
    };

    let settledByPhone = false;
    const phonePromise = new Promise<{ source: "phone"; value: T }>(
      (resolve) => {
        pendingUIResponses.set(id, {
          resolve: (response) => {
            const value = parsePhoneResponse(
              response as MirrorExtensionUIResponse,
            );
            settledByPhone = true;
            resolve({
              source: "phone",
              value,
            });
          },
        });
      },
    );

    sendUIRequest({
      id,
      method,
      ...request,
      timeout: opts?.timeout,
      timeoutAt: opts?.timeout ? Date.now() + opts.timeout : undefined,
    });

    const terminalPromise = terminalDialogQueue
      .run(() => terminalCall(terminalOpts), {
        signal: terminalOpts.signal,
        defaultValue,
      })
      .then((value) => ({ source: "terminal" as const, value }))
      .catch((error: unknown) => {
        if (settledByPhone)
          return { source: "phone" as const, value: defaultValue };
        throw error;
      });

    let winner: { source: "phone" | "terminal"; value: T };
    try {
      winner = await Promise.race([phonePromise, terminalPromise]);
    } finally {
      pendingUIResponses.delete(id);
      sendUISettled(id);
    }

    if (winner.source === "phone") {
      localAbort.abort();
    }
    return winner.value;
  }

  function handleExtensionUIResponse(
    response: MirrorExtensionUIResponse,
  ): void {
    const pending = pendingUIResponses.get(response.id);
    if (!pending) return;
    pending.resolve(response);
  }

  function installExtensionUIProxy(ctx: ExtensionContext): void {
    const ui = ctx.ui as MirrorOptionalUIContext;
    if (proxiedUIContexts.has(ui as object)) return;

    const original = bindMirrorOptionalUIContext(ui);

    proxiedUIContexts.add(ui as object);

    ui.ask = (questions, allowCustom = true, opts) =>
      raceMirrorDialog(
        "ask",
        { questions, allowCustom },
        opts,
        { answers: {}, allIgnored: true },
        (nextOpts) => original.ask(questions, allowCustom, nextOpts),
        parseMirrorAskUIResponse,
      );

    ui.select = (title, options, opts) =>
      raceMirrorDialog(
        "select",
        { title, options },
        opts,
        undefined,
        (nextOpts) => original.select(title, options, nextOpts),
        parseMirrorSelectUIResponse,
      );

    ui.confirm = (title, message, opts) =>
      raceMirrorDialog(
        "confirm",
        { title, message },
        opts,
        false,
        (nextOpts) => original.confirm(title, message, nextOpts),
        parseMirrorConfirmUIResponse,
      );

    ui.input = (title, placeholder, opts) =>
      raceMirrorDialog(
        "input",
        { title, placeholder },
        opts,
        undefined,
        (nextOpts) => original.input(title, placeholder, nextOpts),
        parseMirrorTextUIResponse,
      );

    ui.editor = (title, prefill) =>
      raceMirrorDialog(
        "editor",
        { title, prefill },
        undefined,
        undefined,
        () => original.editor(title, prefill),
        parseMirrorTextUIResponse,
      );

    ui.notify = (message, type) => {
      original.notify?.(message, type);
      if (!suppressUIForwarding) {
        sendUIRequest({
          id: nextUIRequestId("notify"),
          method: "notify",
          message,
          notifyType: type,
        });
      }
    };

    ui.setStatus = (key, text) => {
      original.setStatus?.(key, text);
      if (!suppressUIForwarding) {
        sendUIRequest({
          id: nextUIRequestId("setStatus"),
          method: "setStatus",
          statusKey: key,
          statusText: text,
        });
      }
    };

    ui.setWidget = ((
      key: string,
      content: unknown,
      options?: { placement?: string },
    ) => {
      const generation = (widgetForwardingGenerations.get(key) ?? 0) + 1;
      widgetForwardingGenerations.set(key, generation);

      if (typeof content === "function") {
        const forwardingSuppressed = suppressUIForwarding;
        let component: unknown;
        let snapshotPending = false;
        const sendWidgetSnapshot = (
          widgetLines: string[],
          nativeSurface?: Record<string, unknown>,
        ) => {
          if (
            forwardingSuppressed ||
            suppressUIForwarding ||
            widgetForwardingGenerations.get(key) !== generation
          ) {
            return;
          }
          sendUIRequest({
            id: nextUIRequestId("setWidget"),
            method: "setWidget",
            widgetKey: key,
            widgetLines,
            widgetPlacement: options?.placement,
            nativeSurface,
          });
        };
        const sendSnapshot = () => {
          sendWidgetSnapshot(
            snapshotMirrorWidgetLines(component),
            snapshotMirrorWidgetNativeSurface(component),
          );
        };
        const scheduleSnapshot = () => {
          if (snapshotPending) return;
          snapshotPending = true;
          queueMicrotask(() => {
            snapshotPending = false;
            sendSnapshot();
          });
        };
        const wrappedContent = (tui: unknown, theme: unknown) => {
          const originalComponent = (
            content as (tui: unknown, theme: unknown) => unknown
          )(createMirrorWidgetForwardingTui(tui, scheduleSnapshot), theme);
          component = createMirrorWidgetForwardingComponent(
            originalComponent,
            scheduleSnapshot,
            () => sendWidgetSnapshot([]),
          );
          scheduleSnapshot();
          return component;
        };
        if (original.setWidget) {
          original.setWidget(key, wrappedContent as never, options as never);
        } else {
          wrappedContent(undefined, undefined);
        }
        return;
      }

      original.setWidget?.(key, content as never, options as never);
      if (
        !suppressUIForwarding &&
        (content === undefined || Array.isArray(content))
      ) {
        sendUIRequest({
          id: nextUIRequestId("setWidget"),
          method: "setWidget",
          widgetKey: key,
          widgetLines: content,
          widgetPlacement: options?.placement,
        });
      }
    }) as ExtensionUIContext["setWidget"];

    ui.setTitle = (title) => {
      original.setTitle?.(title);
      if (!suppressUIForwarding) {
        sendUIRequest({
          id: nextUIRequestId("setTitle"),
          method: "setTitle",
          title,
        });
      }
    };

    ui.setEditorText = (text) => {
      original.setEditorText?.(text);
      if (!suppressUIForwarding) {
        sendUIRequest({
          id: nextUIRequestId("set_editor_text"),
          method: "set_editor_text",
          text,
        });
      }
    };

    ui.pasteToEditor = (text) => {
      original.pasteToEditor?.(text);
      if (!suppressUIForwarding) {
        sendUIRequest({
          id: nextUIRequestId("set_editor_text"),
          method: "set_editor_text",
          text,
        });
      }
    };
  }

  function renderIndicator(ctx: ExtensionContext | null = latestCtx) {
    if (!runtimeActive || !ctx || !indicatorMode) return;
    const pendingCount = queueProjection.pendingCount();
    const queued = pendingCount > 0 ? ` q:${pendingCount}` : "";
    const label =
      indicatorMode === "live"
        ? `Oppi mirroring live${queued}`
        : indicatorMode === "connecting"
          ? "Oppi mirror connecting"
          : indicatorMode === "reconnecting"
            ? "Oppi mirror reconnecting"
            : indicatorMode === "blocked"
              ? "Oppi mirror waiting"
              : "Oppi mirror offline";
    safeSetIndicator(ctx, label);
  }

  function startIndicator(ctx: ExtensionContext, mode: MirrorIndicatorMode) {
    if (!runtimeActive) return;
    latestCtx = ctx;
    indicatorMode = mode;
    renderIndicator(ctx);
  }

  function setIndicatorMode(mode: MirrorIndicatorMode) {
    if (!runtimeActive) return;
    indicatorMode = mode;
    renderIndicator();
  }

  function stopIndicator(ctx: ExtensionContext | null = latestCtx) {
    indicatorMode = null;
    if (ctx) safeSetIndicator(ctx, undefined);
  }

  function sendQueueState() {
    send({ type: "queue_state", queue: queueProjection.snapshot() });
  }

  function syncQueueFromTexts(
    steering: readonly string[],
    followUp: readonly string[],
    source = "runtime_snapshot",
  ): boolean {
    const previous = queueProjection.snapshot();
    const result = queueProjection.reconcileRuntimeSnapshot({
      steering,
      followUp,
    });
    if (result.changed) {
      writeMirrorLog("info", "queue_projection_reconciled", {
        runtime: "pi-tui",
        bridgeId,
        sessionId: connectedSessionId,
        workspaceId: connectedWorkspaceId,
        source,
        previousVersion: previous.version,
        version: result.queue.version,
        previousSteeringCount: previous.steering.length,
        steeringCount: result.queue.steering.length,
        previousFollowUpCount: previous.followUp.length,
        followUpCount: result.queue.followUp.length,
      });
    }
    return result.changed;
  }

  function publishQueueIfChanged(
    steering: readonly string[],
    followUp: readonly string[],
  ) {
    if (!runtimeActive) return;
    if (!syncQueueFromTexts(steering, followUp, "queue_update")) return;
    sendQueueState();
    renderIndicator();
  }

  function queueTextsFromAgentSession(
    session: EditableAgentSession | undefined,
  ): { steering: readonly string[]; followUp: readonly string[] } | null {
    if (!session) return null;
    const hasSteeringQueue =
      typeof session.getSteeringMessages === "function" ||
      Array.isArray(session._steeringMessages);
    const hasFollowUpQueue =
      typeof session.getFollowUpMessages === "function" ||
      Array.isArray(session._followUpMessages);
    if (!hasSteeringQueue && !hasFollowUpQueue) return null;

    return {
      steering: Array.from(
        session.getSteeringMessages?.() ?? session._steeringMessages ?? [],
      ),
      followUp: Array.from(
        session.getFollowUpMessages?.() ?? session._followUpMessages ?? [],
      ),
    };
  }

  function syncQueueFromEditableSession(ctx: ExtensionContext): boolean {
    const texts = queueTextsFromAgentSession(findEditableAgentSession(ctx));
    if (!texts) return false;
    if (
      !syncQueueFromTexts(
        texts.steering,
        texts.followUp,
        "agent_session_snapshot",
      )
    )
      return false;
    sendQueueState();
    renderIndicator();
    return true;
  }

  function findEditableAgentSession(
    ctx: ExtensionContext,
  ): EditableAgentSession | undefined {
    const sessionId = ctx.sessionManager.getSessionId();
    return (
      queueUpdateBridge.sessions.get(sessionId) ?? queueUpdateBridge.lastSession
    );
  }

  function requireEditableAgentSession(
    ctx: ExtensionContext,
  ): EditableAgentSession {
    const session = findEditableAgentSession(ctx);
    if (!session) {
      throw new Error(
        "Terminal Pi runtime session control is not attached yet",
      );
    }
    return session;
  }

  function replaceLocalQueue(
    ctx: ExtensionContext,
    nextQueue: MessageQueueState,
  ) {
    const session = requireEditableAgentSession(ctx);
    const previous = queueProjection.snapshot();
    const result = queueProjection.replace(nextQueue);
    if (result.changed) {
      writeMirrorLog("info", "queue_projection_replaced", {
        runtime: "pi-tui",
        bridgeId,
        sessionId: connectedSessionId,
        workspaceId: connectedWorkspaceId,
        source: "set_queue",
        previousVersion: previous.version,
        version: result.queue.version,
        previousSteeringCount: previous.steering.length,
        steeringCount: result.queue.steering.length,
        previousFollowUpCount: previous.followUp.length,
        followUpCount: result.queue.followUp.length,
      });
    }
    replaceAgentSessionQueue(session, nextQueue);
  }

  function clearQueueForShutdown(ctx: ExtensionContext) {
    const previous = queueProjection.snapshot();
    const result = queueProjection.clear();
    const session = findEditableAgentSession(ctx);
    if (session) {
      try {
        clearAgentSessionQueue(session);
      } catch (error) {
        logCallbackError("failed to clear queue for shutdown", error);
      }
    }
    writeMirrorLog("info", "queue_projection_cleared_for_shutdown", {
      runtime: "pi-tui",
      bridgeId,
      sessionId: connectedSessionId,
      workspaceId: connectedWorkspaceId,
      previousVersion: previous.version,
      version: result.queue.version,
      previousSteeringCount: previous.steering.length,
      steeringCount: result.queue.steering.length,
      previousFollowUpCount: previous.followUp.length,
      followUpCount: result.queue.followUp.length,
    });
    sendQueueState();
    renderIndicator();
  }

  function scheduleRuntimeReload(ctx: ExtensionContext) {
    const session = findEditableAgentSession(ctx);
    if (!session?.reload) {
      throw new Error("Terminal Pi runtime reload is not attached yet");
    }
    setTimeout(() => {
      session.reload?.().catch((error) => {
        logCallbackError("remote reload failed", error);
      });
    }, 0);
  }

  function refreshQueueFromRuntime(): MessageQueueState {
    return queueProjection.snapshot();
  }

  function enqueueShadow(
    kind: "steer" | "followUp",
    message: string,
    images?: QueueImageContent[],
    options: { previousMatchingCount?: number } = {},
  ) {
    const result = queueProjection.enqueueOptimistic(
      kind === "steer" ? "steer" : "follow_up",
      message,
      images,
      options,
    );
    if (!result.changed) return;
    sendQueueState();
    renderIndicator();
  }

  function markQueueItemStarted(message: string | undefined) {
    const started = queueProjection.markStarted(message);
    if (!started) return;
    send({
      type: "queue_item_started",
      kind: started.kind,
      item: started.item,
      queueVersion: started.queueVersion,
      queue: started.queue,
    });
    sendQueueState();
    renderIndicator();
  }

  function clearTimers() {
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = null;
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }

  function startHeartbeat(socket: WebSocket, serial: number) {
    if (heartbeatTimer) clearInterval(heartbeatTimer);
    heartbeatTimer = setInterval(() => {
      if (!runtimeActive || connectionSerial !== serial || ws !== socket) {
        return;
      }
      if (!latestCtx) return;
      try {
        syncQueueFromEditableSession(latestCtx);
        send({
          type: "heartbeat",
          state: stateSnapshot(pi, latestCtx),
          queue: queueProjection.snapshot(),
        });
      } catch (error) {
        logCallbackError("heartbeat failed", error);
      }
    }, 10_000);
  }

  function configured(): { serverUrl: string; token: string } | null {
    if (!settings.serverUrl || !settings.token) return null;
    return { serverUrl: settings.serverUrl, token: settings.token };
  }

  function workspaceNameFromSuggestion(hostMount: string): string {
    return (
      basename(hostMount.trim().replace(/\/+$/, "")) || "Terminal Workspace"
    );
  }

  function parkBridgeForUserDecision(reason: string) {
    manualStop = true;
    connectionSerial += 1;
    clearTimers();
    pendingUIResponses.clear();
    const socket = ws;
    ws = null;
    if (
      socket &&
      (socket.readyState === WebSocket.OPEN ||
        socket.readyState === WebSocket.CONNECTING)
    ) {
      socket.close(1000, reason);
    }
  }

  function parkBridgeForWorkspaceDecision() {
    parkBridgeForUserDecision("Waiting for workspace creation decision");
  }

  async function handleWorkspaceMissingError(
    ctx: ExtensionContext,
    err: Record<string, unknown>,
  ) {
    const cwd = typeof err.cwd === "string" ? err.cwd : ctx.cwd;
    const suggestedHostMount =
      typeof err.suggestedHostMount === "string" ? err.suggestedHostMount : cwd;
    const suggestedName =
      typeof err.suggestedName === "string" && err.suggestedName.trim()
        ? err.suggestedName.trim()
        : workspaceNameFromSuggestion(suggestedHostMount);
    const mode = settings.workspaceCreation ?? "ask";
    const wasRequestingCreate =
      createWorkspaceOnNextConnect || mode === "always";

    createWorkspaceOnNextConnect = false;
    nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
    setIndicatorMode("blocked");
    parkBridgeForWorkspaceDecision();
    writeMirrorLog("warn", "workspace_missing", {
      cwd,
      suggestedHostMount,
      suggestedName,
      workspaceCreation: mode,
      wasRequestingCreate,
    });

    if (wasRequestingCreate) {
      notify(
        ctx,
        `Oppi Mirror could not create workspace ${suggestedName}; details were logged.`,
        "warning",
      );
      return;
    }

    if (mode === "never") {
      notify(
        ctx,
        `Oppi Mirror needs an Oppi workspace for ${suggestedHostMount}. Create it in Oppi, or set oppiMirror.workspaceCreation to ask or always.`,
        "warning",
      );
      return;
    }

    if (workspaceCreationPromptActive) return;
    workspaceCreationPromptActive = true;
    let confirmed = false;
    try {
      confirmed = await withSuppressedUIForwarding(() =>
        ctx.ui.confirm(
          "Create Oppi workspace?",
          `No Oppi workspace contains this terminal path.\n\nCreate ${suggestedName} at ${suggestedHostMount}?`,
        ),
      );
    } catch (error) {
      logCallbackError("workspace creation prompt failed", error);
    } finally {
      workspaceCreationPromptActive = false;
    }

    if (!runtimeActive) return;
    if (!confirmed) {
      notify(ctx, "Oppi Mirror stopped; no workspace was created.", "info");
      stopIndicator(ctx);
      return;
    }

    createWorkspaceOnNextConnect = true;
    manualStop = false;
    connect(ctx);
  }

  async function handleOppiTakeoverConfirmationRequired(
    ctx: ExtensionContext,
    err: Record<string, unknown>,
  ) {
    const sessionId = typeof err.sessionId === "string" ? err.sessionId : "";
    const sessionName =
      typeof err.sessionName === "string" && err.sessionName.trim()
        ? err.sessionName.trim()
        : undefined;
    const sessionStatus =
      typeof err.sessionStatus === "string" && err.sessionStatus.trim()
        ? err.sessionStatus.trim()
        : undefined;
    const requiresStop = err.requiresStop === true;

    takeoverConfirmationSessionId = null;
    nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
    setIndicatorMode("blocked");
    parkBridgeForUserDecision("Waiting for Oppi takeover confirmation");
    writeMirrorLog("warn", "oppi_takeover_confirmation_required", {
      sessionId,
      sessionName,
      sessionStatus,
      requiresStop,
    });

    if (!sessionId) {
      notify(
        ctx,
        "Oppi Mirror needs takeover confirmation, but the server did not name a session.",
        "warning",
      );
      stopIndicator(ctx);
      return;
    }

    if (takeoverPromptActive) return;
    takeoverPromptActive = true;
    let confirmed = false;
    try {
      const label = sessionName ? `${sessionName} (${sessionId})` : sessionId;
      const statusLine = sessionStatus
        ? `\nCurrent Oppi status: ${sessionStatus}`
        : "";
      const takeoverEffect = requiresStop
        ? "Oppi will stop the server-owned SDK session, then mirror this terminal as pi-tui."
        : "Oppi will treat the live runtime as pi-tui until the terminal mirror stops.";
      confirmed = await withSuppressedUIForwarding(() =>
        ctx.ui.confirm(
          "Take over Oppi session?",
          `This Pi session is currently owned by Oppi as ${label}.${statusLine}\n\nTake it over from this terminal? ${takeoverEffect}`,
        ),
      );
    } catch (error) {
      logCallbackError("takeover confirmation prompt failed", error);
    } finally {
      takeoverPromptActive = false;
    }

    if (!runtimeActive) return;
    if (!confirmed) {
      notify(
        ctx,
        "Oppi Mirror stopped; session takeover was not confirmed.",
        "info",
      );
      stopIndicator(ctx);
      return;
    }

    takeoverConfirmationSessionId = sessionId;
    manualStop = false;
    connect(ctx);
  }

  function connect(ctx: ExtensionContext) {
    if (!runtimeActive) return;
    try {
      installExtensionUIProxy(ctx);
    } catch (error) {
      logCallbackError("install extension UI proxy failed", error);
      return;
    }
    latestCtx = ctx;
    if (!isInteractiveTerminalProcess()) {
      notify(
        ctx,
        "Oppi Mirror only starts from an interactive Pi TUI terminal",
        "warning",
      );
      return;
    }
    settings = loadSettings();
    const config = configured();
    if (!config) {
      notify(
        ctx,
        "Oppi Mirror could not auto-discover ~/.config/oppi/config.json. Start the Oppi server once, or set OPPI_MIRROR_URL/OPPI_MIRROR_TOKEN.",
        "warning",
      );
      return;
    }

    if (
      ws &&
      (ws.readyState === WebSocket.OPEN ||
        ws.readyState === WebSocket.CONNECTING)
    ) {
      notify(ctx, "Oppi Mirror is already running", "info");
      return;
    }

    manualStop = false;
    startIndicator(ctx, "connecting");
    let url: string;
    let socket: WebSocket;
    try {
      url = bridgeUrl(config.serverUrl);
      socket = new WebSocket(url, {
        headers: { Authorization: `Bearer ${config.token}` },
        perMessageDeflate: false,
        // Auto-discovery reads the local Oppi config/token from the same user account.
        // Local self-signed HTTPS is expected; do not require manual cert pairing for this path.
        rejectUnauthorized: !isLocalUrl(config.serverUrl),
      });
    } catch (error) {
      logCallbackError("websocket setup failed", error);
      setIndicatorMode("error");
      return;
    }
    const serial = ++connectionSerial;
    ws = socket;

    socket.on("open", () => {
      if (!runtimeActive || connectionSerial !== serial || ws !== socket) {
        return;
      }
      try {
        const shouldCreateWorkspace =
          createWorkspaceOnNextConnect ||
          settings.workspaceCreation === "always";
        send({
          type: "hello",
          protocolVersion: 1,
          bridgeId,
          pid: process.pid,
          hostname: hostname(),
          cwd: ctx.cwd,
          ...(shouldCreateWorkspace ? { createWorkspace: true } : {}),
          ...(takeoverConfirmationSessionId
            ? {
                takeoverConfirmation: {
                  sessionId: takeoverConfirmationSessionId,
                },
              }
            : {}),
          capabilities: OPPI_MIRROR_CAPABILITIES,
          state: stateSnapshot(pi, ctx),
        });
        sendQueueState();
        startHeartbeat(socket, serial);
        setIndicatorMode("connecting");
      } catch (error) {
        logCallbackError("websocket open handler failed", error);
      }
    });

    socket.on("message", (raw: RawData) => {
      if (!runtimeActive || connectionSerial !== serial || ws !== socket) {
        return;
      }
      void handleServerMessage(raw.toString()).catch((error: unknown) => {
        logCallbackError("websocket message handler failed", error);
      });
    });

    socket.on("close", (code: number, reason: Buffer) => {
      if (!runtimeActive || connectionSerial !== serial || ws !== socket) {
        return;
      }
      writeMirrorLog("info", "bridge_disconnected", {
        runtime: "pi-tui",
        bridgeId,
        sessionId: connectedSessionId,
        workspaceId: connectedWorkspaceId,
        code,
        reason: reason.toString("utf8"),
        manualStop,
      });
      clearTimers();
      pendingUIResponses.clear();
      ws = null;
      if (!manualStop) {
        const delayMs = Math.max(
          DEFAULT_RECONNECT_DELAY_MS,
          nextReconnectDelayMs,
        );
        setIndicatorMode(
          delayMs > DEFAULT_RECONNECT_DELAY_MS ? "blocked" : "reconnecting",
        );
        reconnectTimer = setTimeout(() => {
          if (!runtimeActive || connectionSerial !== serial || manualStop) {
            return;
          }
          try {
            connect(ctx);
          } catch (error) {
            logCallbackError("reconnect failed", error);
          }
        }, delayMs);
      } else {
        stopIndicator(ctx);
      }
    });

    socket.on("error", (error: Error) => {
      if (!runtimeActive || connectionSerial !== serial || ws !== socket) {
        return;
      }
      nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
      setIndicatorMode("reconnecting");
      writeMirrorLog("warn", "websocket_error", { url, error });
    });
  }

  function stop(
    ctx: ExtensionContext | null,
    reason = "stopped",
    options: { notify?: boolean } = {},
  ) {
    const shouldNotify = options.notify ?? true;
    manualStop = true;
    connectionSerial += 1;
    clearTimers();
    pendingUIResponses.clear();
    const socket = ws;
    const stateCtx = ctx ?? latestCtx;
    if (socket?.readyState === WebSocket.OPEN) {
      try {
        socket.send(
          JSON.stringify({
            type: "goodbye",
            reason,
            ...(stateCtx ? { state: stateSnapshot(pi, stateCtx) } : {}),
          }),
        );
      } catch (error) {
        logCallbackError("failed to send goodbye", error);
      }
    }
    if (
      socket &&
      (socket.readyState === WebSocket.OPEN ||
        socket.readyState === WebSocket.CONNECTING)
    ) {
      socket.close();
    }
    ws = null;
    connectedSessionId = null;
    connectedWorkspaceId = null;
    stopIndicator(stateCtx);
    latestCtx = null;
    if (shouldNotify) notify(ctx, "Oppi Mirror stopped");
  }

  async function handleServerMessage(raw: string) {
    if (!runtimeActive) return;
    const ctx = latestCtx;
    if (!ctx) return;

    const message = JSON.parse(raw) as {
      type?: string;
      id?: string;
      command?: Record<string, unknown>;
    };
    switch (message.type) {
      case "hello_ack":
        connectedSessionId =
          (message as { sessionId?: string }).sessionId ?? null;
        connectedWorkspaceId =
          (message as { workspaceId?: string }).workspaceId ?? null;
        nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
        createWorkspaceOnNextConnect = false;
        workspaceCreationPromptActive = false;
        takeoverConfirmationSessionId = null;
        takeoverPromptActive = false;
        lastOppiRuntimeConflictSessionId = null;
        lastOppiRuntimeConflictNotifiedAt = 0;
        writeMirrorLog("info", "bridge_connected", {
          runtime: "pi-tui",
          bridgeId,
          sessionId: connectedSessionId,
          workspaceId: connectedWorkspaceId,
        });
        setIndicatorMode("live");
        return;

      case "command":
        if (message.id && message.command) {
          await handleCommand(ctx, message.id, message.command);
        }
        return;

      case "extension_ui_response":
        handleExtensionUIResponse(message as MirrorExtensionUIResponse);
        return;

      case "error": {
        const err = message as {
          code?: string;
          error?: string;
          retryAfterMs?: number;
          sessionId?: string;
          sessionName?: string;
          sessionStatus?: string;
          requiresStop?: boolean;
          cwd?: string;
          suggestedHostMount?: string;
          suggestedName?: string;
        };
        const errorText = err.error ?? "unknown";
        if (err.code === "workspace_missing") {
          await handleWorkspaceMissingError(ctx, err);
          return;
        }
        if (err.code === "oppi_takeover_confirmation_required") {
          await handleOppiTakeoverConfirmationRequired(ctx, err);
          return;
        }
        if (
          err.code === "oppi_runtime_active" ||
          errorText.includes("already owned by the oppi runtime")
        ) {
          const sessionId =
            typeof err.sessionId === "string" ? err.sessionId : "";
          if (sessionId && takeoverConfirmationSessionId !== sessionId) {
            await handleOppiTakeoverConfirmationRequired(ctx, {
              ...err,
              sessionId,
              requiresStop: true,
            });
            return;
          }

          const sessionLabel = sessionId || "this session";
          nextReconnectDelayMs =
            typeof err.retryAfterMs === "number" &&
            Number.isFinite(err.retryAfterMs)
              ? Math.max(DEFAULT_RECONNECT_DELAY_MS, err.retryAfterMs)
              : 10_000;
          takeoverConfirmationSessionId = null;
          takeoverPromptActive = false;
          setIndicatorMode("blocked");

          const now = Date.now();
          const shouldNotify =
            lastOppiRuntimeConflictSessionId !== sessionLabel ||
            now - lastOppiRuntimeConflictNotifiedAt >
              OPPI_RUNTIME_CONFLICT_NOTIFY_INTERVAL_MS;
          if (shouldNotify) {
            lastOppiRuntimeConflictSessionId = sessionLabel;
            lastOppiRuntimeConflictNotifiedAt = now;
            notify(
              ctx,
              `Oppi Mirror could not stop Oppi session ${sessionLabel}. Stop it in Oppi, then retry the terminal takeover.`,
              "warning",
            );
          }
          return;
        }

        nextReconnectDelayMs = DEFAULT_RECONNECT_DELAY_MS;
        setIndicatorMode("error");
        writeMirrorLog("warn", "server_error_message", {
          code: err.code,
          error: errorText,
          retryAfterMs: err.retryAfterMs,
          sessionId: err.sessionId,
          cwd: err.cwd,
          suggestedHostMount: err.suggestedHostMount,
          suggestedName: err.suggestedName,
        });
        notify(
          ctx,
          "Oppi Mirror reported a bridge error; details were logged.",
          "warning",
        );
        return;
      }
    }
  }

  function commandDataLogDetails(
    type: OppiMirrorBridgeCommand,
    data: unknown,
  ): Record<string, unknown> {
    if (
      type !== "get_session_tree" ||
      !isRecord(data) ||
      !Array.isArray(data.nodes)
    ) {
      return {};
    }

    return {
      responseKind: "session_tree_snapshot",
      responseNodeCount: data.nodes.length,
    };
  }

  async function handleCommand(
    ctx: ExtensionContext,
    id: string,
    command: Record<string, unknown>,
  ) {
    const startedAt = Date.now();
    const details = commandLogDetails(command);
    writeMirrorLog("info", "command_received", {
      runtime: "pi-tui",
      bridgeId,
      sessionId: connectedSessionId,
      workspaceId: connectedWorkspaceId,
      commandId: id,
      ...details,
    });
    try {
      const type = command.type;
      if (!isOppiMirrorBridgeCommand(type)) {
        throw new Error(`Unsupported Oppi Mirror command: ${String(type)}`);
      }
      const data = await runCommand(ctx, type, command);
      const responsePayload = {
        type: "command_result",
        id,
        success: true,
        data,
        state: stateSnapshot(pi, ctx),
      };
      const responseBytes = serializeBridgePayload(responsePayload)?.bytes;
      writeMirrorLog("info", "command_completed", {
        runtime: "pi-tui",
        bridgeId,
        sessionId: connectedSessionId,
        workspaceId: connectedWorkspaceId,
        commandId: id,
        ...details,
        ...commandDataLogDetails(type, data),
        outcome: "success",
        durationMs: Date.now() - startedAt,
        responseBytes,
        maxPayloadBytes: MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES,
      });
      send(responsePayload);
    } catch (error) {
      const responsePayload = commandError("command_result", id, error);
      const responseBytes = serializeBridgePayload(responsePayload)?.bytes;
      writeMirrorLog("warn", "command_completed", {
        runtime: "pi-tui",
        bridgeId,
        sessionId: connectedSessionId,
        workspaceId: connectedWorkspaceId,
        commandId: id,
        ...details,
        outcome: "error",
        durationMs: Date.now() - startedAt,
        responseBytes,
        maxPayloadBytes: MIRROR_BRIDGE_MAX_SAFE_PAYLOAD_BYTES,
        error,
      });
      send(responsePayload);
    }
  }

  async function runCommand(
    ctx: ExtensionContext,
    type: OppiMirrorBridgeCommand,
    command: Record<string, unknown>,
  ): Promise<unknown> {
    switch (type) {
      case "prompt": {
        const message =
          typeof command.message === "string" ? command.message : "";
        if (message.trim() === "/reload") {
          scheduleRuntimeReload(ctx);
          return { reloading: true };
        }
        const images = imagesFromCommand(command.images);
        const content = contentForMessage(message, images);
        const streamingBehavior = command.streamingBehavior;
        if (streamingBehavior === "steer") {
          const previousMatchingCount = queueProjection
            .snapshot()
            .steering.filter((item) => item.message === message).length;
          pi.sendUserMessage(content, { deliverAs: "steer" });
          enqueueShadow("steer", message, images, { previousMatchingCount });
        } else if (streamingBehavior === "followUp") {
          const previousMatchingCount = queueProjection
            .snapshot()
            .followUp.filter((item) => item.message === message).length;
          pi.sendUserMessage(content, { deliverAs: "followUp" });
          enqueueShadow("followUp", message, images, { previousMatchingCount });
        } else {
          pi.sendUserMessage(content);
        }
        return { dispatched: true, queue: queueProjection.snapshot() };
      }

      case "steer": {
        const message = String(command.message ?? "");
        const images = imagesFromCommand(command.images);
        const previousMatchingCount = queueProjection
          .snapshot()
          .steering.filter((item) => item.message === message).length;
        pi.sendUserMessage(contentForMessage(message, images), {
          deliverAs: "steer",
        });
        enqueueShadow("steer", message, images, { previousMatchingCount });
        return { dispatched: true, queue: queueProjection.snapshot() };
      }

      case "follow_up": {
        const message = String(command.message ?? "");
        const images = imagesFromCommand(command.images);
        const previousMatchingCount = queueProjection
          .snapshot()
          .followUp.filter((item) => item.message === message).length;
        pi.sendUserMessage(contentForMessage(message, images), {
          deliverAs: "followUp",
        });
        enqueueShadow("followUp", message, images, { previousMatchingCount });
        return { dispatched: true, queue: queueProjection.snapshot() };
      }

      case "abort":
        findEditableAgentSession(ctx)?.abortCompaction?.();
        ctx.abort();
        // Remote abort has no terminal composer to restore queued text into.
        // Keep the queue intact so phone users do not lose queued steer/follow-up
        // messages. Terminal Escape still owns its native clear-and-restore path.
        sendQueueState();
        renderIndicator();
        return { aborted: true, queue: queueProjection.snapshot() };

      case "stop": {
        const session = findEditableAgentSession(ctx);
        notify(
          ctx,
          "Oppi requested a pi-tui shutdown. Current work will be interrupted and this session will exit.",
          "warning",
        );
        session?.abortCompaction?.();
        session?.abortRetry?.();
        session?.abortBash?.();
        clearQueueForShutdown(ctx);
        ctx.abort();
        ctx.shutdown();
        return { stopping: true };
      }

      case "reload":
        scheduleRuntimeReload(ctx);
        return { reloading: true };

      case "get_queue": {
        const latestQueue = refreshQueueFromRuntime();
        sendQueueState();
        renderIndicator();
        return { queue: latestQueue };
      }

      case "set_queue": {
        const baseVersion = Number(command.baseVersion);
        const steering = Array.isArray(command.steering)
          ? (command.steering as MessageQueueDraftItem[])
          : [];
        const followUp = Array.isArray(command.followUp)
          ? (command.followUp as MessageQueueDraftItem[])
          : [];
        const requestedQueue = queueProjection.queueFromDrafts(
          baseVersion,
          steering,
          followUp,
        );

        replaceLocalQueue(ctx, requestedQueue);
        sendQueueState();
        renderIndicator();
        return { queue: queueProjection.snapshot() };
      }

      case "get_state":
        return stateSnapshot(pi, ctx);

      case "get_messages":
        return { entries: ctx.sessionManager.getEntries() };

      case "get_fork_messages": {
        const messages =
          requireEditableAgentSession(ctx).getUserMessagesForForking?.();
        if (!messages)
          throw new Error(
            "Terminal Pi runtime fork messages are not attached yet",
          );
        return { messages };
      }

      case "get_session_tree":
        return sessionTreeWire(ctx, command.filterMode);

      case "navigate_tree": {
        const targetId = String(command.targetId ?? "").trim();
        if (!targetId) throw new Error("Invalid payload: expected targetId");
        const navigateTree = requireEditableAgentSession(ctx).navigateTree;
        if (!navigateTree)
          throw new Error(
            "Terminal Pi runtime tree navigation is not attached yet",
          );
        return await navigateTree(targetId, {
          summarize:
            typeof command.summarize === "boolean"
              ? command.summarize
              : undefined,
          customInstructions:
            typeof command.customInstructions === "string"
              ? command.customInstructions
              : undefined,
          replaceInstructions:
            typeof command.replaceInstructions === "boolean"
              ? command.replaceInstructions
              : undefined,
          label: typeof command.label === "string" ? command.label : undefined,
        });
      }

      case "get_session_stats": {
        const entries = ctx.sessionManager.getEntries();
        return {
          sessionFile: ctx.sessionManager.getSessionFile(),
          piSessionId: ctx.sessionManager.getSessionId(),
          totalMessages: entries.length,
          contextUsage: contextUsageWire(ctx),
        };
      }

      case "get_commands":
        return { commands: pi.getCommands() };

      case "get_available_models":
        return { models: await ctx.modelRegistry.getAvailable() };

      case "set_model": {
        const provider = String(command.provider ?? "");
        const modelId = String(command.modelId ?? command.id ?? "");
        const models = await ctx.modelRegistry.getAvailable();
        const model = models.find(
          (candidate) =>
            candidate.provider === provider && candidate.id === modelId,
        );
        if (!model) throw new Error(`Model not found: ${provider}/${modelId}`);
        const ok = await pi.setModel(model);
        if (!ok) throw new Error("No API key for this model");
        return model;
      }

      case "cycle_model": {
        const models = await ctx.modelRegistry.getAvailable();
        if (!ctx.model || models.length === 0) return null;
        const index = models.findIndex(
          (candidate) =>
            candidate.provider === ctx.model?.provider &&
            candidate.id === ctx.model?.id,
        );
        const next = models[(index + 1 + models.length) % models.length];
        await pi.setModel(next);
        return { model: next };
      }

      case "set_thinking_level":
        pi.setThinkingLevel(
          String(command.level ?? "medium") as Parameters<
            typeof pi.setThinkingLevel
          >[0],
        );
        return { level: pi.getThinkingLevel() };

      case "cycle_thinking_level": {
        const levels = [
          "off",
          "minimal",
          "low",
          "medium",
          "high",
          "xhigh",
        ] as const;
        const current = pi.getThinkingLevel();
        const next =
          levels[
            (levels.indexOf(current as (typeof levels)[number]) + 1) %
              levels.length
          ];
        pi.setThinkingLevel(next);
        return { level: pi.getThinkingLevel() };
      }

      case "set_session_name": {
        const name = String(command.name ?? "").trim();
        if (!name) throw new Error("Session name cannot be empty");
        pi.setSessionName(name);
        return { name };
      }

      case "compact":
        ctx.compact({
          customInstructions:
            typeof command.customInstructions === "string"
              ? command.customInstructions
              : undefined,
        });
        return { compacting: true };

      case "set_auto_compaction": {
        const enabled = !!command.enabled;
        const session = requireEditableAgentSession(ctx);
        if (!session.setAutoCompactionEnabled) {
          throw new Error(
            "Terminal Pi runtime auto-compaction control is not attached yet",
          );
        }
        session.setAutoCompactionEnabled(enabled);
        return { enabled };
      }

      case "set_steering_mode": {
        const mode = String(command.mode ?? "");
        if (mode !== "all" && mode !== "one-at-a-time") {
          throw new Error(
            "Invalid set_steering_mode payload: expected all or one-at-a-time",
          );
        }
        const session = requireEditableAgentSession(ctx);
        if (!session.setSteeringMode) {
          throw new Error(
            "Terminal Pi runtime steering mode control is not attached yet",
          );
        }
        session.setSteeringMode(mode);
        return { mode };
      }

      case "set_follow_up_mode": {
        const mode = String(command.mode ?? "");
        if (mode !== "all" && mode !== "one-at-a-time") {
          throw new Error(
            "Invalid set_follow_up_mode payload: expected all or one-at-a-time",
          );
        }
        const session = requireEditableAgentSession(ctx);
        if (!session.setFollowUpMode) {
          throw new Error(
            "Terminal Pi runtime follow-up mode control is not attached yet",
          );
        }
        session.setFollowUpMode(mode);
        return { mode };
      }

      case "set_auto_retry": {
        const enabled = !!command.enabled;
        const session = requireEditableAgentSession(ctx);
        if (!session.setAutoRetryEnabled) {
          throw new Error(
            "Terminal Pi runtime auto-retry control is not attached yet",
          );
        }
        session.setAutoRetryEnabled(enabled);
        return { enabled };
      }

      case "abort_retry": {
        const session = requireEditableAgentSession(ctx);
        if (!session.abortRetry) {
          throw new Error(
            "Terminal Pi runtime retry abort is not attached yet",
          );
        }
        session.abortRetry();
        return { success: true };
      }

      case "abort_bash": {
        const session = requireEditableAgentSession(ctx);
        if (!session.abortBash) {
          throw new Error("Terminal Pi runtime bash abort is not attached yet");
        }
        session.abortBash();
        return { success: true };
      }

      default:
        return type satisfies never;
    }
  }

  function mirrorAgentEventPayload(
    eventType: (typeof EVENT_TYPES)[number],
    event: unknown,
    ctx: ExtensionContext,
  ): object {
    const eventRecord = isToolTuiRecord(event) ? event : {};
    if (eventType === "tool_execution_start") {
      const toolCallId =
        typeof eventRecord.toolCallId === "string" &&
        eventRecord.toolCallId.length > 0
          ? eventRecord.toolCallId
          : undefined;
      if (toolCallId) {
        toolArgsByCallId.set(
          toolCallId,
          isToolTuiRecord(eventRecord.args) ? eventRecord.args : {},
        );
      }
      return { ...eventRecord, type: eventType };
    }

    if (eventType !== "tool_execution_end") {
      return { ...eventRecord, type: eventType };
    }

    const toolCallId =
      typeof eventRecord.toolCallId === "string" &&
      eventRecord.toolCallId.length > 0
        ? eventRecord.toolCallId
        : undefined;
    const toolName =
      typeof eventRecord.toolName === "string"
        ? eventRecord.toolName
        : undefined;
    const result = isToolTuiRecord(eventRecord.result)
      ? eventRecord.result
      : undefined;
    const session = findEditableAgentSession(ctx);
    const toolDefinition =
      toolName && shouldAttachToolTuiRenderSnapshot(toolName)
        ? session?.getToolDefinition?.(toolName)
        : undefined;

    try {
      if (toolDefinition?.renderResult && result) {
        const snapshot = renderToolTuiResultSnapshot({
          toolDefinition,
          toolCallId,
          content: Array.isArray(result.content) ? result.content : [],
          details: result.details,
          isError: eventRecord.isError === true,
          args: toolCallId ? toolArgsByCallId.get(toolCallId) : undefined,
          cwd: session?.sessionManager?.getHeader?.()?.cwd ?? ctx.cwd,
          theme: ctx.ui.theme,
        });
        if (snapshot) {
          const details = mergeToolTuiRenderSnapshot(result.details, snapshot);
          if (details) {
            return {
              ...eventRecord,
              type: eventType,
              result: {
                ...result,
                details,
              },
            };
          }
        }
      }
    } catch (error) {
      writeMirrorLog("warn", "tool_tui_render_failed", {
        tool: toolName,
        toolCallId,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      if (toolCallId) toolArgsByCallId.delete(toolCallId);
    }

    return { ...eventRecord, type: eventType };
  }

  function guardExtensionCallback<T extends unknown[]>(
    scope: string,
    callback: (...args: T) => void | Promise<void>,
  ) {
    return (...args: T) => {
      try {
        const result = callback(...args);
        if (result && typeof (result as Promise<void>).catch === "function") {
          void (result as Promise<void>).catch((error: unknown) => {
            logCallbackError(scope, error);
          });
        }
      } catch (error) {
        logCallbackError(scope, error);
      }
    };
  }

  for (const eventType of EVENT_TYPES) {
    pi.on(
      eventType as never,
      guardExtensionCallback(
        `event:${eventType}`,
        (event: unknown, ctx: ExtensionContext) => {
          latestCtx = ctx;
          if (eventType === "message_start") {
            markQueueItemStarted(
              textFromUserMessage((event as { message?: unknown }).message),
            );
            syncQueueFromEditableSession(ctx);
          }
          const includeState =
            eventType === "agent_start" ||
            eventType === "agent_end" ||
            eventType === "turn_start" ||
            eventType === "turn_end" ||
            eventType === "message_end";
          send({
            type: "event",
            event: mirrorAgentEventPayload(eventType, event, ctx),
            ...(includeState ? { state: stateSnapshot(pi, ctx) } : {}),
          });
        },
      ) as never,
    );
  }

  pi.on(
    "session_start",
    guardExtensionCallback(
      "session_start",
      (_event: unknown, ctx: ExtensionContext) => {
        latestCtx = ctx;
        if (settings.autoStart && isInteractiveTerminalProcess()) connect(ctx);
      },
    ),
  );

  pi.on(
    "session_shutdown",
    guardExtensionCallback(
      "session_shutdown",
      (event: unknown, ctx: ExtensionContext) => {
        runtimeActive = false;
        queueUpdateBridge.listeners.delete(queueUpdateListener);
        queueUpdateBridge.internalEventListeners.delete(
          internalAgentEventListener,
        );
        const shutdownReason = (event as { reason?: unknown }).reason;
        const reason =
          shutdownReason === "reload"
            ? "reload"
            : shutdownReason === "quit"
              ? "stopped"
              : "session_shutdown";
        stop(ctx, reason, { notify: false });
      },
    ),
  );

  pi.registerCommand("oppi-mirror", {
    description: "Mirror this live Pi TUI session into Oppi",
    handler: async (args, ctx) => {
      try {
        const [subcommand] = args.trim().split(/\s+/).filter(Boolean);
        switch (subcommand || "status") {
          case "start":
            connect(ctx);
            return;
          case "stop":
            stop(ctx);
            return;
          case "status":
            notify(
              ctx,
              ws?.readyState === WebSocket.OPEN
                ? `Oppi mirroring live: workspace=${connectedWorkspaceId ?? "?"} session=${connectedSessionId ?? "?"}`
                : "Oppi mirror offline",
              ws?.readyState === WebSocket.OPEN ? "info" : "warning",
            );
            return;
          default:
            notify(ctx, "Usage: /oppi-mirror start|stop|status", "warning");
        }
      } catch (error) {
        logCallbackError("command:oppi-mirror", error);
        notify(
          ctx,
          "Oppi Mirror command failed; details were logged.",
          "warning",
        );
      }
    },
  });
}
