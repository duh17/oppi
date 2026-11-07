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
 * A stop's bookkeeping, carried on its `aborting`/`terminating` phase. `claimed` marks a stop
 * something already finishes (an abort confirmed at agent_end before agent_settled, or a force
 * terminate under way), so a racing event backs off; promotion to a terminate clears it.
 */
export interface StopState {
  source: StopRequestSource;
  claimed?: boolean;
  timeoutHandle?: NodeJS.Timeout;
  /** Resolves once the stop is over: with the error when it failed, so it never rejects. */
  completion: Promise<Error | undefined>;
  settle: (error?: Error) => void;
  /** The runtime-transaction permit a later continuation reads without closing over it. */
  permit?: SessionRuntimeTransactionPermit;
}

function newStopState(source: StopRequestSource): StopState {
  let settle!: (error?: Error) => void;
  const completion = new Promise<Error | undefined>((resolve) => (settle = resolve));
  return { source, completion, settle };
}

export type LifecyclePhase =
  | { name: "starting" | SettledPhase | "stopped" }
  /**
   * `back` is where a failed stop returns: `running` while a turn is open (agent_start to
   * agent_settled). An abort of a compaction, or of a durable run whose agent_start has not
   * arrived, opens none.
   */
  | { name: "aborting" | "terminating"; back: SettledPhase; stop: StopState };

/** The stop under way from its request until its outcome; with `name`, only in that phase. */
export function activeStop(
  session: Session,
  name?: "aborting" | "terminating",
): StopState | undefined {
  const phase = lifecyclePhase(session);
  return "stop" in phase && (!name || phase.name === name) ? phase.stop : undefined;
}

export function isStopping(session: Session): boolean {
  return activeStop(session) !== undefined;
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

/** The phase of a row whose status was written elsewhere (a reload, the e2e UI harness). */
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

/** The next phase, or undefined when `event` is not allowed in `phase`. */
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
        // An abort's agent_end claim does not cover the terminate it becomes: its force must run.
        if (name === "aborting") stopping.stop.claimed = false;
        if (stopSource) stopping.stop.source = stopSource;
        return { ...stopping, name: "terminating" };
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
  if (phase && WIRE_STATUS[phase.name] === session.status) return phase;
  // Remembered, so a reconstructed stop keeps one identity across reads.
  const reconstructed = PHASE_OF_STATUS[session.status]();
  phases.set(session, reconstructed);
  return reconstructed;
}

/** Move `session` through `event`. True when its status changed: persist and broadcast it. */
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
