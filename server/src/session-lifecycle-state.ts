/**
 * The lifecycle of a session's runtime, and the only writer of `Session.status`
 * (`check-architecture-boundaries` rejects an assignment anywhere else).
 *
 * The wire `status` projects the phase onto the six values Build 57 and older decode as a
 * closed enum, so abort and terminate share `stopping`. The phase belongs to the Session object
 * a runtime holds; a row with no runtime, or a status set outside this module (a new row, the
 * e2e UI harness), stands for its own phase. An event the phase does not allow is logged and
 * ignored, never thrown: engines, timers and clients send events in any order.
 *
 * `session_runtime_live` (Storage) records live runtimes, so a crash restart resumes those only
 * and tells an abort from a terminate. This writes it when a runtime begins and when a terminate
 * begins or fails; saving a row stopped or failed deletes it. So the record exists before a row
 * says live and outlives it until the row says otherwise.
 */

import { createLogger } from "./logger.js";
import type { RuntimeLivePhase, Storage } from "./storage.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_lifecycle" } });

export type LifecyclePhase =
  | { name: "starting" }
  | { name: "idle" }
  | { name: "running" }
  /**
   * `run`: a turn is open, from its agent_start to its agent_settled. An abort or terminate
   * of a compaction, or of a durable run whose agent_start has not arrived, opens none.
   */
  | { name: "aborting"; run: boolean }
  | { name: "terminating"; run: boolean }
  | { name: "stopped" }
  | { name: "failed" };

export type LifecycleEvent =
  /** A runtime is being created for the session (a start, a mirror's hello). */
  | "start_begun"
  /** The runtime registered and idles. */
  | "start_registered"
  /** The start ended without a runtime. */
  | "start_failed"
  /** agent_start, a busy mirror bridge, or a start-time snapshot that streams. */
  | "run_started"
  /** agent_settled, an idle mirror bridge, or a confirmed abort of a run-less compaction. */
  | "run_settled"
  | "abort_requested"
  | "terminate_requested"
  /** A stop gave up; the session goes back to what it was doing. */
  | "stop_failed"
  /** The runtime is gone: its end, a crash, or a stop of a row that had none. */
  | "runtime_ended"
  /** Launch or start configuration failed: the row shows `error`. */
  | "launch_failed";

/** Events that write the live-runtime record. */
type MarkerEvent = "start_begun" | "terminate_requested" | "stop_failed";

export type RuntimeLiveMarkers = Pick<Storage, "markRuntimeLive">;

const STARTING: LifecyclePhase = { name: "starting" };
const IDLE: LifecyclePhase = { name: "idle" };
const RUNNING: LifecyclePhase = { name: "running" };
const STOPPED: LifecyclePhase = { name: "stopped" };
const FAILED: LifecyclePhase = { name: "failed" };

const WIRE_STATUS: Record<LifecyclePhase["name"], Session["status"]> = {
  starting: "starting",
  idle: "ready",
  running: "busy",
  aborting: "stopping",
  terminating: "stopping",
  stopped: "stopped",
  failed: "error",
};

/** The next phase, or undefined when `event` is not allowed in `phase`. */
export function nextLifecyclePhase(
  phase: LifecyclePhase,
  event: LifecycleEvent,
): LifecyclePhase | undefined {
  switch (event) {
    case "start_begun":
      return STARTING;
    case "start_registered":
      return phase.name === "starting" ? IDLE : undefined;
    case "start_failed":
      return phase.name === "starting" ? STOPPED : undefined;
    case "run_started":
      if (phase.name === "aborting" || phase.name === "terminating") return { ...phase, run: true };
      return phase.name === "idle" || phase.name === "running" || phase.name === "failed"
        ? RUNNING
        : undefined;
    case "run_settled":
      if (phase.name === "terminating") return { name: "terminating", run: false };
      return phase.name === "idle" || phase.name === "running" || phase.name === "aborting"
        ? IDLE
        : undefined;
    case "abort_requested":
      if (phase.name === "running") return { name: "aborting", run: true };
      return phase.name === "idle" || phase.name === "failed"
        ? { name: "aborting", run: false }
        : undefined;
    case "terminate_requested":
      switch (phase.name) {
        case "starting":
        case "idle":
        case "failed":
          return { name: "terminating", run: false };
        case "running":
          return { name: "terminating", run: true };
        case "aborting":
        case "terminating":
          return { name: "terminating", run: phase.run };
        default:
          return undefined;
      }
    case "stop_failed":
      if (phase.name !== "aborting" && phase.name !== "terminating") return undefined;
      return phase.run ? RUNNING : IDLE;
    case "runtime_ended":
      return STOPPED;
    case "launch_failed":
      return FAILED;
  }
}

/**
 * The phase a stored status stands for. `stopping` is read as a terminate unless the live
 * record says the runtime was only aborting a turn.
 */
export function phaseOfStoredStatus(
  status: Session["status"],
  live?: RuntimeLivePhase,
): LifecyclePhase {
  switch (status) {
    case "starting":
      return STARTING;
    case "ready":
      return IDLE;
    case "busy":
      return RUNNING;
    case "stopping":
      return live === "live" ? { name: "aborting", run: true } : { name: "terminating", run: true };
    case "stopped":
      return STOPPED;
    case "error":
      return FAILED;
  }
}

const phases = new WeakMap<Session, LifecyclePhase>();

export function lifecyclePhase(session: Session): LifecyclePhase {
  const phase = phases.get(session);
  return phase && WIRE_STATUS[phase.name] === session.status
    ? phase
    : phaseOfStoredStatus(session.status);
}

/**
 * Move `session` through `event` and set its status to the new phase's wire value. True when
 * the status changed, which is when a caller persists and broadcasts it.
 */
export function applyLifecycle(
  session: Session,
  event: MarkerEvent,
  markers: RuntimeLiveMarkers,
): boolean;
export function applyLifecycle(
  session: Session,
  event: Exclude<LifecycleEvent, MarkerEvent>,
): boolean;
export function applyLifecycle(
  session: Session,
  event: LifecycleEvent,
  markers?: RuntimeLiveMarkers,
): boolean {
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
  if (event === "start_begun" || (event === "stop_failed" && from.name === "terminating")) {
    markers?.markRuntimeLive(session.id, "live");
  } else if (event === "terminate_requested") {
    markers?.markRuntimeLive(session.id, "terminating");
  }
  phases.set(session, to);
  const status = WIRE_STATUS[to.name];
  if (session.status === status) return false;
  session.status = status;
  return true;
}
