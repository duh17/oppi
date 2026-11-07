/**
 * The only writer of `Session.status`; the `session-status-writer` architecture rule rejects any
 * other assignment. The status is the phase's wire value: Build 57 and older decode six values as
 * a closed enum, so abort and terminate both show `stopping`. The phase is kept per Session object.
 * A row with no runtime, or a status the e2e UI harness set, is read from its status. An event
 * the phase does not allow is logged and ignored, because engines, timers and clients race.
 */

import type { AgentBackend } from "./agent-backend.js";
import { createLogger } from "./logger.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_lifecycle" } });

/** Phases a runtime holds between stops. */
type SettledPhase = "idle" | "running" | "failed";

export type LifecyclePhase =
  | { name: "starting" | SettledPhase | "stopped" }
  /**
   * `back` is where a failed stop returns: `running` while a turn is open (agent_start to
   * agent_settled). An abort of a compaction, or of a durable run whose agent_start has not
   * arrived, opens none.
   */
  | { name: "aborting" | "terminating"; back: SettledPhase };

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

const PHASE_OF_STATUS: Record<Session["status"], LifecyclePhase> = {
  starting: { name: "starting" },
  ready: { name: "idle" },
  busy: { name: "running" },
  stopping: { name: "terminating", back: "running" },
  stopped: { name: "stopped" },
  error: { name: "failed" },
};

/** A settled turn leaves its runtime idle; an error outlives the turn that settles after it. */
const settled = (phase: SettledPhase): SettledPhase => (phase === "running" ? "idle" : phase);

/** The next phase, or undefined when `event` is not allowed in `phase`. */
export function nextLifecyclePhase(
  phase: LifecyclePhase,
  event: LifecycleEvent,
): LifecyclePhase | undefined {
  const { name } = phase;
  const between = name === "idle" || name === "running" || name === "failed" ? name : undefined;
  const stopping = "back" in phase ? phase : undefined;
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
      return between ? { name: "aborting", back: between } : undefined;
    case "terminate_requested":
      if (stopping) return { name: "terminating", back: stopping.back };
      return between ? { name: "terminating", back: between } : undefined;
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
    : PHASE_OF_STATUS[session.status];
}

/** Move `session` through `event`. True when its status changed: persist and broadcast it. */
export function applyLifecycle(session: Session, event: LifecycleEvent): boolean {
  const from = lifecyclePhase(session);
  const to = nextLifecyclePhase(from, event);
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
