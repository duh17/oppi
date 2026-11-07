/**
 * The only writer of `Session.status`; the `session-status-writer` architecture rule rejects any
 * other assignment. The status is the phase's wire value: Build 57 and older decode six values as
 * a closed enum, so abort and terminate both show `stopping`. The phase is kept per Session object.
 * A row with no runtime, or a status the e2e UI harness set, is read from its status. An event
 * the phase does not allow is logged and ignored, because engines, timers and clients race.
 */

import type { AgentBackend } from "./agent-backend.js";
import { createLogger } from "./logger.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_lifecycle" } });

/** Phases a runtime holds between stops. */
type SettledPhase = "idle" | "running" | "failed";

export type StopRequestSource = "user" | "timeout" | "server";

/**
 * A stop's bookkeeping, carried on the `aborting`/`terminating` phase it belongs to instead of a
 * separate `PendingStop` record. A phase with a `stop` payload *is* "a stop is pending", so
 * `mode` (abort vs terminate) is gone too: it only ever duplicated the phase name.
 *
 * `claimed` marks that something has already taken ownership of finishing this stop — an abort
 * confirmed early at `agent_end` while its phase still shows `aborting` until `agent_settled`, or
 * a force-terminate already under way — so a second event racing the same stop backs off instead
 * of acting twice. A promotion from `aborting` to `terminating` clears it: the new terminate
 * episode has not claimed anything yet, even if the abort it replaces had.
 */
export interface StopState {
  source: StopRequestSource;
  claimed?: boolean;
  timeoutHandle?: NodeJS.Timeout;
  /**
   * Settles once this stop's phase ends: resolves for code that only needs to know it is over
   * (every caller in `session-stop.ts`). The mirror runtime's `stopSession` also awaits it as its
   * own call's outcome, so it can reject — a bridge that reports its stop command failed, or
   * never shuts down in time, rejects the caller that is still waiting on this specific stop.
   */
  completion: Promise<void>;
  resolveCompletion: () => void;
  rejectCompletion: (error: Error) => void;
  /** Opaque runtime-transaction permit a later continuation reads without closing over it. */
  permit?: SessionRuntimeTransactionPermit;
}

function newStopState(source: StopRequestSource): StopState {
  let resolveCompletion!: () => void;
  let rejectCompletion!: (error: Error) => void;
  const completion = new Promise<void>((resolve, reject) => {
    resolveCompletion = resolve;
    rejectCompletion = reject;
  });
  return { source, completion, resolveCompletion, rejectCompletion };
}

export type LifecyclePhase =
  | { name: "starting" | SettledPhase | "stopped" }
  /**
   * `back` is where a failed stop returns: `running` while a turn is open (agent_start to
   * agent_settled). An abort of a compaction, or of a durable run whose agent_start has not
   * arrived, opens none.
   */
  | { name: "aborting" | "terminating"; back: SettledPhase; stop: StopState };

/** The phase's stop bookkeeping, or undefined when it is not between `abort_requested`/
 * `terminate_requested` and whatever ends that stop. */
export function activeStop(session: Session): StopState | undefined {
  const phase = lifecyclePhase(session);
  return phase.name === "aborting" || phase.name === "terminating" ? phase.stop : undefined;
}

/** Whether `session` is between a stop request and its outcome, abort or terminate alike. */
export function isStopping(session: Session): boolean {
  const { name } = lifecyclePhase(session);
  return name === "aborting" || name === "terminating";
}

export type LifecycleEvent =
  /** A runtime is being created: a start, or a mirror's hello. */
  | "start_begun"
  | "start_registered"
  /** The start ended without a runtime. */
  | "start_failed"
  /** agent_start, a busy mirror bridge, or a start-time snapshot that streams. */
  | "run_started"
  /** agent_settled, an idle mirror bridge, or a confirmed abort of work that opened no turn. */
  | "run_settled"
  | "abort_requested"
  | "terminate_requested"
  | "stop_failed"
  /** The runtime is gone, or a row without one is stored stopped. */
  | "runtime_ended"
  /** Launch or start configuration failed: the row shows `error`. */
  | "launch_failed";

const WIRE_STATUS: Record<LifecyclePhase["name"], Session["status"]> = {
  starting: "starting",
  idle: "ready",
  running: "busy",
  aborting: "stopping",
  terminating: "stopping",
  stopped: "stopped",
  failed: "error",
};

/**
 * A row with no live phase (a fresh `Session` object after a restart or reload, or a status the
 * e2e UI harness set directly): reconstruct a phase that fits its persisted status. A `stopping`
 * row with no recollection of which stop it was gets a synthetic one (an escalation can still
 * force it; nothing else can tell abort from terminate after the fact).
 */
const PHASE_OF_STATUS: Record<Session["status"], () => LifecyclePhase> = {
  starting: () => ({ name: "starting" }),
  ready: () => ({ name: "idle" }),
  busy: () => ({ name: "running" }),
  stopping: () => ({ name: "terminating", back: "running", stop: newStopState("server") }),
  stopped: () => ({ name: "stopped" }),
  error: () => ({ name: "failed" }),
};

/** A settled turn leaves its runtime idle; an error outlives the turn that settles after it. */
const settled = (phase: SettledPhase): SettledPhase => (phase === "running" ? "idle" : phase);

/**
 * The next phase, or undefined when `event` is not allowed in `phase`. `stopSource` names who is
 * asking for `abort_requested`/`terminate_requested`; omit it only where a caller never starts a
 * fresh stop (the reducer-table test exercises every phase × event without one).
 */
export function nextLifecyclePhase(
  phase: LifecyclePhase,
  event: LifecycleEvent,
  stopSource?: StopRequestSource,
): LifecyclePhase | undefined {
  const { name } = phase;
  const between = name === "idle" || name === "running" || name === "failed" ? name : undefined;
  const stopping = name === "aborting" || name === "terminating" ? phase : undefined;
  switch (event) {
    case "start_begun":
      return { name: "starting" };
    case "start_registered":
      return name === "starting" ? { name: "idle" } : undefined;
    case "start_failed":
      return name === "starting" ? { name: "stopped" } : undefined;
    case "run_started":
      if (stopping) return { ...stopping, back: "running" };
      return between ? { name: "running" } : undefined;
    case "run_settled":
      if (stopping?.name === "terminating") return { ...stopping, back: settled(stopping.back) };
      if (stopping) return { name: settled(stopping.back) };
      return between ? { name: settled(between) } : undefined;
    case "abort_requested":
      return between
        ? { name: "aborting", back: between, stop: newStopState(stopSource ?? "user") }
        : undefined;
    case "terminate_requested":
      if (stopping) {
        // A promotion from an abort has not claimed anything as this terminate: its own
        // force-terminate must still run, not be blocked by the abort's early agent_end claim.
        if (stopping.name === "aborting" && stopping.stop) stopping.stop.claimed = false;
        if (stopSource && stopping.stop) stopping.stop.source = stopSource;
        return { name: "terminating", back: stopping.back, stop: stopping.stop };
      }
      return between
        ? { name: "terminating", back: between, stop: newStopState(stopSource ?? "user") }
        : undefined;
    case "stop_failed":
      return stopping ? { name: stopping.back } : undefined;
    case "runtime_ended":
      return { name: "stopped" };
    case "launch_failed":
      return { name: "failed" };
  }
}

const phases = new WeakMap<Session, LifecyclePhase>();

export function lifecyclePhase(session: Session): LifecyclePhase {
  const phase = phases.get(session);
  return phase && WIRE_STATUS[phase.name] === session.status
    ? phase
    : PHASE_OF_STATUS[session.status]();
}

/**
 * Move `session` through `event`. True when its status changed: persist and broadcast it.
 * `stopSource` names who is asking, for `abort_requested`/`terminate_requested`.
 */
export function applyLifecycle(
  session: Session,
  event: LifecycleEvent,
  stopSource?: StopRequestSource,
): boolean {
  const from = lifecyclePhase(session);
  const to = nextLifecyclePhase(from, event, stopSource);
  if (!to) {
    log.warn("session_lifecycle.illegal_transition", {
      sessionId: session.id,
      phase: from.name,
      event,
    });
    return false;
  }
  phases.set(session, to);
  const status = WIRE_STATUS[to.name];
  if (session.status === status) return false;
  session.status = status;
  return true;
}

/**
 * Whether a turn runs: the phase says so until an abort settles, or the engine streams or
 * compacts. The engine read covers a durable run committed before its agent_start arrived.
 */
export function turnRunning(active: {
  session: Session;
  sdkBackend?: Partial<Pick<AgentBackend, "isStreaming" | "isCompacting">>;
}): boolean {
  const phase = lifecyclePhase(active.session).name;
  return (
    phase === "running" ||
    phase === "aborting" ||
    active.sdkBackend?.isStreaming === true ||
    active.sdkBackend?.isCompacting === true
  );
}
