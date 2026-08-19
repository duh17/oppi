import { throwIfAborted, type LocalApiRequestOptions } from "../local-api-client.js";
import { apiStatus } from "../resources.js";
import { sleepWithSignal } from "./wait.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

// ─── Session wait poller ───
//
// `session wait` uses this state machine for one session and prints the terminal record.
// Status comes from the live events/catch-up stream so busy→ready is observed without a tight
// status poll; pending dialogs come from the per-session dialogs route only when the condition
// needs them. Tool counts and the last assistant snippet are derived from the events already
// fetched, never from tool/extension names.

type SessionWatchCondition = "idle" | "attention" | "either" | "any-change";
type SessionWatchReason = "idle" | "attention" | "change";
type WatchOutputDeltaKind = "delta" | "latest";

const MAX_WATCH_OUTPUT_DELTA_CHARS = 50_000;
const WATCH_OUTPUT_OMISSION_MARKER = "[… earlier output omitted …]\n\n";

interface WatchSessionState {
  sinceSeq: number;
  status?: string;
  messageCount?: number;
  pendingDialogs?: number;
  toolsThisTurn: number;
  last?: string;
  lastOutputKey?: string;
  assistantEventObserved: boolean;
  outputDelta: string;
  seenBaseline: boolean;
  met: boolean;
}

interface WatchTransition {
  ts: number;
  sessionId: string;
  kind: "transition" | "resolved";
  reason?: SessionWatchReason;
  prevStatus?: string;
  status?: string;
  messageCount?: number;
  toolsThisTurn: number;
  last?: string;
  pendingDialogs?: number;
}

export type WatchOutcome =
  | {
      kind: "session";
      sessionId: string;
      reason: SessionWatchReason;
      status?: string;
      pendingDialogs?: number;
      outputDelta?: string;
      outputDeltaKind?: WatchOutputDeltaKind;
    }
  | {
      kind: "all";
      condition: SessionWatchCondition;
      sessions: Array<{ sessionId: string; status?: string; pendingDialogs?: number }>;
    };

export type WaitProgressSession = {
  sessionId: string;
  status?: string;
  pendingDialogs?: number;
  toolsThisTurn: number;
};

export type WaitProgressSnapshot = {
  ts: number;
  elapsedMs: number;
  sessions: WaitProgressSession[];
};

interface WatchOptions {
  condition: SessionWatchCondition;
  requireAll: boolean;
  intervalMs: number;
  timeoutMs: number;
  /** 0 disables heartbeats. Used by wait, not by streaming watch. */
  summaryEveryMs?: number;
  onSummary?: (snapshot: WaitProgressSnapshot) => void;
  signal?: AbortSignal;
}

/**
 * Wait defaults from 14-day server telemetry (2026-08-19):
 * - server.turn_ttft_ms p50 = 4.3s → poll at half TTFT, clamped to 2s
 * - server.turn_duration_ms p50 = 236s → heartbeat at ~1/4 turn = 60s
 * See .internal/reports/session-wait-poll-defaults-2026-08-19.md
 */
export const WAIT_DEFAULT_POLL = "2s";
export const WAIT_DEFAULT_SUMMARY_EVERY = "60s";

class SessionWatchTimeout extends Error {
  constructor(
    readonly condition: SessionWatchCondition,
    readonly pending: string[],
  ) {
    const target = pending.length === 1 ? `session ${pending[0]}` : `${pending.length} sessions`;
    super(`Timed out waiting for ${target} to reach ${condition}`);
    this.name = "SessionWatchTimeout";
  }
}

export function parseWatchCondition(
  raw: string | undefined,
  fallback: SessionWatchCondition,
): SessionWatchCondition {
  const value = raw?.trim().toLowerCase();
  if (!value) return fallback;
  if (value === "idle" || value === "attention" || value === "either") return value;
  if (value === "any-change") return "any-change";
  throw new Error("condition must be idle, attention, either, or any-change");
}

function isIdleSessionStatus(status: string | undefined): boolean {
  // A turn has settled once the runtime leaves the working states. Terminal stopped/error
  // sessions also count as idle so a supervisor wait resolves instead of timing out.
  return status === "ready" || status === "stopped" || status === "error";
}

async function observeSession(
  id: string,
  state: WatchSessionState,
  needDialogs: boolean,
  call: SessionListApiCall,
  signal?: AbortSignal,
): Promise<{ activityChanged: boolean; stateChanged: boolean }> {
  const prevStatus = state.status;
  const prevPending = state.pendingDialogs;
  const prevSeq = state.sinceSeq;
  const prevMessageCount = state.messageCount;
  const prevTools = state.toolsThisTurn;
  const prevLast = state.last;
  let status: string | undefined;

  try {
    const events = await call<{
      session?: { status?: string; messageCount?: number; lastMessage?: string };
      events?: Array<Record<string, unknown>>;
      currentSeq?: number;
    }>(
      `/sessions/${encodeURIComponent(id)}/events?since=${state.sinceSeq}`,
      signal ? { signal } : undefined,
    );
    status = events.session?.status;
    if (typeof events.session?.messageCount === "number") {
      state.messageCount = events.session.messageCount;
    }
    if (typeof events.currentSeq === "number") state.sinceSeq = events.currentSeq;
    for (const event of events.events ?? []) {
      const type = event.type;
      if (type === "agent_start") state.toolsThisTurn = 0;
      else if (type === "tool_start") state.toolsThisTurn += 1;
      else if (type === "message_end" && event.role === "assistant") {
        const content = event.content;
        if (typeof content === "string") {
          state.assistantEventObserved = true;
          recordAssistantOutput(state, content, false);
        }
      }
    }
    if (!state.assistantEventObserved && typeof events.session?.lastMessage === "string") {
      recordAssistantOutput(state, events.session.lastMessage);
    }
  } catch (err) {
    throwIfAborted(signal);
    if (apiStatus(err) === 404) {
      const snapshot = await call<{
        session?: { status?: string; messageCount?: number; lastMessage?: string };
      }>(`/sessions/${encodeURIComponent(id)}`, signal ? { signal } : undefined);
      status = snapshot.session?.status;
      if (typeof snapshot.session?.messageCount === "number") {
        state.messageCount = snapshot.session.messageCount;
      }
      if (typeof snapshot.session?.lastMessage === "string") {
        recordAssistantOutput(state, snapshot.session.lastMessage);
      }
    } else {
      throw err;
    }
  }

  throwIfAborted(signal);
  state.status = status;
  if (needDialogs) {
    const list = await call<{ dialogs?: unknown[] }>(
      `/sessions/${encodeURIComponent(id)}/dialogs`,
      signal ? { signal } : undefined,
    );
    state.pendingDialogs = Array.isArray(list.dialogs) ? list.dialogs.length : 0;
  }

  const stateChanged = state.status !== prevStatus || state.pendingDialogs !== prevPending;
  return {
    stateChanged,
    activityChanged:
      stateChanged ||
      state.sinceSeq !== prevSeq ||
      state.messageCount !== prevMessageCount ||
      state.toolsThisTurn !== prevTools ||
      state.last !== prevLast,
  };
}

function recordAssistantOutput(state: WatchSessionState, content: string, dedupe = true): void {
  const normalized = content.trim();
  if (!normalized) return;
  const outputKey = watchOutputKey(normalized);
  if (dedupe && outputKey === state.lastOutputKey) return;

  state.lastOutputKey = outputKey;
  state.last = boundWatchOutput(normalized);
  const next = state.outputDelta ? `${state.outputDelta}\n\n${normalized}` : normalized;
  state.outputDelta = boundWatchOutput(next);
}

function boundWatchOutput(text: string): string {
  if (text.length <= MAX_WATCH_OUTPUT_DELTA_CHARS) return text;
  return `${WATCH_OUTPUT_OMISSION_MARKER}${text.slice(
    -(MAX_WATCH_OUTPUT_DELTA_CHARS - WATCH_OUTPUT_OMISSION_MARKER.length),
  )}`;
}

function watchOutputKey(text: string): string {
  // Keep snapshot de-duplication bounded even when an assistant message is very large.
  let hash = 2_166_136_261;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 16_777_619);
  }
  return `${text.length}:${hash >>> 0}`;
}

function resolvedOutputDelta(
  state: WatchSessionState,
): { text: string; kind: WatchOutputDeltaKind } | undefined {
  if (state.outputDelta) return { text: state.outputDelta, kind: "delta" };
  if (state.last) return { text: state.last, kind: "latest" };
  return undefined;
}

function evaluateWatchCondition(
  condition: SessionWatchCondition,
  state: WatchSessionState,
  isBaseline: boolean,
  activityChanged: boolean,
): SessionWatchReason | undefined {
  if (condition === "any-change") {
    return !isBaseline && activityChanged ? "change" : undefined;
  }
  const idle = isIdleSessionStatus(state.status);
  const attention = (state.pendingDialogs ?? 0) > 0;
  if (condition === "idle") return idle ? "idle" : undefined;
  if (condition === "attention") return attention ? "attention" : undefined;
  if (attention) return "attention";
  return idle ? "idle" : undefined;
}

function buildWatchTransition(
  id: string,
  state: WatchSessionState,
  kind: "transition" | "resolved",
  prevStatus: string | undefined,
  reason?: SessionWatchReason,
): WatchTransition {
  return {
    ts: Date.now(),
    sessionId: id,
    kind,
    ...(reason !== undefined ? { reason } : {}),
    ...(prevStatus !== undefined ? { prevStatus } : {}),
    ...(state.status !== undefined ? { status: state.status } : {}),
    ...(state.messageCount !== undefined ? { messageCount: state.messageCount } : {}),
    toolsThisTurn: state.toolsThisTurn,
    ...(state.last !== undefined ? { last: state.last } : {}),
    ...(state.pendingDialogs !== undefined ? { pendingDialogs: state.pendingDialogs } : {}),
  };
}

export async function runSessionWatch(
  ids: string[],
  options: WatchOptions,
  call: SessionListApiCall,
  emit: (transition: WatchTransition) => void,
): Promise<WatchOutcome> {
  if (options.intervalMs < 1) throw new Error("--interval must be a positive duration");
  if (options.timeoutMs < 1) throw new Error("--timeout must be a positive duration");
  throwIfAborted(options.signal);
  const needDialogs = options.condition !== "idle";
  const states = new Map<string, WatchSessionState>();
  for (const id of ids) {
    states.set(id, {
      sinceSeq: 0,
      toolsThisTurn: 0,
      assistantEventObserved: false,
      outputDelta: "",
      seenBaseline: false,
      met: false,
    });
  }
  const deadline = Date.now() + options.timeoutMs;
  const startedAt = Date.now();
  const summaryEveryMs = options.summaryEveryMs ?? 0;
  let lastSummaryAt = startedAt;

  for (;;) {
    for (const id of ids) {
      throwIfAborted(options.signal);
      const state = states.get(id);
      if (!state) continue;
      const prevStatus = state.status;
      const { activityChanged, stateChanged } = await observeSession(
        id,
        state,
        needDialogs,
        call,
        options.signal,
      );
      const isBaseline = !state.seenBaseline;
      if (isBaseline) state.outputDelta = "";
      state.seenBaseline = true;
      const reason = evaluateWatchCondition(options.condition, state, isBaseline, activityChanged);
      state.met =
        options.condition === "any-change"
          ? state.met || reason !== undefined
          : reason !== undefined;
      if (reason && !options.requireAll) {
        throwIfAborted(options.signal);
        emit(buildWatchTransition(id, state, "resolved", prevStatus, reason));
        const outputDelta = resolvedOutputDelta(state);
        return {
          kind: "session",
          sessionId: id,
          reason,
          ...(state.status !== undefined ? { status: state.status } : {}),
          ...(state.pendingDialogs !== undefined ? { pendingDialogs: state.pendingDialogs } : {}),
          ...(outputDelta
            ? { outputDelta: outputDelta.text, outputDeltaKind: outputDelta.kind }
            : {}),
        };
      }
      if (
        !isBaseline &&
        (stateChanged || (options.condition === "any-change" && activityChanged))
      ) {
        emit(buildWatchTransition(id, state, "transition", prevStatus));
      }
    }

    if (options.requireAll && ids.every((id) => states.get(id)?.met)) {
      throwIfAborted(options.signal);
      return {
        kind: "all",
        condition: options.condition,
        sessions: ids.map((id) => {
          const state = states.get(id);
          return {
            sessionId: id,
            ...(state?.status !== undefined ? { status: state.status } : {}),
            ...(state?.pendingDialogs !== undefined
              ? { pendingDialogs: state.pendingDialogs }
              : {}),
          };
        }),
      };
    }

    if (Date.now() >= deadline) {
      throwIfAborted(options.signal);
      throw new SessionWatchTimeout(
        options.condition,
        ids.filter((id) => !states.get(id)?.met),
      );
    }
    if (summaryEveryMs > 0 && Date.now() - lastSummaryAt >= summaryEveryMs) {
      lastSummaryAt = Date.now();
      options.onSummary?.({
        ts: lastSummaryAt,
        elapsedMs: lastSummaryAt - startedAt,
        sessions: ids.map((id) => {
          const state = states.get(id);
          return {
            sessionId: id,
            toolsThisTurn: state?.toolsThisTurn ?? 0,
            ...(state?.status !== undefined ? { status: state.status } : {}),
            ...(state?.pendingDialogs !== undefined
              ? { pendingDialogs: state.pendingDialogs }
              : {}),
          };
        }),
      });
    }
    await sleepWithSignal(
      Math.min(options.intervalMs, Math.max(0, deadline - Date.now())),
      options.signal,
    );
  }
}
