import { formatSkillsForPrompt, type AgentSession } from "@mariozechner/pi-coding-agent";

import { parsePiStateSnapshot, type PiStateSnapshot } from "./pi-events.js";
import { createLogger } from "./logger.js";
import { normalizeCommandError } from "./session-protocol.js";
import {
  shareSession,
  type ShareSessionAction,
  type ShareSessionRedactionPolicyInput,
} from "./session-share.js";
import { composeModelId, type SessionStateActiveSession } from "./session-state.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Session, ServerMessage } from "./types.js";

const log = createLogger({ base: { component: "session_commands" } });

function toRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function readCompactInstructions(command: Record<string, unknown>): string | undefined {
  if (typeof command.customInstructions !== "string") {
    return undefined;
  }

  const trimmed = command.customInstructions.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function toCommandLocation(value: string | undefined): "user" | "project" | "path" | undefined {
  if (value === "user" || value === "project" || value === "path") {
    return value;
  }
  return undefined;
}

interface SessionCommandDescriptor {
  name: string;
  description?: string;
  source: "builtin" | "extension" | "prompt" | "skill";
  location?: "user" | "project" | "path";
  path?: string;
}

interface ContextFileTokenSnapshot {
  path: string;
  chars: number;
  tokens: number;
}

interface SessionContextCompositionSnapshot {
  piSystemPromptChars: number;
  piSystemPromptTokens: number;
  agentsChars: number;
  agentsTokens: number;
  agentsFiles: ContextFileTokenSnapshot[];
  skillsListingChars: number;
  skillsListingTokens: number;
}

function estimateTokensFromChars(chars: number): number {
  if (chars <= 0) {
    return 0;
  }
  return Math.max(1, Math.ceil(chars / 4));
}

function collectSessionContextComposition(
  session: AgentSession,
): SessionContextCompositionSnapshot {
  const piSystemPromptChars = session.systemPrompt.length;
  const piSystemPromptTokens = estimateTokensFromChars(piSystemPromptChars);

  const agentsFiles = session.resourceLoader.getAgentsFiles().agentsFiles.map((file) => {
    const chars = file.content.length;
    return {
      path: file.path,
      chars,
      tokens: estimateTokensFromChars(chars),
    };
  });

  const agentsChars = agentsFiles.reduce((sum, file) => sum + file.chars, 0);
  const agentsTokens = agentsFiles.reduce((sum, file) => sum + file.tokens, 0);

  const skillsListing = formatSkillsForPrompt(session.resourceLoader.getSkills().skills);
  const skillsListingChars = skillsListing.length;
  const skillsListingTokens = estimateTokensFromChars(skillsListingChars);

  return {
    piSystemPromptChars,
    piSystemPromptTokens,
    agentsChars,
    agentsTokens,
    agentsFiles,
    skillsListingChars,
    skillsListingTokens,
  };
}

const BUILTIN_SLASH_COMMANDS: readonly SessionCommandDescriptor[] = [
  {
    name: "share",
    description: "Share session as an auto-redacted secret GitHub gist",
    source: "builtin",
  },
];

function collectSessionCommands(session: AgentSession): { commands: SessionCommandDescriptor[] } {
  const commands: SessionCommandDescriptor[] = [...BUILTIN_SLASH_COMMANDS];

  for (const command of session.extensionRunner?.getRegisteredCommands() ?? []) {
    commands.push({
      name: command.name,
      description: command.description,
      source: "extension",
      path: command.sourceInfo.path,
    });
  }

  for (const template of session.promptTemplates) {
    commands.push({
      name: template.name,
      description: template.description,
      source: "prompt",
      location: toCommandLocation(template.sourceInfo.source),
      path: template.filePath,
    });
  }

  for (const skill of session.resourceLoader.getSkills().skills) {
    commands.push({
      name: `skill:${skill.name}`,
      description: skill.description,
      source: "skill",
      location: toCommandLocation(skill.sourceInfo.source),
      path: skill.filePath,
    });
  }

  return { commands };
}

type SessionTreeFilterMode = "default" | "no-tools" | "user-only" | "labeled-only" | "all";

interface SessionTreeNodeSnapshot {
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

type SessionTreeNode = ReturnType<AgentSession["sessionManager"]["getTree"]>[number];
type SessionTreeEntry = SessionTreeNode["entry"];

const MAX_TEXT_PREVIEW_CHARS = 160;
const TREE_DEFAULT_HIDDEN_ENTRY_TYPES = new Set([
  "label",
  "custom",
  "model_change",
  "thinking_level_change",
  "session_info",
]);

interface TreeToolCallSnapshot {
  name: string;
  arguments: Record<string, unknown>;
}

function compareTreeNodesByTimestamp(left: SessionTreeNode, right: SessionTreeNode): number {
  const leftTime = Date.parse(left.entry.timestamp);
  const rightTime = Date.parse(right.entry.timestamp);

  if (!Number.isNaN(leftTime) && !Number.isNaN(rightTime) && leftTime !== rightTime) {
    return leftTime - rightTime;
  }

  if (left.entry.timestamp !== right.entry.timestamp) {
    return left.entry.timestamp.localeCompare(right.entry.timestamp);
  }

  return left.entry.id.localeCompare(right.entry.id);
}

function sortTreeNodes(nodes: SessionTreeNode[], leafPathIds: Set<string>): SessionTreeNode[] {
  return [...nodes].sort((left, right) => {
    const leftOnActivePath = leafPathIds.has(left.entry.id) ? 1 : 0;
    const rightOnActivePath = leafPathIds.has(right.entry.id) ? 1 : 0;

    if (leftOnActivePath !== rightOnActivePath) {
      return rightOnActivePath - leftOnActivePath;
    }

    return compareTreeNodesByTimestamp(left, right);
  });
}

function collectLeafPathIds(session: AgentSession, leafId: string | null): Set<string> {
  const pathIds = new Set<string>();
  let currentId = leafId;

  while (currentId) {
    if (pathIds.has(currentId)) {
      break;
    }

    pathIds.add(currentId);
    const entry = session.sessionManager.getEntry(currentId);
    currentId = entry?.parentId ?? null;
  }

  return pathIds;
}

function previewText(rawText: string): string | undefined {
  const normalized = rawText.replace(/\s+/g, " ").trim();
  if (normalized.length === 0) {
    return undefined;
  }

  if (normalized.length <= MAX_TEXT_PREVIEW_CHARS) {
    return normalized;
  }

  return `${normalized.slice(0, MAX_TEXT_PREVIEW_CHARS - 1)}…`;
}

function extractDisplayTextFromMessageContent(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  const parts: string[] = [];
  for (const block of content) {
    const record = toRecord(block);

    if (
      (record.type === "text" || record.type === "output_text") &&
      typeof record.text === "string"
    ) {
      parts.push(record.text);
    }
  }

  return parts.join(" ");
}

function hasDisplayTextContent(content: unknown): boolean {
  return previewText(extractDisplayTextFromMessageContent(content)) !== undefined;
}

function shortenTreePath(path: string): string {
  const home = process.env.HOME || process.env.USERPROFILE || "";
  if (home && path.startsWith(home)) {
    return `~${path.slice(home.length)}`;
  }
  return path;
}

function formatTreeToolCall(name: string, args: Record<string, unknown>): string {
  switch (name) {
    case "read": {
      const path = shortenTreePath(String(args.path || ""));
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

    case "write": {
      const path = shortenTreePath(String(args.path || ""));
      return `[write: ${path}]`;
    }

    case "edit": {
      const path = shortenTreePath(String(args.path || ""));
      return `[edit: ${path}]`;
    }

    case "bash": {
      const rawCommand = String(args.command || "");
      const command = rawCommand
        .replace(/[\n\t]/g, " ")
        .trim()
        .slice(0, 50);
      return `[bash: ${command}${rawCommand.length > 50 ? "..." : ""}]`;
    }

    case "grep": {
      const pattern = String(args.pattern || "");
      const path = shortenTreePath(String(args.path || "."));
      return `[grep: /${pattern}/ in ${path}]`;
    }

    case "find": {
      const pattern = String(args.pattern || "");
      const path = shortenTreePath(String(args.path || "."));
      return `[find: ${pattern} in ${path}]`;
    }

    case "ls": {
      const path = shortenTreePath(String(args.path || "."));
      return `[ls: ${path}]`;
    }

    default: {
      const argsJson = JSON.stringify(args);
      const preview = argsJson.slice(0, 40);
      return `[${name}: ${preview}${argsJson.length > 40 ? "..." : ""}]`;
    }
  }
}

function collectTreeToolCalls(tree: SessionTreeNode[]): Map<string, TreeToolCallSnapshot> {
  const toolCalls = new Map<string, TreeToolCallSnapshot>();
  const stack = [...tree];

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) {
      continue;
    }

    const entry = current.entry;
    if (entry.type === "message") {
      const message = toRecord(entry.message);
      if (message.role === "assistant" && Array.isArray(message.content)) {
        for (const block of message.content) {
          const record = toRecord(block);
          if (
            record.type === "toolCall" &&
            typeof record.id === "string" &&
            typeof record.name === "string"
          ) {
            toolCalls.set(record.id, {
              name: record.name,
              arguments: toRecord(record.arguments),
            });
          }
        }
      }
    }

    for (const child of current.children) {
      stack.push(child);
    }
  }

  return toolCalls;
}

function isTreeEntryEligibleForFilters(entry: SessionTreeEntry, leafId: string | null): boolean {
  if (entry.type !== "message" || entry.id === leafId) {
    return true;
  }

  const message = toRecord(entry.message);
  if (message.role !== "assistant") {
    return true;
  }

  const hasText = hasDisplayTextContent(message.content);
  const stopReason = typeof message.stopReason === "string" ? message.stopReason : undefined;
  const isErrorOrAborted =
    stopReason !== undefined && stopReason !== "stop" && stopReason !== "toolUse";

  return hasText || isErrorOrAborted;
}

function isTreeEntryVisibleByDefault(entry: SessionTreeEntry, leafId: string | null): boolean {
  return (
    isTreeEntryEligibleForFilters(entry, leafId) && !TREE_DEFAULT_HIDDEN_ENTRY_TYPES.has(entry.type)
  );
}

function matchesSessionTreeFilter(
  node: SessionTreeNode,
  filterMode: SessionTreeFilterMode,
  leafId: string | null,
): boolean {
  if (!isTreeEntryEligibleForFilters(node.entry, leafId)) {
    return false;
  }

  const entry = node.entry;
  const isSettingsEntry = TREE_DEFAULT_HIDDEN_ENTRY_TYPES.has(entry.type);

  switch (filterMode) {
    case "user-only":
      return entry.type === "message" && toRecord(entry.message).role === "user";

    case "no-tools":
      return (
        !isSettingsEntry &&
        !(entry.type === "message" && toRecord(entry.message).role === "toolResult")
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

function extractTreeNodeSnapshot(
  entry: SessionTreeEntry,
  toolCalls: Map<string, TreeToolCallSnapshot>,
  leafId: string | null,
): { defaultVisible: boolean; role?: string; textPreview?: string } {
  const defaultVisible = isTreeEntryVisibleByDefault(entry, leafId);

  switch (entry.type) {
    case "message": {
      const message = toRecord(entry.message);
      const role = typeof message.role === "string" ? message.role : undefined;
      let textPreview: string | undefined;

      switch (role) {
        case "toolResult": {
          const toolCallId =
            typeof message.toolCallId === "string" ? message.toolCallId : undefined;
          const toolCall = toolCallId ? toolCalls.get(toolCallId) : undefined;
          textPreview = toolCall
            ? formatTreeToolCall(toolCall.name, toolCall.arguments)
            : typeof message.toolName === "string"
              ? `[${message.toolName}]`
              : undefined;
          break;
        }

        case "bashExecution": {
          const command = typeof message.command === "string" ? message.command : "";
          textPreview = previewText(command);
          break;
        }

        default:
          textPreview = previewText(extractDisplayTextFromMessageContent(message.content));
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

    case "branch_summary":
      return {
        defaultVisible,
        ...(previewText(entry.summary) ? { textPreview: previewText(entry.summary) } : {}),
      };

    case "custom_message": {
      const rawContent =
        typeof entry.content === "string"
          ? entry.content
          : extractDisplayTextFromMessageContent(entry.content);
      const textPreview = previewText(rawContent);
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "session_info":
      return {
        defaultVisible,
        ...(previewText(entry.name || "") ? { textPreview: previewText(entry.name || "") } : {}),
      };

    case "model_change":
      return {
        defaultVisible,
        ...(previewText(entry.modelId || "")
          ? { textPreview: previewText(entry.modelId || "") }
          : {}),
      };

    case "thinking_level_change":
      return {
        defaultVisible,
        ...(previewText(entry.thinkingLevel || "")
          ? { textPreview: previewText(entry.thinkingLevel || "") }
          : {}),
      };

    case "label":
      return {
        defaultVisible,
        ...(previewText(entry.label || "") ? { textPreview: previewText(entry.label || "") } : {}),
      };

    case "custom":
      return {
        defaultVisible,
        ...(previewText(entry.customType || "")
          ? { textPreview: previewText(entry.customType || "") }
          : {}),
      };

    default:
      return { defaultVisible };
  }
}

function serializeSessionTree(
  session: AgentSession,
  filterMode: SessionTreeFilterMode = "default",
): {
  leafId: string | null;
  nodes: SessionTreeNodeSnapshot[];
} {
  const tree = session.sessionManager.getTree();
  const leafId = session.sessionManager.getLeafId();
  const leafPathIds = collectLeafPathIds(session, leafId);
  const toolCalls = collectTreeToolCalls(tree);

  const nodes: SessionTreeNodeSnapshot[] = [];
  const stack = sortTreeNodes(tree, leafPathIds)
    .reverse()
    .map((node) => ({ node, depth: 0 }));

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) {
      continue;
    }

    const extracted = extractTreeNodeSnapshot(current.node.entry, toolCalls, leafId);
    const snapshot: SessionTreeNodeSnapshot = {
      id: current.node.entry.id,
      parentId: current.node.entry.parentId,
      type: current.node.entry.type,
      timestamp: current.node.entry.timestamp,
      depth: current.depth,
      isLeafPath: leafPathIds.has(current.node.entry.id),
      matchesFilter: matchesSessionTreeFilter(current.node, filterMode, leafId),
      ...extracted,
      ...(current.node.label
        ? {
            label: current.node.label,
          }
        : {}),
    };

    nodes.push(snapshot);

    const children = sortTreeNodes(current.node.children, leafPathIds);
    for (let i = children.length - 1; i >= 0; i -= 1) {
      const child = children[i];
      if (child) {
        stack.push({
          node: child,
          depth: current.depth + 1,
        });
      }
    }
  }

  return { leafId, nodes };
}

function readOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function readRequiredString(value: unknown, fieldName: string): string {
  const parsed = readOptionalString(value);
  if (!parsed) {
    throw new Error(`Invalid payload: expected ${fieldName}`);
  }
  return parsed;
}

function readOptionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function readSessionTreeFilterMode(command: Record<string, unknown>): SessionTreeFilterMode {
  switch (readOptionalString(command.filterMode)) {
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

function readShareSessionAction(command: Record<string, unknown>): ShareSessionAction {
  return command.action === "prepare" ? "prepare" : "publish";
}

function readShareSessionRedactionPolicy(
  command: Record<string, unknown>,
): ShareSessionRedactionPolicyInput | undefined {
  const raw = toRecord(command.redactionPolicy);
  if (Object.keys(raw).length === 0) {
    return undefined;
  }

  return {
    secrets: readOptionalBoolean(raw.secrets),
    emails: readOptionalBoolean(raw.emails),
    phones: readOptionalBoolean(raw.phones),
    userPaths: readOptionalBoolean(raw.userPaths),
    ipAddresses: readOptionalBoolean(raw.ipAddresses),
    jwtAndBearer: readOptionalBoolean(raw.jwtAndBearer),
    namesHeuristic: readOptionalBoolean(raw.namesHeuristic),
  };
}

export interface CommandSessionState extends SessionStateActiveSession {
  session: Session;
  sdkBackend: SdkBackend;
}

export interface SessionCommandCoordinatorDeps {
  getActiveSession: (key: string) => CommandSessionState | undefined;
  persistSessionNow: (key: string, session: Session) => void;
  broadcast: (key: string, message: ServerMessage) => void;
  applyPiStateSnapshot: (session: Session, state: PiStateSnapshot | null | undefined) => boolean;
  getContextWindowResolver: () => ((modelId: string) => number) | null;
}

type BackendCommandHandler = (
  backend: SdkBackend,
  cmd: Record<string, unknown>,
) => unknown | Promise<unknown>;

type SessionCommandHandler = (
  session: AgentSession,
  cmd: Record<string, unknown>,
) => unknown | Promise<unknown>;

export class SessionCommandCoordinator {
  constructor(private readonly deps: SessionCommandCoordinatorDeps) {}

  private static readonly SERVER_LOGIC_HANDLERS = new Map<string, BackendCommandHandler>([
    ["get_state", (backend) => backend.getStateSnapshot()],

    [
      "set_model",
      async (backend, cmd) => {
        const modelFromCommand =
          typeof cmd.model === "string" && cmd.model.trim().length > 0
            ? cmd.model.trim()
            : undefined;
        const modelFromParts =
          typeof cmd.provider === "string" &&
          cmd.provider.trim().length > 0 &&
          typeof cmd.modelId === "string" &&
          cmd.modelId.trim().length > 0
            ? composeModelId(cmd.provider.trim(), cmd.modelId.trim())
            : undefined;
        const model = modelFromCommand ?? modelFromParts;
        if (!model) {
          throw new Error("Invalid set_model payload: expected model or provider+modelId");
        }

        const result = await backend.setModel(model);
        if (!result.success) {
          throw new Error(result.error);
        }
        return result;
      },
    ],

    ["cycle_model", (backend, cmd) => backend.session.cycleModel(cmd.direction as never)],

    [
      "set_thinking_level",
      (backend, cmd) => {
        backend.session.setThinkingLevel(
          cmd.level as Parameters<AgentSession["setThinkingLevel"]>[0],
        );
        return { level: cmd.level };
      },
    ],

    ["cycle_thinking_level", (backend) => ({ level: backend.session.cycleThinkingLevel() })],

    [
      "new_session",
      async (backend) => {
        await backend.newSession();
        return { success: true };
      },
    ],

    [
      "set_session_name",
      (backend, cmd) => {
        backend.session.setSessionName(cmd.name as string);
        return { name: cmd.name };
      },
    ],

    ["fork", (backend, cmd) => backend.fork(cmd.entryId as string)],
    ["switch_session", (backend, cmd) => backend.switchSession(cmd.sessionPath as string)],
  ]);

  private static readonly SESSION_PASSTHROUGH_HANDLERS = new Map<string, SessionCommandHandler>([
    ["get_messages", (session) => session.messages],
    ["get_fork_messages", (session) => ({ messages: session.getUserMessagesForForking() })],
    [
      "get_session_tree",
      (session, cmd) => serializeSessionTree(session, readSessionTreeFilterMode(cmd)),
    ],
    [
      "navigate_tree",
      (session, cmd) =>
        session.navigateTree(readRequiredString(cmd.targetId, "targetId"), {
          summarize: readOptionalBoolean(cmd.summarize),
          customInstructions: readOptionalString(cmd.customInstructions),
          replaceInstructions: readOptionalBoolean(cmd.replaceInstructions),
          label: readOptionalString(cmd.label),
        }),
    ],
    [
      "get_session_stats",
      (session) => ({
        ...session.getSessionStats(),
        contextComposition: collectSessionContextComposition(session),
      }),
    ],
    ["get_available_models", () => []],
    ["get_commands", (session) => collectSessionCommands(session)],
    [
      "share_session",
      (session, cmd) =>
        shareSession(
          session,
          {},
          {
            action: readShareSessionAction(cmd),
            redactionPolicy: readShareSessionRedactionPolicy(cmd),
          },
        ),
    ],

    ["compact", (session, cmd) => session.compact(readCompactInstructions(cmd))],

    [
      "set_auto_compaction",
      (session, cmd) => {
        session.setAutoCompactionEnabled(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],

    [
      "set_steering_mode",
      (session, cmd) => {
        session.setSteeringMode(cmd.mode as "all" | "one-at-a-time");
        return { mode: cmd.mode };
      },
    ],

    [
      "set_follow_up_mode",
      (session, cmd) => {
        session.setFollowUpMode(cmd.mode as "all" | "one-at-a-time");
        return { mode: cmd.mode };
      },
    ],

    [
      "set_auto_retry",
      (session, cmd) => {
        session.setAutoRetryEnabled(!!cmd.enabled);
        return { enabled: !!cmd.enabled };
      },
    ],

    [
      "abort_retry",
      (session) => {
        session.abortRetry();
        return { success: true };
      },
    ],

    [
      "abort_bash",
      (session) => {
        session.abortBash();
        return { success: true };
      },
    ],
  ]);

  private static readonly ALLOWED_COMMANDS = new Set<string>([
    ...SessionCommandCoordinator.SERVER_LOGIC_HANDLERS.keys(),
    ...SessionCommandCoordinator.SESSION_PASSTHROUGH_HANDLERS.keys(),
  ]);

  isAllowedCommand(commandType: string): boolean {
    return SessionCommandCoordinator.ALLOWED_COMMANDS.has(commandType);
  }

  sendCommand(key: string, command: Record<string, unknown>): void {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return;
    }

    this.routeSdkCommand(active.sdkBackend, command);
  }

  async sendCommandAsync(key: string, command: Record<string, unknown>): Promise<unknown> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error("Session not active");
    }

    const type = command.type as string;
    const backendHandler = SessionCommandCoordinator.SERVER_LOGIC_HANDLERS.get(type);
    if (backendHandler) {
      return backendHandler(active.sdkBackend, command);
    }

    const sessionHandler = SessionCommandCoordinator.SESSION_PASSTHROUGH_HANDLERS.get(type);
    if (!sessionHandler) {
      throw new Error(`Unhandled SDK command: ${type}`);
    }

    return sessionHandler(active.sdkBackend.session, command);
  }

  async forwardClientCommand(
    key: string,
    message: Record<string, unknown>,
    requestId: string | undefined,
    sendCommandAsync: (key: string, command: Record<string, unknown>) => Promise<unknown>,
  ): Promise<void> {
    const cmdType = message.type as string;
    if (!this.isAllowedCommand(cmdType)) {
      throw new Error(`Command not allowed: ${cmdType}`);
    }

    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    try {
      const rpcData: unknown = await sendCommandAsync(key, { ...message });
      const rpcObject = toRecord(rpcData);

      if (cmdType === "get_state") {
        const snapshot = parsePiStateSnapshot(rpcData);
        if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
          this.deps.persistSessionNow(key, active.session);
          // Broadcast updated session so clients see model/thinking/name changes
          this.deps.broadcast(key, { type: "state", session: active.session });
        }
      }

      // Track thinking level changes so the session object stays in sync
      if (cmdType === "cycle_thinking_level" || cmdType === "set_thinking_level") {
        const levelFromResponse =
          typeof rpcObject.level === "string" && rpcObject.level.trim().length > 0
            ? rpcObject.level.trim()
            : undefined;
        const levelFromRequest =
          cmdType === "set_thinking_level" &&
          typeof message.level === "string" &&
          message.level.trim().length > 0
            ? message.level.trim()
            : undefined;

        const effectiveLevel = levelFromResponse ?? levelFromRequest;
        if (effectiveLevel && active.session.thinkingLevel !== effectiveLevel) {
          active.session.thinkingLevel = effectiveLevel;
          this.deps.persistSessionNow(key, active.session);
        }
      }

      // Track model changes so the session object stays in sync
      if (cmdType === "set_model" || cmdType === "cycle_model") {
        // set_model returns the model object, cycle_model returns { model, thinkingLevel, isScoped }
        const modelData = cmdType === "cycle_model" ? toRecord(rpcObject.model) : rpcObject;
        const provider = modelData.provider;
        const modelId = modelData.id;
        if (typeof provider === "string" && typeof modelId === "string") {
          const fullId = composeModelId(provider, modelId);
          if (active.session.model !== fullId) {
            active.session.model = fullId;
            const contextWindowResolver = this.deps.getContextWindowResolver();
            if (contextWindowResolver) {
              active.session.contextWindow = contextWindowResolver(fullId);
            }
            this.deps.persistSessionNow(key, active.session);
          }
        }

        // Pi returns the clamped thinkingLevel for the active model.
        if (
          typeof rpcObject.thinkingLevel === "string" &&
          rpcObject.thinkingLevel.trim().length > 0
        ) {
          active.session.thinkingLevel = rpcObject.thinkingLevel.trim();
          this.deps.persistSessionNow(key, active.session);
        }
      }

      // Track session name changes so optimistic client renames don't get
      // overwritten by stale local get_state snapshots.
      if (cmdType === "set_session_name") {
        const requestedName = typeof message.name === "string" ? message.name.trim() : "";
        const responseName = typeof rpcObject.name === "string" ? rpcObject.name.trim() : "";
        const nextName = responseName.length > 0 ? responseName : requestedName;
        if (nextName.length > 0 && active.session.name !== nextName) {
          active.session.name = nextName;
          this.deps.persistSessionNow(key, active.session);
        }
      }

      // Session-branching commands mutate pi session identity/file in-place.
      // Refresh state immediately so reconnect/resume uses the new branch.
      if (
        cmdType === "fork" ||
        cmdType === "new_session" ||
        cmdType === "switch_session" ||
        cmdType === "navigate_tree"
      ) {
        try {
          const refreshed = await sendCommandAsync(key, { type: "get_state" });
          const snapshot = parsePiStateSnapshot(refreshed);
          if (snapshot && this.deps.applyPiStateSnapshot(active.session, snapshot)) {
            this.deps.persistSessionNow(key, active.session);
            this.deps.broadcast(key, { type: "state", session: active.session });
          }
        } catch (stateErr) {
          const message = stateErr instanceof Error ? stateErr.message : String(stateErr);
          log.warn("session_commands.state_refresh.failed", {
            sessionId: active.session.id,
            commandType: cmdType,
            error: message,
          });
        }
      }

      this.deps.broadcast(key, {
        type: "command_result",
        command: cmdType,
        requestId,
        success: true,
        data: rpcData,
      });

      // Broadcast updated session state after model/thinking/name changes
      // so clients see the change immediately without waiting for next agent event
      if (
        cmdType === "set_model" ||
        cmdType === "cycle_model" ||
        cmdType === "set_thinking_level" ||
        cmdType === "cycle_thinking_level" ||
        cmdType === "set_session_name"
      ) {
        this.deps.broadcast(key, { type: "state", session: active.session });
      }
    } catch (err) {
      const rawError = err instanceof Error ? err.message : String(err);
      this.deps.broadcast(key, {
        type: "command_result",
        command: cmdType,
        requestId,
        success: false,
        error: normalizeCommandError(cmdType, rawError),
      });
    }
  }

  private routeSdkCommand(backend: SdkBackend, command: Record<string, unknown>): void {
    const type = command.type as string;
    switch (type) {
      case "prompt":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: command.streamingBehavior as "steer" | "followUp" | undefined,
        });
        break;
      case "steer":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "steer",
        });
        break;
      case "follow_up":
        backend.prompt(command.message as string, {
          images: command.images as Array<{ type: "image"; data: string; mimeType: string }>,
          streamingBehavior: "followUp",
        });
        break;
      case "abort":
        void backend.abort();
        break;
      default:
        log.warn("session_commands.unhandled_fire_and_forget_command", {
          commandType: type,
        });
    }
  }
}
