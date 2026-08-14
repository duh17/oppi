import { createHash } from "node:crypto";
import { closeSync, createReadStream, fstatSync, openSync, readSync } from "node:fs";
import { realpath, stat } from "node:fs/promises";
import { resolve } from "node:path";

import { matchPiReadPath, resolvePiReadPath } from "./pi-read-path.js";
import { canonicalServerResourcePath } from "./server-resource-id.js";
import { isSandboxSkillBindingToken } from "./sandbox-resource-paths.js";

import {
  isResourceUsageTraceEventId,
  resourceUsageActionId,
  resourceUsageRuntimeActionAliases,
  resourceUsageToolOccurrenceId,
} from "./resource-usage-service.js";
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
const LIFECYCLE_MARKER_TYPE = "oppi-lifecycle";

export interface ResourceUsageBackfillSource {
  sourceKey: string;
  path: string;
  sessionId: string;
  workspaceId?: string;
  runtime: ResourceUsageRuntime;
  /** Random runtime binding tokens. Empty means sandbox attribution is disabled. */
  sandboxSkillBindings?: ReadonlyMap<string, { id: string; name: string }>;
}

export interface ResourceUsageBackfillCatalog {
  skills: ReadonlyMap<string, string>;
  /** Transient canonical primary Markdown path to privacy-safe Skill identity. */
  skillPrimaryFiles: ReadonlyMap<string, { id: string; name: string }>;
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

interface CheckpointPosition {
  offset: number;
  lines: number;
  corruptLines: number;
  oversizedLines: number;
}

interface PendingToolCall {
  producerId: string;
  toolName: string;
  skill?: { id: string; name: string };
  awaitingLifecycle: boolean;
  successfulResult?: boolean;
  resultObserved?: boolean;
  resume: CheckpointPosition;
}

interface PendingLifecycleMarker {
  eventId: string;
  resume: CheckpointPosition;
}

interface ParseState {
  traceId?: string;
  cwd?: string;
  provider?: string;
  model?: string;
  /**
   * Occurrence counters are scoped to one source scan and reconstructed from a
   * checkpoint prefix; no provider IDs or arguments cross the source boundary.
   */
  toolCallOccurrences: Map<string, number>;
  pendingToolCalls: Map<string, PendingToolCall[]>;
  pendingLifecycleMarkers: Map<string, PendingLifecycleMarker[]>;
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
      toolCallOccurrences: new Map(),
      pendingToolCalls: new Map(),
      pendingLifecycleMarkers: new Map(),
      exactActionByMessageEntryId: new Map(),
      pendingExactPromptEvents: new Map(),
    };
    // The header is before a resume offset. Read it separately without retaining
    // its path or cwd fields so action identity remains stable across increments.
    await readHeader(canonicalPath, this.maxLineBytes, state);
    const scanNowMs = this.now();
    const offset = checkpoint?.offset ?? 0;
    if (offset > 0) {
      await restoreToolCallOccurrences(canonicalPath, offset, this.maxLineBytes, state, scanNowMs);
    }
    let lines = checkpoint?.lines ?? 0;
    let corruptLines = checkpoint?.corruptLines ?? 0;
    let oversizedLines = checkpoint?.oversizedLines ?? 0;
    let batch: ResourceUsageEvent[] = [];
    let batchOffset = offset;

    const flush = async (completed = false): Promise<boolean> => {
      // Correlation is transient and path-free. Do not checkpoint past either
      // side of an unmatched call/lifecycle pair: replay must be able to recover
      // the deterministic fallback identity and atomically replace it with the
      // later exact lifecycle identity after a crash or cancellation.
      const resume = earliestPendingCorrelationResume(
        state.pendingToolCalls,
        state.pendingLifecycleMarkers,
      );
      const checkpointPosition = resume ?? {
        offset: batchOffset,
        lines,
        corruptLines,
        oversizedLines,
      };
      const result = this.store.recordBackfillBatch({
        enrollment,
        events: batch,
        checkpoint: {
          sourceKey: source.sourceKey,
          offset: checkpointPosition.offset,
          size: fileSize,
          fingerprint,
          ...(completed && !resume ? { completedAt: this.now() } : {}),
          corruptLines: checkpointPosition.corruptLines,
          oversizedLines: checkpointPosition.oversizedLines,
          lines: checkpointPosition.lines,
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
      const beforeLine: CheckpointPosition = {
        offset: batchOffset,
        lines,
        corruptLines,
        oversizedLines,
      };
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
        for (const event of eventsFromEntry(entry, state, source, catalog, scanNowMs, beforeLine)) {
          batch.push(event);
        }
      }
      if (batch.length >= this.batchSize && !(await flush())) return "failed";
    }
    if (this.signal?.aborted) return "cancelled";
    const unresolvedCorrelation =
      hasPendingCorrelation(state.pendingToolCalls) ||
      hasPendingCorrelation(state.pendingLifecycleMarkers);
    if (!(await flush(!unresolvedCorrelation))) return "failed";
    total.bytes += Math.max(0, fileSize - offset);
    return unresolvedCorrelation || corruptLines > 0 || oversizedLines > 0 ? "failed" : "complete";
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

async function restoreToolCallOccurrences(
  path: string,
  checkpointOffset: number,
  maxLineBytes: number,
  state: ParseState,
  nowMs: number,
): Promise<void> {
  for await (const line of boundedJsonlLines(path, 0, maxLineBytes)) {
    if (line.nextOffset > checkpointOffset) return;
    if (!line.text || line.oversized) continue;
    try {
      const entry = JSON.parse(line.text) as TraceEntry;
      if (retainedTimestamp(entry, nowMs) === undefined || entry.type !== "message") continue;
      const message = asRecord(entry.message);
      if (message?.role !== "assistant" || !Array.isArray(message.content)) continue;
      for (const part of message.content) {
        const content = asRecord(part);
        if (content?.type === "toolCall" && isString(content.id) && isString(content.name)) {
          nextToolCallProducerId(state, content.id);
        }
      }
    } catch {
      // Corrupt prefix lines were already counted in the durable checkpoint.
    }
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
  if (entry.type === "session") {
    if (isString(entry.id)) state.traceId = entry.id;
    const session = entry as TraceEntry & { cwd?: unknown };
    if (isString(session.cwd)) state.cwd = session.cwd;
  }
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
  beforeEntry: CheckpointPosition,
): ResourceUsageEvent[] {
  const occurredAt = retainedTimestamp(entry, nowMs);
  if (occurredAt === undefined) return [];
  if (entry.type === "custom" && entry.customType === LIFECYCLE_MARKER_TYPE) {
    return eventsFromLifecycleMarker(entry, state, source, catalog, occurredAt, beforeEntry);
  }
  if (entry.type === "custom" && entry.customType === RESOURCE_MARKER_TYPE) {
    const data = asRecord(entry.data);
    if (!data) return [];
    if (data.version === 3) {
      if (
        data.signal !== "skill_instruction_read" ||
        !isSandboxSkillBindingToken(data.bindingToken) ||
        !isResourceUsageProducerId(data.producerId) ||
        !state.traceId
      ) {
        return [];
      }
      const skill = source.sandboxSkillBindings?.get(data.bindingToken);
      if (!skill) return [];
      return [
        eventForSource(source, {
          ...resourceUsageEventIdentity(
            source.runtime,
            state.traceId,
            "skill_instruction_read",
            data.producerId,
          ),
          occurredAt,
          signal: "skill_instruction_read",
          ownerKind: "skill",
          ownerId: skill.id,
          itemName: skill.name,
          ...(state.provider ? { provider: state.provider } : {}),
          ...(state.model ? { model: state.model } : {}),
          attribution: "exact",
        }),
      ];
    }
    if ((data.version !== 1 && data.version !== 2) || !isSha256(data.actionId)) return [];
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

  if (entry.type !== "message") return [];
  const message = asRecord(entry.message);
  if (!message || !isString(message.role)) return [];
  if (message.role === "assistant" && Array.isArray(message.content)) {
    const events: ResourceUsageEvent[] = [];
    for (const part of message.content) {
      const content = asRecord(part);
      if (
        !content ||
        content.type !== "toolCall" ||
        !isString(content.id) ||
        !isString(content.name)
      ) {
        continue;
      }
      const fallbackProducerId = nextToolCallProducerId(state, content.id);
      const pendingKey = resourceUsagePendingToolKey(content.id, content.name);
      const markerQueue = state.pendingLifecycleMarkers.get(pendingKey);
      const precedingMarker = markerQueue?.shift();
      if (markerQueue?.length === 0) state.pendingLifecycleMarkers.delete(pendingKey);
      const args = content.name === "read" ? asRecord(content.arguments) : undefined;
      const skill =
        args && isString(args.path)
          ? skillForReadPath(args.path, state.cwd ?? ".", source, catalog)
          : undefined;
      const fallbackEvents = toolEvent(
        content.name,
        fallbackProducerId,
        occurredAt,
        state,
        source,
        catalog,
      );

      if (precedingMarker) {
        // The exact Tool event was emitted by the earlier marker. A primary read
        // still needs its result, but generic tools and non-primary reads are
        // fully correlated without retaining their call or arguments.
        if (skill) {
          const queue = state.pendingToolCalls.get(pendingKey) ?? [];
          queue.push({
            producerId: precedingMarker.eventId,
            toolName: content.name,
            skill,
            awaitingLifecycle: false,
            // Replaying a pending primary read must also replay the preceding
            // marker that supplied its exact producer identity.
            resume: precedingMarker.resume,
          });
          state.pendingToolCalls.set(pendingKey, queue);
        }
        continue;
      }
      if (fallbackEvents.length === 0 && !skill) continue;

      const queue = state.pendingToolCalls.get(pendingKey) ?? [];
      queue.push({
        producerId: fallbackProducerId,
        toolName: content.name,
        ...(skill ? { skill } : {}),
        awaitingLifecycle: true,
        resume: beforeEntry,
      });
      state.pendingToolCalls.set(pendingKey, queue);
      events.push(...fallbackEvents);
    }
    return events;
  }
  if (message.role === "toolResult") {
    if (message.toolName !== "read" || !isString(message.toolCallId)) return [];
    const pendingKey = resourceUsagePendingToolKey(message.toolCallId, message.toolName);
    const queue = state.pendingToolCalls.get(pendingKey);
    const pendingIndex = queue?.findIndex((call) => !call.resultObserved) ?? -1;
    const pending = pendingIndex >= 0 ? queue?.[pendingIndex] : undefined;
    if (!pending) return [];
    pending.resultObserved = true;
    pending.successfulResult = message.isError === false;
    if (!pending.awaitingLifecycle) removePendingToolCall(state, pendingKey, pendingIndex);
    if (!pending.skill || !pending.successfulResult || !state.traceId) return [];
    return [skillReadEvent(pending, occurredAt, state, source)];
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

function eventsFromLifecycleMarker(
  entry: TraceEntry,
  state: ParseState,
  source: ResourceUsageBackfillSource,
  catalog: ResourceUsageBackfillCatalog,
  occurredAt: number,
  beforeEntry: CheckpointPosition,
): ResourceUsageEvent[] {
  const data = asRecord(entry.data);
  if (
    data?.version !== 2 ||
    data.event !== "tool_execution_start" ||
    !isString(data.toolCallId) ||
    !isString(data.toolName) ||
    !isResourceUsageTraceEventId(data.eventId) ||
    !state.traceId
  ) {
    return [];
  }

  const pendingKey = resourceUsagePendingToolKey(data.toolCallId, data.toolName);
  const queue = state.pendingToolCalls.get(pendingKey);
  const pendingIndex = queue?.findIndex((call) => call.awaitingLifecycle) ?? -1;
  const pending = pendingIndex >= 0 ? queue?.[pendingIndex] : undefined;
  if (!pending) {
    const events = toolEvent(data.toolName, data.eventId, occurredAt, state, source, catalog);
    if (events.length === 0) return [];
    const markerQueue = state.pendingLifecycleMarkers.get(pendingKey) ?? [];
    markerQueue.push({ eventId: data.eventId, resume: beforeEntry });
    state.pendingLifecycleMarkers.set(pendingKey, markerQueue);
    return events;
  }

  const fallbackProducerId = pending.producerId;
  pending.producerId = data.eventId;
  pending.awaitingLifecycle = false;
  const events = toolEvent(data.toolName, data.eventId, occurredAt, state, source, catalog, [
    resourceUsageActionId(source.runtime, state.traceId, "tool_invocation", fallbackProducerId),
  ]);
  if (pending.skill && pending.successfulResult) {
    events.push(
      skillReadEvent(pending, occurredAt, state, source, [
        resourceUsageActionId(
          source.runtime,
          state.traceId,
          "skill_instruction_read",
          fallbackProducerId,
        ),
      ]),
    );
  }
  if (data.toolName !== "read" || !pending.skill || pending.resultObserved) {
    removePendingToolCall(state, pendingKey, pendingIndex);
  }
  return events;
}

function resourceUsagePendingToolKey(toolCallId: string, toolName: string): string {
  return JSON.stringify([toolCallId, toolName]);
}

function removePendingToolCall(state: ParseState, pendingKey: string, index: number): void {
  const queue = state.pendingToolCalls.get(pendingKey);
  if (!queue) return;
  queue.splice(index, 1);
  if (queue.length === 0) state.pendingToolCalls.delete(pendingKey);
}

function skillReadEvent(
  pending: PendingToolCall,
  occurredAt: number,
  state: ParseState,
  source: ResourceUsageBackfillSource,
  supersedesActionIds: readonly string[] = [],
): ResourceUsageEvent {
  if (!pending.skill || !state.traceId) {
    throw new Error("Skill read event requires correlated Skill and trace identities");
  }
  return eventForSource(source, {
    ...resourceUsageEventIdentity(
      source.runtime,
      state.traceId,
      "skill_instruction_read",
      pending.producerId,
      supersedesActionIds,
    ),
    occurredAt,
    signal: "skill_instruction_read",
    ownerKind: "skill",
    ownerId: pending.skill.id,
    itemName: pending.skill.name,
    ...(state.provider ? { provider: state.provider } : {}),
    ...(state.model ? { model: state.model } : {}),
    attribution: "exact",
  });
}

function resourceUsageEventIdentity(
  runtime: ResourceUsageRuntime,
  traceId: string,
  signal: ResourceUsageSignal,
  producerId: string,
  supersedesActionIds: readonly string[] = [],
): Pick<ResourceUsageEvent, "actionId" | "supersedesActionIds"> {
  return {
    actionId: resourceUsageActionId(runtime, traceId, signal, producerId),
    supersedesActionIds: [
      ...supersedesActionIds,
      ...resourceUsageRuntimeActionAliases(traceId, signal, producerId),
    ],
  };
}

function earliestPendingCorrelationResume(
  pendingCalls: ReadonlyMap<string, readonly PendingToolCall[]>,
  pendingMarkers: ReadonlyMap<string, readonly PendingLifecycleMarker[]>,
): CheckpointPosition | undefined {
  let earliest: CheckpointPosition | undefined;
  for (const pending of [pendingCalls, pendingMarkers]) {
    for (const queue of pending.values()) {
      for (const value of queue) {
        if (!earliest || value.resume.offset < earliest.offset) earliest = value.resume;
      }
    }
  }
  return earliest;
}

function hasPendingCorrelation<T>(pending: ReadonlyMap<string, readonly T[]>): boolean {
  return [...pending.values()].some((queue) => queue.length > 0);
}

function nextToolCallProducerId(state: ParseState, toolCallId: string): string {
  const occurrence = (state.toolCallOccurrences.get(toolCallId) ?? 0) + 1;
  state.toolCallOccurrences.set(toolCallId, occurrence);
  return resourceUsageToolOccurrenceId(toolCallId, occurrence);
}

function skillForReadPath(
  rawPath: string,
  cwd: string,
  source: ResourceUsageBackfillSource,
  catalog: ResourceUsageBackfillCatalog,
): { id: string; name: string } | undefined {
  let candidate: string;
  try {
    candidate = resolvePiReadPath(rawPath, cwd);
  } catch {
    return undefined;
  }
  // Sandbox traces require a runtime-journaled random token. Existing traces
  // without one omit attribution rather than reconstructing it from a path.
  if (source.sandboxSkillBindings !== undefined) return undefined;
  return matchPiReadPath(catalog.skillPrimaryFiles, canonicalServerResourcePath(candidate));
}

function toolEvent(
  toolName: string,
  producerId: string,
  occurredAt: number,
  state: ParseState,
  source: ResourceUsageBackfillSource,
  catalog: ResourceUsageBackfillCatalog,
  supersedesActionIds: readonly string[] = [],
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
      ...resourceUsageEventIdentity(
        source.runtime,
        state.traceId,
        "tool_invocation",
        producerId,
        supersedesActionIds,
      ),
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

function retainedTimestamp(entry: TraceEntry, nowMs: number): number | undefined {
  const occurredAt = timestampMs(entry.timestamp);
  return occurredAt !== undefined && occurredAt >= nowMs - RETENTION_MS ? occurredAt : undefined;
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
    value === "skill_instruction_read" ||
    value === "explicit_activation" ||
    value === "tool_invocation" ||
    value === "command_invocation"
  );
}

function isOwnerKind(value: unknown): value is ResourceUsageOwnerKind {
  return value === "skill" || value === "extension" || value === "builtin";
}

function isResourceUsageProducerId(value: unknown): value is string {
  return (
    isResourceUsageTraceEventId(value) ||
    (typeof value === "string" && /^tool-occurrence-v1_[a-f0-9]{64}$/.test(value))
  );
}

function isSha256(value: unknown): value is string {
  return isString(value) && /^[a-f0-9]{64}$/.test(value);
}

function isString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}
