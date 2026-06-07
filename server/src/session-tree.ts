export type SessionTreeFilterMode = "default" | "no-tools" | "user-only" | "labeled-only" | "all";

export interface SessionTreeNodeSnapshot {
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

export interface SessionTreeEntry {
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

export interface SessionTreeNode {
  entry: SessionTreeEntry;
  children: SessionTreeNode[];
  label?: string;
}

export interface SessionTreeManager {
  getTree: () => SessionTreeNode[];
  getLeafId: () => string | null;
  getEntry: (id: string) => SessionTreeEntry | undefined;
}

interface TreeToolCallSnapshot {
  name: string;
  arguments: Record<string, unknown>;
}

const MAX_TEXT_PREVIEW_CHARS = 160;
const TREE_DEFAULT_HIDDEN_ENTRY_TYPES = new Set([
  "label",
  "custom",
  "model_change",
  "thinking_level_change",
  "session_info",
]);

function toRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {};
}

function readOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

export function readSessionTreeFilterMode(value: unknown): SessionTreeFilterMode {
  switch (readOptionalString(value)) {
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

function compareTreeNodesByTimestamp(left: SessionTreeNode, right: SessionTreeNode): number {
  const leftTimestamp = left.entry.timestamp ?? "";
  const rightTimestamp = right.entry.timestamp ?? "";
  const leftTime = Date.parse(leftTimestamp);
  const rightTime = Date.parse(rightTimestamp);

  if (!Number.isNaN(leftTime) && !Number.isNaN(rightTime) && leftTime !== rightTime) {
    return leftTime - rightTime;
  }

  if (leftTimestamp !== rightTimestamp) {
    return leftTimestamp.localeCompare(rightTimestamp);
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

function collectLeafPathIds(manager: SessionTreeManager, leafId: string | null): Set<string> {
  const pathIds = new Set<string>();
  let currentId = leafId;

  while (currentId) {
    if (pathIds.has(currentId)) {
      break;
    }

    pathIds.add(currentId);
    const entry = manager.getEntry(currentId);
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

    case "branch_summary": {
      const textPreview = previewText(String(entry.summary || ""));
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

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

    case "session_info": {
      const textPreview = previewText(String(entry.name || ""));
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "model_change": {
      const textPreview = previewText(String(entry.modelId || ""));
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "thinking_level_change": {
      const textPreview = previewText(String(entry.thinkingLevel || ""));
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "label": {
      const textPreview = previewText(String(entry.label || ""));
      return {
        defaultVisible,
        ...(textPreview ? { textPreview } : {}),
      };
    }

    case "custom":
      // Pi CustomEntry records are extension persistence state. Keep tree shape,
      // but do not surface extension identifiers or data in snapshots.
      return { defaultVisible };

    default:
      return { defaultVisible };
  }
}

export function serializeSessionTree(
  manager: SessionTreeManager,
  filterMode: SessionTreeFilterMode = "default",
): {
  leafId: string | null;
  nodes: SessionTreeNodeSnapshot[];
} {
  const tree = manager.getTree();
  const leafId = manager.getLeafId();
  const leafPathIds = collectLeafPathIds(manager, leafId);
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
      parentId: current.node.entry.parentId ?? null,
      type: current.node.entry.type,
      timestamp: current.node.entry.timestamp ?? "",
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

function parseSessionTreeNode(value: unknown): SessionTreeNode {
  const nodeRecord = toRecord(value);
  const entryRecord = toRecord(nodeRecord.entry);

  if (
    typeof entryRecord.id !== "string" ||
    typeof entryRecord.type !== "string" ||
    !Array.isArray(nodeRecord.children)
  ) {
    throw new Error("pi-tui did not return session tree");
  }

  const entry: SessionTreeEntry = {
    ...entryRecord,
    id: entryRecord.id,
    type: entryRecord.type,
    parentId:
      typeof entryRecord.parentId === "string" || entryRecord.parentId === null
        ? entryRecord.parentId
        : undefined,
    timestamp: typeof entryRecord.timestamp === "string" ? entryRecord.timestamp : undefined,
  };

  return {
    entry,
    children: nodeRecord.children.map(parseSessionTreeNode),
    ...(typeof nodeRecord.label === "string" ? { label: nodeRecord.label } : {}),
  };
}

function parseSessionTreeNodes(value: unknown): SessionTreeNode[] {
  if (!Array.isArray(value)) {
    throw new Error("pi-tui did not return session tree");
  }
  return value.map(parseSessionTreeNode);
}

export function sessionTreeManagerFromTree(
  tree: SessionTreeNode[],
  leafId: string | null,
): SessionTreeManager {
  const entries = new Map<string, SessionTreeEntry>();
  const stack = [...tree];

  while (stack.length > 0) {
    const current = stack.pop();
    if (!current) continue;
    entries.set(current.entry.id, current.entry);
    for (const child of current.children) {
      stack.push(child);
    }
  }

  return {
    getTree: () => tree,
    getLeafId: () => leafId,
    getEntry: (id) => entries.get(id),
  };
}

export function serializeRawSessionTreePayload(
  payload: unknown,
  filterMode: SessionTreeFilterMode,
): {
  leafId: string | null;
  nodes: SessionTreeNodeSnapshot[];
} {
  const record = toRecord(payload);
  const leafId = typeof record.leafId === "string" ? record.leafId : null;
  const tree = parseSessionTreeNodes(record.tree);
  return serializeSessionTree(sessionTreeManagerFromTree(tree, leafId), filterMode);
}
