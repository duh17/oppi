import { createHash } from "node:crypto";
import { closeSync, createReadStream, fstatSync, openSync, readSync } from "node:fs";
import { realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";

import { resourceUsageActionId } from "./resource-usage-service.js";
import {
  RESOURCE_USAGE_RETENTION_DAYS,
  type ResourceUsageEvent,
  type ResourceUsageOwnerKind,
  type ResourceUsageRuntime,
  type ResourceUsageSignal,
  type ResourceUsageStore,
} from "./storage/resource-usage-store.js";
import type { Session } from "./types.js";

const DEFAULT_BATCH_SIZE = 500;
const DEFAULT_MAX_LINE_BYTES = 4 * 1024 * 1024;
const RETENTION_MS = RESOURCE_USAGE_RETENTION_DAYS * 86_400_000;
const RESOURCE_MARKER_TYPE = "oppi-resource-usage";

export interface ResourceUsageBackfillSource {
  sourceKey: string;
  path: string;
  sessionId: string;
  workspaceId?: string;
  runtime: ResourceUsageRuntime;
}

export interface ResourceUsageBackfillCatalog {
  skills: ReadonlyMap<string, string>;
  commands: ReadonlyMap<string, { ownerKind: ResourceUsageOwnerKind; ownerId: string }>;
  tools: ReadonlyMap<string, { ownerKind: ResourceUsageOwnerKind; ownerId: string }>;
  builtInTools: ReadonlySet<string>;
}

export interface ResourceUsageBackfillResult {
  totalSources: number;
  sources: number;
  completedSources: number;
  failedSources: number;
  bytes: number;
  lines: number;
  events: number;
  corruptLines: number;
  oversizedLines: number;
  cancelled: boolean;
}

export interface ResourceUsageBackfillOptions {
  now?: () => number;
  batchSize?: number;
  maxLineBytes?: number;
  yieldNow?: () => Promise<void>;
  signal?: AbortSignal;
  onProgress?: (progress: Readonly<ResourceUsageBackfillResult>) => void;
}

interface JsonlLine {
  text?: string;
  nextOffset: number;
  oversized: boolean;
  terminated: boolean;
}

interface ParseState {
  traceId?: string;
  provider?: string;
  model?: string;
  exactActionByMessageEntryId: Map<string, string>;
  pendingExactPromptEvents: Map<string, ResourceUsageEvent[]>;
}

interface TraceEntry {
  type?: unknown;
  id?: unknown;
  timestamp?: unknown;
  customType?: unknown;
  data?: unknown;
  message?: unknown;
  provider?: unknown;
  modelId?: unknown;
  model?: unknown;
}

/** Incremental, privacy-minimized JSONL history importer. Paths remain transient. */
export class ResourceUsageBackfill {
  private readonly now: () => number;
  private readonly batchSize: number;
  private readonly maxLineBytes: number;
  private readonly yieldNow: () => Promise<void>;
  private readonly signal?: AbortSignal;
  private readonly onProgress?: (progress: Readonly<ResourceUsageBackfillResult>) => void;

  constructor(
    private readonly store: ResourceUsageStore,
    options: ResourceUsageBackfillOptions = {},
  ) {
    this.now = options.now ?? Date.now;
    this.batchSize = options.batchSize ?? DEFAULT_BATCH_SIZE;
    this.maxLineBytes = options.maxLineBytes ?? DEFAULT_MAX_LINE_BYTES;
    this.yieldNow = options.yieldNow ?? (() => new Promise((done) => setImmediate(done)));
    this.signal = options.signal;
    this.onProgress = options.onProgress;
  }

  async run(
    sources: readonly ResourceUsageBackfillSource[],
    catalog: ResourceUsageBackfillCatalog,
  ): Promise<ResourceUsageBackfillResult> {
    const result: ResourceUsageBackfillResult = {
      totalSources: sources.length,
      sources: 0,
      completedSources: 0,
      failedSources: 0,
      bytes: 0,
      lines: 0,
      events: this.store.countHistoricalEvents(),
      corruptLines: 0,
      oversizedLines: 0,
      cancelled: false,
    };
    this.onProgress?.({ ...result });
    for (const source of sources) {
      if (this.signal?.aborted) {
        result.cancelled = true;
        break;
      }
      const outcome = await this.scanSource(source, catalog, result);
      if (outcome === "cancelled") {
        result.cancelled = true;
        break;
      }
      result.sources += 1;
      if (outcome === "complete") result.completedSources += 1;
      else result.failedSources += 1;
      this.onProgress?.({ ...result });
      await this.yieldNow();
    }
    return result;
  }

  private async scanSource(
    source: ResourceUsageBackfillSource,
    catalog: ResourceUsageBackfillCatalog,
    total: ResourceUsageBackfillResult,
  ): Promise<"complete" | "failed" | "cancelled"> {
    let canonicalPath: string;
    let fileSize: number;
    try {
      canonicalPath = await realpath(source.path);
      fileSize = (await stat(canonicalPath)).size;
    } catch {
      return "failed";
    }
    const fingerprint = fileFingerprint(canonicalPath);
    let checkpoint = this.store.getBackfillCheckpoint(source.sourceKey);
    if (checkpoint && (fileSize < checkpoint.offset || checkpoint.fingerprint !== fingerprint)) {
      this.store.resetBackfillSource(source.sourceKey);
      checkpoint = undefined;
    }
    const enrollment = this.store.enrollBackfillSource({
      sourceKey: source.sourceKey,
      sessionId: source.sessionId,
      ...(source.workspaceId ? { workspaceId: source.workspaceId } : {}),
      runtime: source.runtime,
    });
    if (!enrollment) return "failed";

    const state: ParseState = {
      exactActionByMessageEntryId: new Map(),
      pendingExactPromptEvents: new Map(),
    };
    // The header is before a resume offset. Read it separately without retaining
    // its path or cwd fields so action identity remains stable across increments.
    await readHeader(canonicalPath, this.maxLineBytes, state);
    const offset = checkpoint?.offset ?? 0;
    let lines = checkpoint?.lines ?? 0;
    let corruptLines = checkpoint?.corruptLines ?? 0;
    let oversizedLines = checkpoint?.oversizedLines ?? 0;
    let batch: ResourceUsageEvent[] = [];
    let batchOffset = offset;

    const flush = async (completed = false): Promise<boolean> => {
      const result = this.store.recordBackfillBatch({
        enrollment,
        events: batch,
        checkpoint: {
          sourceKey: source.sourceKey,
          offset: batchOffset,
          size: fileSize,
          fingerprint,
          ...(completed ? { completedAt: this.now() } : {}),
          corruptLines,
          oversizedLines,
          lines,
        },
        nowMs: this.now(),
      });
      batch = [];
      total.events = result.retainedHistoricalEvents;
      await this.yieldNow();
      return result.accepted;
    };

    for await (const line of boundedJsonlLines(
      canonicalPath,
      offset,
      this.maxLineBytes,
      this.signal,
    )) {
      if (this.signal?.aborted) return "cancelled";
      // A writer can be between chunks. Resume at the start of an unterminated
      // line instead of checkpointing into its middle.
      if (!line.terminated) break;
      batchOffset = line.nextOffset;
      lines += 1;
      total.lines += 1;
      if (line.oversized) {
        oversizedLines += 1;
        total.oversizedLines += 1;
      } else if (line.text?.trim()) {
        let entry: TraceEntry;
        try {
          entry = JSON.parse(line.text) as TraceEntry;
        } catch {
          corruptLines += 1;
          total.corruptLines += 1;
          if (batch.length >= this.batchSize && !(await flush())) return "failed";
          continue;
        }
        updateParseState(entry, state);
        for (const event of eventsFromEntry(entry, state, source, catalog, this.now())) {
          batch.push(event);
        }
      }
      if (batch.length >= this.batchSize && !(await flush())) return "failed";
    }
    if (this.signal?.aborted) return "cancelled";
    if (!(await flush(true))) return "failed";
    total.bytes += Math.max(0, fileSize - offset);
    return corruptLines > 0 || oversizedLines > 0 ? "failed" : "complete";
  }
}

export function opaqueResourceUsageSourceKey(path: string): string {
  return createHash("sha256").update(resolve(path)).digest("hex");
}

/**
 * Resolve every path against the complete authoritative set. Shared ancestor
 * traces remain with the oldest session; a fork owns only its new trace.
 */
export function resolveRegisteredResourceUsageSources(
  sessions: readonly Pick<
    Session,
    "id" | "createdAt" | "workspaceId" | "runtime" | "piSessionFile" | "piSessionFiles"
  >[],
): ResourceUsageBackfillSource[] {
  const candidates = new Map<string, typeof sessions>();
  for (const session of sessions) {
    if (!session.runtime) continue;
    for (const path of new Set(
      [...(session.piSessionFiles ?? []), session.piSessionFile].filter(isString),
    )) {
      const current = candidates.get(path) ?? [];
      candidates.set(path, [...current, session]);
    }
  }
  return [...candidates.entries()].map(([path, owners]) => {
    const owner = [...owners].sort(
      (left, right) => left.createdAt - right.createdAt || left.id.localeCompare(right.id),
    )[0];
    if (!owner?.runtime) throw new Error("Resource Usage source has no authoritative owner");
    return {
      sourceKey: opaqueResourceUsageSourceKey(path),
      path,
      sessionId: owner.id,
      ...(owner.workspaceId ? { workspaceId: owner.workspaceId } : {}),
      runtime: owner.runtime,
    };
  });
}

export function localResourceUsageSource(input: {
  path: string;
  piSessionId: string;
}): ResourceUsageBackfillSource {
  const traceHash = createHash("sha256").update(input.piSessionId).digest("hex");
  return {
    sourceKey: opaqueResourceUsageSourceKey(input.path),
    path: input.path,
    sessionId: `local_${traceHash}`,
    runtime: "pi-tui",
  };
}

async function* boundedJsonlLines(
  path: string,
  start: number,
  maxLineBytes: number,
  signal?: AbortSignal,
): AsyncGenerator<JsonlLine> {
  const stream = createReadStream(path, { start });
  let offset = start;
  let chunks: Buffer[] = [];
  let length = 0;
  let oversized = false;
  for await (const value of stream) {
    if (signal?.aborted) return;
    const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    let segmentStart = 0;
    for (let index = 0; index < chunk.length; index += 1) {
      if (chunk[index] !== 0x0a) continue;
      const segment = chunk.subarray(segmentStart, index);
      if (!oversized) {
        if (length + segment.length <= maxLineBytes) {
          chunks.push(segment);
          length += segment.length;
        } else {
          oversized = true;
          chunks = [];
          length = 0;
        }
      }
      offset += index - segmentStart + 1;
      yield {
        ...(oversized ? {} : { text: Buffer.concat(chunks, length).toString("utf8") }),
        nextOffset: offset,
        oversized,
        terminated: true,
      };
      chunks = [];
      length = 0;
      oversized = false;
      segmentStart = index + 1;
    }
    const tail = chunk.subarray(segmentStart);
    offset += tail.length;
    if (!oversized) {
      if (length + tail.length <= maxLineBytes) {
        chunks.push(tail);
        length += tail.length;
      } else {
        oversized = true;
        chunks = [];
        length = 0;
      }
    }
  }
  if (length > 0 || oversized) {
    yield {
      ...(oversized ? {} : { text: Buffer.concat(chunks, length).toString("utf8") }),
      nextOffset: offset,
      oversized,
      terminated: false,
    };
  }
}

async function readHeader(path: string, maxLineBytes: number, state: ParseState): Promise<void> {
  for await (const line of boundedJsonlLines(path, 0, maxLineBytes)) {
    if (!line.text) return;
    try {
      updateParseState(JSON.parse(line.text) as TraceEntry, state);
    } catch {
      // A missing header makes producer evidence unusable but does not stop scan.
    }
    return;
  }
}

function fileFingerprint(path: string): string {
  const fd = openSync(path, "r");
  try {
    const bytes = Buffer.allocUnsafe(4096);
    const count = readSync(fd, bytes, 0, bytes.length, 0);
    const newline = bytes.subarray(0, count).indexOf(0x0a);
    const stableCount = newline >= 0 ? newline + 1 : count;
    const identity = fstatSync(fd);
    return createHash("sha256")
      .update(bytes.subarray(0, stableCount))
      .update(`\0${identity.dev}\0${identity.ino}`)
      .digest("hex");
  } finally {
    closeSync(fd);
  }
}

function updateParseState(entry: TraceEntry, state: ParseState): void {
  if (entry.type === "session" && isString(entry.id)) state.traceId = entry.id;
  if (entry.type === "model_change") {
    if (isString(entry.provider)) state.provider = entry.provider;
    if (isString(entry.modelId)) state.model = entry.modelId;
    else if (isString(entry.model)) state.model = entry.model;
  }
}

function eventsFromEntry(
  entry: TraceEntry,
  state: ParseState,
  source: ResourceUsageBackfillSource,
  catalog: ResourceUsageBackfillCatalog,
  nowMs: number,
): ResourceUsageEvent[] {
  const occurredAt = timestampMs(entry.timestamp);
  if (occurredAt === undefined || occurredAt < nowMs - RETENTION_MS) return [];
  if (entry.type === "custom" && entry.customType === RESOURCE_MARKER_TYPE) {
    const data = asRecord(entry.data);
    if (!data || (data.version !== 1 && data.version !== 2) || !isSha256(data.actionId)) return [];
    if (!isSignal(data.signal) || !isOwnerKind(data.ownerKind) || !isString(data.ownerId))
      return [];
    const messageEntryId = isString(data.messageEntryId) ? data.messageEntryId : undefined;
    if (messageEntryId) state.exactActionByMessageEntryId.set(messageEntryId, data.actionId);
    const event = eventForSource(source, {
      actionId: data.actionId,
      occurredAt,
      signal: data.signal,
      ownerKind: data.ownerKind,
      ownerId: data.ownerId,
      ...(isString(data.itemName) ? { itemName: data.itemName } : {}),
      ...(isString(data.provider)
        ? { provider: data.provider }
        : state.provider
          ? { provider: state.provider }
          : {}),
      ...(isString(data.model) ? { model: data.model } : state.model ? { model: state.model } : {}),
      ...(isString(data.manifestRevision) ? { manifestRevision: data.manifestRevision } : {}),
      attribution: "exact",
      ...(!messageEntryId && data.signal === "explicit_activation" && data.ownerKind === "skill"
        ? { reconcilesFutureInference: true }
        : {}),
      ...(messageEntryId && state.traceId
        ? {
            reconcilesActionId: resourceUsageActionId(
              source.runtime,
              state.traceId,
              data.signal,
              messageEntryId,
            ),
          }
        : {}),
    });
    if (event.reconcilesFutureInference) {
      const key = promptReconciliationKey(
        event.signal,
        event.ownerKind,
        event.ownerId,
        event.itemName,
      );
      state.pendingExactPromptEvents.set(key, [
        ...(state.pendingExactPromptEvents.get(key) ?? []),
        event,
      ]);
    }
    return [event];
  }

  const lifecycle =
    entry.type === "custom" && entry.customType === "oppi-lifecycle"
      ? asRecord(entry.data)
      : undefined;
  if (
    lifecycle?.event === "tool_execution_start" &&
    isString(lifecycle.toolCallId) &&
    isString(lifecycle.toolName)
  ) {
    return toolEvent(lifecycle.toolName, lifecycle.toolCallId, occurredAt, state, source, catalog);
  }

  if (entry.type !== "message") return [];
  const message = asRecord(entry.message);
  if (!message || !isString(message.role)) return [];
  if (message.role === "assistant" && Array.isArray(message.content)) {
    return message.content.flatMap((part) => {
      const content = asRecord(part);
      if (
        !content ||
        content.type !== "toolCall" ||
        !isString(content.id) ||
        !isString(content.name)
      )
        return [];
      return toolEvent(content.name, content.id, occurredAt, state, source, catalog);
    });
  }
  if (message.role !== "user") return [];
  if (isString(entry.id) && state.exactActionByMessageEntryId.has(entry.id)) return [];
  const text = messageText(message.content);
  const command = text?.trimStart().match(/^\/([^\s]+)/)?.[1];
  if (!command || !isString(entry.id) || !state.traceId) return [];
  if (command.startsWith("skill:")) {
    const name = command.slice("skill:".length);
    const ownerId = catalog.skills.get(name);
    if (!ownerId) return [];
    const pending = state.pendingExactPromptEvents.get(
      promptReconciliationKey("explicit_activation", "skill", ownerId, name),
    );
    const exact = pending?.shift();
    if (exact) {
      exact.reconcilesFutureInference = false;
      exact.consumesFutureInferenceReconciliation = true;
      if (pending?.length === 0) {
        state.pendingExactPromptEvents.delete(
          promptReconciliationKey("explicit_activation", "skill", ownerId, name),
        );
      }
      return [exact];
    }
    return [
      eventForSource(source, {
        actionId: resourceUsageActionId(
          source.runtime,
          state.traceId,
          "explicit_activation",
          entry.id,
        ),
        occurredAt,
        signal: "explicit_activation",
        ownerKind: "skill",
        ownerId,
        itemName: name,
        ...(state.provider ? { provider: state.provider } : {}),
        ...(state.model ? { model: state.model } : {}),
        attribution: "inferred",
      }),
    ];
  }
  const owner = catalog.commands.get(command);
  if (!owner) return [];
  return [
    eventForSource(source, {
      actionId: resourceUsageActionId(
        source.runtime,
        state.traceId,
        "command_invocation",
        entry.id,
      ),
      occurredAt,
      signal: "command_invocation",
      ...owner,
      itemName: command,
      ...(state.provider ? { provider: state.provider } : {}),
      ...(state.model ? { model: state.model } : {}),
      attribution: "inferred",
    }),
  ];
}

function toolEvent(
  toolName: string,
  toolCallId: string,
  occurredAt: number,
  state: ParseState,
  source: ResourceUsageBackfillSource,
  catalog: ResourceUsageBackfillCatalog,
): ResourceUsageEvent[] {
  if (!state.traceId) return [];
  const owner =
    catalog.tools.get(toolName) ??
    (catalog.builtInTools.has(toolName)
      ? { ownerKind: "builtin" as const, ownerId: "builtin" }
      : undefined);
  if (!owner) return [];
  return [
    eventForSource(source, {
      actionId: resourceUsageActionId(source.runtime, state.traceId, "tool_invocation", toolCallId),
      occurredAt,
      signal: "tool_invocation",
      ...owner,
      itemName: toolName,
      ...(state.provider ? { provider: state.provider } : {}),
      ...(state.model ? { model: state.model } : {}),
      attribution: "exact",
    }),
  ];
}

function eventForSource(
  source: ResourceUsageBackfillSource,
  event: Omit<ResourceUsageEvent, "sessionId" | "workspaceId" | "runtime" | "origin" | "sourceKey">,
): ResourceUsageEvent {
  return {
    ...event,
    sessionId: source.sessionId,
    ...(source.workspaceId ? { workspaceId: source.workspaceId } : {}),
    runtime: source.runtime,
    origin: "history",
    sourceKey: source.sourceKey,
  };
}

function promptReconciliationKey(
  signal: ResourceUsageSignal,
  ownerKind: ResourceUsageOwnerKind,
  ownerId: string,
  itemName?: string,
): string {
  return `${signal}\0${ownerKind}\0${ownerId}\0${itemName ?? ""}`;
}

function timestampMs(value: unknown): number | undefined {
  const timestamp = typeof value === "number" ? value : isString(value) ? Date.parse(value) : NaN;
  return Number.isFinite(timestamp) ? timestamp : undefined;
}

function messageText(value: unknown): string | undefined {
  if (isString(value)) return value;
  if (!Array.isArray(value)) return undefined;
  return value
    .flatMap((part) => {
      const content = asRecord(part);
      return content?.type === "text" && isString(content.text) ? [content.text] : [];
    })
    .join("\n");
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function isSignal(value: unknown): value is ResourceUsageSignal {
  return (
    value === "agent_load" ||
    value === "explicit_activation" ||
    value === "tool_invocation" ||
    value === "command_invocation"
  );
}

function isOwnerKind(value: unknown): value is ResourceUsageOwnerKind {
  return value === "skill" || value === "extension" || value === "builtin";
}

function isSha256(value: unknown): value is string {
  return isString(value) && /^[a-f0-9]{64}$/.test(value);
}

function isString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
