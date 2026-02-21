import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";
import type { Session } from "./types.js";

export interface WorkspaceGraphNode {
  id: string;
  createdAt: number;
  parentId?: string;
  workspaceId: string;
  attachedSessionIds: string[];
  activeSessionIds: string[];
  sessionFile?: string;
  parentSessionFile?: string;
}

export interface WorkspaceGraphEdge {
  from: string;
  to: string;
  type: "fork";
}

export interface WorkspaceSessionGraph {
  nodes: WorkspaceGraphNode[];
  edges: WorkspaceGraphEdge[];
  roots: string[];
}

export interface EntryGraphNode {
  id: string;
  type: string;
  parentId?: string;
  timestamp?: number;
  role?: string;
  preview?: string;
}

export interface EntryGraphEdge {
  from: string;
  to: string;
  type: "parent";
}

export interface WorkspaceEntryGraph {
  piSessionId: string;
  nodes: EntryGraphNode[];
  edges: EntryGraphEdge[];
  rootEntryId?: string;
  leafEntryId?: string;
}

export interface WorkspaceGraphResponse {
  workspaceId: string;
  generatedAt: number;
  current?: {
    sessionId: string;
    nodeId?: string;
  };
  sessionGraph: WorkspaceSessionGraph;
  entryGraph?: WorkspaceEntryGraph;
}

export interface BuildWorkspaceGraphOptions {
  workspaceId: string;
  sessions: Session[];
  activeSessionIds?: Set<string>;
  currentSessionId?: string;
  includeEntryGraph?: boolean;
  entrySessionId?: string;
  includePaths?: boolean;
}

interface SessionHeader {
  id: string;
  timestampMs: number;
  parentSessionFile?: string;
}

interface InternalNode {
  id: string;
  sessionFile: string;
  createdAt: number;
  parentSessionFile?: string;
  parentId?: string;
  attachedSessionIds: Set<string>;
  activeSessionIds: Set<string>;
}

interface ParsedEntry {
  id: string;
  type: string;
  parentId?: string;
  timestamp?: number;
  role?: string;
  preview?: string;
}

export function buildWorkspaceGraph(options: BuildWorkspaceGraphOptions): WorkspaceGraphResponse {
  const sessions = options.sessions.filter(
    (session) => session.workspaceId === options.workspaceId,
  );
  const activeSessionIds = options.activeSessionIds ?? new Set<string>();

  const candidateFiles = new Set<string>();
  for (const session of sessions) {
    if (session.piSessionFile) {
      candidateFiles.add(session.piSessionFile);
    }

    for (const path of session.piSessionFiles ?? []) {
      candidateFiles.add(path);
    }
  }

  const nodesById = new Map<string, InternalNode>();
  const fileToNodeId = new Map<string, string>();

  const queue = [...candidateFiles];
  const visitedFiles = new Set<string>();

  while (queue.length > 0) {
    const file = queue.shift();
    if (!file || visitedFiles.has(file)) {
      continue;
    }

    visitedFiles.add(file);

    const header = readSessionHeader(file);
    if (!header) {
      continue;
    }

    fileToNodeId.set(file, header.id);

    const existing = nodesById.get(header.id);
    if (!existing) {
      nodesById.set(header.id, {
        id: header.id,
        sessionFile: file,
        createdAt: header.timestampMs,
        parentSessionFile: header.parentSessionFile,
        attachedSessionIds: new Set<string>(),
        activeSessionIds: new Set<string>(),
      });
    } else {
      if (
        header.timestampMs !== 0 &&
        (existing.createdAt === 0 || header.timestampMs < existing.createdAt)
      ) {
        existing.createdAt = header.timestampMs;
      }

      if (!existing.parentSessionFile && header.parentSessionFile) {
        existing.parentSessionFile = header.parentSessionFile;
      }

      if (existing.sessionFile !== file && shouldPreferSessionFile(file, existing.sessionFile)) {
        existing.sessionFile = file;
      }
    }

    if (header.parentSessionFile && !visitedFiles.has(header.parentSessionFile)) {
      queue.push(header.parentSessionFile);
    }
  }

  for (const node of nodesById.values()) {
    const parentFile = node.parentSessionFile;
    if (!parentFile) {
      continue;
    }

    const knownParent = fileToNodeId.get(parentFile);
    if (knownParent) {
      node.parentId = knownParent;
      continue;
    }

    const parsedParent = parseSessionIdFromFile(parentFile);
    if (parsedParent && nodesById.has(parsedParent)) {
      node.parentId = parsedParent;
    }
  }

  for (const session of sessions) {
    const files = normalizeSessionFiles(session);

    for (const node of nodesById.values()) {
      const attached = session.piSessionId === node.id || files.has(node.sessionFile);
      if (!attached) {
        continue;
      }

      node.attachedSessionIds.add(session.id);

      const isCurrent =
        session.piSessionId === node.id || session.piSessionFile === node.sessionFile;
      if (isCurrent && activeSessionIds.has(session.id)) {
        node.activeSessionIds.add(session.id);
      }
    }
  }

  const sortedNodes = Array.from(nodesById.values()).sort((a, b) => {
    if (a.createdAt !== b.createdAt) {
      return a.createdAt - b.createdAt;
    }
    return a.id.localeCompare(b.id);
  });

  const edges: WorkspaceGraphEdge[] = [];
  for (const node of sortedNodes) {
    if (!node.parentId || !nodesById.has(node.parentId)) {
      continue;
    }

    edges.push({
      from: node.parentId,
      to: node.id,
      type: "fork",
    });
  }

  const roots = sortedNodes
    .filter((node) => !node.parentId || !nodesById.has(node.parentId))
    .map((node) => node.id);

  const includePaths = options.includePaths === true;
  const sessionGraphNodes: WorkspaceGraphNode[] = sortedNodes.map((node) => {
    const baseNode: WorkspaceGraphNode = {
      id: node.id,
      createdAt: node.createdAt,
      parentId: node.parentId,
      workspaceId: options.workspaceId,
      attachedSessionIds: Array.from(node.attachedSessionIds).sort(),
      activeSessionIds: Array.from(node.activeSessionIds).sort(),
    };

    if (includePaths) {
      baseNode.sessionFile = node.sessionFile;
      baseNode.parentSessionFile = node.parentSessionFile;
    }

    return baseNode;
  });

  let current:
    | {
        sessionId: string;
        nodeId?: string;
      }
    | undefined;

  if (options.currentSessionId) {
    const session = sessions.find((item) => item.id === options.currentSessionId);
    if (session) {
      current = {
        sessionId: session.id,
        nodeId: resolveCurrentNodeId(session, nodesById, fileToNodeId),
      };
    }
  }

  let entryGraph: WorkspaceEntryGraph | undefined;
  if (options.includeEntryGraph) {
    const targetNodeId = options.entrySessionId || current?.nodeId;
    if (targetNodeId) {
      const targetNode = nodesById.get(targetNodeId);
      if (targetNode) {
        entryGraph = buildEntryGraph(targetNode.id, targetNode.sessionFile);
      }
    }
  }

  return {
    workspaceId: options.workspaceId,
    generatedAt: Date.now(),
    current,
    sessionGraph: {
      nodes: sessionGraphNodes,
      edges,
      roots,
    },
    entryGraph,
  };
}

function normalizeSessionFiles(session: Session): Set<string> {
  const files = new Set<string>();
  if (session.piSessionFile) {
    files.add(session.piSessionFile);
  }
  for (const path of session.piSessionFiles ?? []) {
    files.add(path);
  }
  return files;
}

function resolveCurrentNodeId(
  session: Session,
  nodesById: Map<string, InternalNode>,
  fileToNodeId: Map<string, string>,
): string | undefined {
  if (session.piSessionId && nodesById.has(session.piSessionId)) {
    return session.piSessionId;
  }

  if (session.piSessionFile) {
    return fileToNodeId.get(session.piSessionFile);
  }

  return undefined;
}

function shouldPreferSessionFile(candidate: string, current: string): boolean {
  return candidate.localeCompare(current) < 0;
}

function readSessionHeader(path: string): SessionHeader | null {
  if (!existsSync(path)) {
    return null;
  }

  let content: string;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    return null;
  }

  const newline = content.indexOf("\n");
  const firstLine = (newline >= 0 ? content.slice(0, newline) : content).trim();
  if (!firstLine) {
    return null;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(firstLine) as unknown;
  } catch {
    return null;
  }

  const record = asRecord(parsed);
  if (!record) {
    return null;
  }

  if (record.type !== "session") {
    return null;
  }

  const id = asString(record.id);
  if (!id) {
    return null;
  }

  return {
    id,
    timestampMs: parseTimestampToMs(record.timestamp),
    parentSessionFile: asString(record.parentSession),
  };
}

function parseTimestampToMs(raw: unknown): number {
  const timestamp = asString(raw);
  if (!timestamp) {
    return 0;
  }

  const ms = Date.parse(timestamp);
  return Number.isFinite(ms) ? ms : 0;
}

function parseSessionIdFromFile(path: string): string | undefined {
  const file = basename(path);
  const match = file.match(/_([0-9a-fA-F-]{36})\.jsonl$/);
  return match?.[1];
}

function buildEntryGraph(piSessionId: string, path: string): WorkspaceEntryGraph | undefined {
  if (!existsSync(path)) {
    return undefined;
  }

  let content: string;
  try {
    content = readFileSync(path, "utf8");
  } catch {
    return undefined;
  }

  const parsedEntries: ParsedEntry[] = [];

  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed) as unknown;
    } catch {
      continue;
    }

    const record = asRecord(parsed);
    if (!record) {
      continue;
    }

    const id = asString(record.id);
    if (!id) {
      continue;
    }

    const type = asString(record.type) || "unknown";

    const entry: ParsedEntry = {
      id,
      type,
      parentId: asString(record.parentId) || undefined,
      timestamp: parseTimestampToMs(record.timestamp),
    };

    if (type === "message") {
      const message = asRecord(record.message);
      if (message) {
        entry.role = asString(message.role) || undefined;
        entry.preview = extractMessagePreview(message.content);
      }
    }

    parsedEntries.push(entry);
  }

  if (parsedEntries.length === 0) {
    return undefined;
  }

  const nodeIds = new Set(parsedEntries.map((entry) => entry.id));

  const edges: EntryGraphEdge[] = [];
  for (const entry of parsedEntries) {
    if (!entry.parentId || !nodeIds.has(entry.parentId)) {
      continue;
    }

    edges.push({
      from: entry.parentId,
      to: entry.id,
      type: "parent",
    });
  }

  const rootEntryId = parsedEntries.find(
    (entry) => !entry.parentId || !nodeIds.has(entry.parentId),
  )?.id;
  const leafEntryId = parsedEntries[parsedEntries.length - 1]?.id;

  return {
    piSessionId,
    nodes: parsedEntries,
    edges,
    rootEntryId,
    leafEntryId,
  };
}

function extractMessagePreview(content: unknown): string | undefined {
  const text = extractTextContent(content).trim();
  if (!text) {
    return undefined;
  }

  if (text.length <= 160) {
    return text;
  }

  return `${text.slice(0, 159)}…`;
}

function extractTextContent(content: unknown): string {
  if (typeof content === "string") {
    return content;
  }

  if (!Array.isArray(content)) {
    return "";
  }

  const chunks: string[] = [];
  for (const block of content) {
    const record = asRecord(block);
    if (!record) {
      continue;
    }

    const type = asString(record.type);
    const text = asString(record.text);

    if ((type === "text" || type === "output_text") && text) {
      chunks.push(text);
    }
  }

  return chunks.join("\n");
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  return value as Record<string, unknown>;
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
