/* eslint-disable no-console */
import * as c from "../../ansi.js";
import type { LocalApiRequestOptions } from "../local-api-client.js";
import { apiStatus } from "../resources.js";
import { parseDurationMs } from "./wait.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

// ─── Watch / wait (shared polling core) ───
//
// A single state machine drives both `wait` (one session, resolves on a condition, prints the
// terminal record) and `watch` (many sessions, streams one compact line per state transition).
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

interface WatchOptions {
  condition: SessionWatchCondition;
  requireAll: boolean;
  intervalMs: number;
  timeoutMs: number;
}

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
    }>(`/sessions/${encodeURIComponent(id)}/events?since=${state.sinceSeq}`);
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
    if (apiStatus(err) === 404) {
      const snapshot = await call<{
        session?: { status?: string; messageCount?: number; lastMessage?: string };
      }>(`/sessions/${encodeURIComponent(id)}`);
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

  state.status = status;
  if (needDialogs) {
    const list = await call<{ dialogs?: unknown[] }>(`/sessions/${encodeURIComponent(id)}/dialogs`);
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

  for (;;) {
    for (const id of ids) {
      const state = states.get(id);
      if (!state) continue;
      const prevStatus = state.status;
      const { activityChanged, stateChanged } = await observeSession(id, state, needDialogs, call);
      const isBaseline = !state.seenBaseline;
      if (isBaseline) state.outputDelta = "";
      state.seenBaseline = true;
      const reason = evaluateWatchCondition(options.condition, state, isBaseline, activityChanged);
      state.met =
        options.condition === "any-change"
          ? state.met || reason !== undefined
          : reason !== undefined;
      if (reason && !options.requireAll) {
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
      throw new SessionWatchTimeout(
        options.condition,
        ids.filter((id) => !states.get(id)?.met),
      );
    }
    await sleep(Math.min(options.intervalMs, Math.max(0, deadline - Date.now())));
  }
}

function clipWatchSnippet(text: string, budget: number): string {
  const oneLine = text.replace(/\s+/g, " ").trim();
  if (oneLine.length <= budget) return oneLine;
  return `${oneLine.slice(0, Math.max(0, budget - 1))}…`;
}

function formatWatchTransitionLine(transition: WatchTransition): string {
  const time = new Date(transition.ts).toTimeString().slice(0, 8);
  const state =
    transition.prevStatus === undefined
      ? `status=${transition.status ?? "?"}`
      : `${transition.prevStatus}→${transition.status ?? "?"}`;
  const reason = transition.reason ? ` reason=${transition.reason}` : "";
  const dialogs =
    transition.pendingDialogs !== undefined ? ` dialogs=${transition.pendingDialogs}` : "";
  const prefix = `${time} ${transition.sessionId} ${state}${reason} tools=${transition.toolsThisTurn}${dialogs}`;
  if (!transition.last) return prefix;
  const budget = Math.max(8, 100 - prefix.length - 9);
  return `${prefix} last='${clipWatchSnippet(transition.last, budget)}'`;
}

function watchTransitionJson(transition: WatchTransition): Record<string, unknown> {
  return {
    event: transition.kind,
    ts: transition.ts,
    session_id: transition.sessionId,
    ...(transition.reason !== undefined ? { reason: transition.reason } : {}),
    ...(transition.prevStatus !== undefined ? { prev: transition.prevStatus } : {}),
    status: transition.status ?? null,
    tool_calls: transition.toolsThisTurn,
    ...(transition.pendingDialogs !== undefined
      ? { pending_dialogs: transition.pendingDialogs }
      : {}),
    ...(transition.messageCount !== undefined ? { message_count: transition.messageCount } : {}),
    ...(transition.last !== undefined ? { last: clipWatchSnippet(transition.last, 200) } : {}),
  };
}

function watchResolvedJson(
  outcome: Extract<WatchOutcome, { kind: "all" }>,
): Record<string, unknown> {
  return {
    event: "resolved",
    all: true,
    condition: outcome.condition,
    sessions: outcome.sessions.map((session) => ({
      session_id: session.sessionId,
      status: session.status ?? null,
      ...(session.pendingDialogs !== undefined ? { pending_dialogs: session.pendingDialogs } : {}),
    })),
  };
}

function formatWatchResolved(outcome: Extract<WatchOutcome, { kind: "all" }>): string {
  return `all ${outcome.sessions.length} sessions reached ${outcome.condition}`;
}

export async function watchSessions(
  positional: string[],
  flags: Record<string, string>,
  jsonOutput: boolean,
  call: SessionListApiCall,
): Promise<void> {
  const ids = positional.map((value) => value.trim()).filter(Boolean);
  if (ids.length === 0) throw new Error("at least one session id is required");
  if (new Set(ids).size !== ids.length) throw new Error("session ids must be unique");
  const condition = parseWatchCondition(flags.until, "idle");
  if (condition === "either") {
    throw new Error("--until must be idle, attention, or any-change");
  }
  const emit = (transition: WatchTransition): void => {
    if (jsonOutput) process.stdout.write(`${JSON.stringify(watchTransitionJson(transition))}\n`);
    else console.log(formatWatchTransitionLine(transition));
  };

  try {
    const outcome = await runSessionWatch(
      ids,
      {
        condition,
        requireAll: flags.all === "true",
        intervalMs: parseDurationMs(flags.interval ?? "2s"),
        timeoutMs: parseDurationMs(flags.timeout ?? "30m"),
      },
      call,
      emit,
    );
    if (outcome.kind === "all") {
      if (jsonOutput) process.stdout.write(`${JSON.stringify(watchResolvedJson(outcome))}\n`);
      else console.log(formatWatchResolved(outcome));
    }
  } catch (err) {
    if (err instanceof SessionWatchTimeout) {
      if (jsonOutput) {
        process.stdout.write(
          `${JSON.stringify({ event: "timeout", condition: err.condition, pending: err.pending })}\n`,
        );
      } else {
        console.log(c.red(`timeout: ${err.message}`));
      }
      process.exitCode = 1;
      return;
    }
    if (jsonOutput) {
      const message = err instanceof Error ? err.message : String(err);
      const status = apiStatus(err);
      process.stdout.write(
        `${JSON.stringify({ event: "error", message, ...(status ? { status } : {}) })}\n`,
      );
      process.exitCode = 1;
      return;
    }
    throw err;
  }
}

async function sleep(ms: number): Promise<void> {
  await new Promise<void>((resolve) => setTimeout(resolve, ms));
}
