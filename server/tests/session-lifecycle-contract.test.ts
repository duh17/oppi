import { readFileSync } from "node:fs";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { queueOrphanedSessionsForRestart } from "../src/session-restart-resume.js";
import { Storage } from "../src/storage.js";
import type { ServerMessage, Session } from "../src/types.js";
import {
  assistantEnd,
  buildSessionLifecycleWire,
  classicWorld,
  flush,
  serializeSessionLifecycleWire,
  SESSION_ID,
  SESSION_LIFECYCLE_WIRE_FILE,
  setCompacting,
  setStreaming,
  type ClassicWorld,
  type LifecycleScenario,
  type RecordedFrame,
  type SessionLifecycleWire,
} from "./session-lifecycle-wire.js";

// Characterisation of the session lifecycle as a client and the CLI see it today, across the
// classic, durable, and mirror engines. It pins observed behaviour, including behaviour a later
// slice of the simplified-architecture plan changes on purpose: those rows say so, and the slice
// that changes one edits its expectation here. Nothing in this file asserts what the lifecycle
// should be.
//
// Every scenario runs against the real SessionManager, storage, app-event mux, and CLI wait loop;
// only the Pi runtime is replaced (a stub backend for classic, a faux provider for durable, a fake
// bridge socket for mirror). The recorded frames are `protocol/session-lifecycle-wire.json`,
// compared byte for byte below. The Apple replay test reads the same file. Regenerate it only with
// `npm run protocol:fixtures:update`.

let wire: SessionLifecycleWire;
beforeAll(async () => {
  wire = await buildSessionLifecycleWire();
}, 180_000);

afterEach(() => {
  vi.useRealTimers();
});

const scenario = (id: string): LifecycleScenario => {
  const found = wire.scenarios.find((candidate) => candidate.id === id);
  if (!found) throw new Error(`No recorded scenario ${id}`);
  return found;
};

// ─── Projections: what the pinned sequences below are made of ───

const SEQUENCE_FRAMES = new Set([
  "state",
  "session_summary",
  "agent_start",
  "agent_end",
  "agent_settled",
  "stop_requested",
  "stop_confirmed",
  "stop_failed",
  "session_ended",
  "error",
  "session_error",
  "extension_ui_request",
  "extension_ui_settled",
  "compaction_start",
  "compaction_end",
  "command_result",
]);

function programLabel(program: { state: string; kind?: string }): string {
  return program.kind ? `${program.state}(${program.kind})` : program.state;
}

function frameLabel(entry: RecordedFrame): string | undefined {
  const frame = entry.frame as {
    type: string;
    session?: { status: string; programStatus: { state: string; kind?: string } };
    summary?: { status: string; programStatus: { state: string; kind?: string } };
    reason?: string;
    error?: string;
    message?: string;
  };
  if (!SEQUENCE_FRAMES.has(frame.type)) return undefined;
  const body = frame.session ?? frame.summary;
  const detail = body
    ? ` ${body.status}/${programLabel(body.programStatus)}`
    : (frame.reason ?? frame.error ?? frame.message)
      ? ` "${frame.reason ?? frame.error ?? frame.message}"`
      : "";
  return `${frame.type === "session_summary" ? "summary" : frame.type}${detail}`;
}

const withoutRepeats = (labels: string[]): string[] =>
  labels.filter((label, index) => label !== labels[index - 1]);

/** The frames one channel delivered, in order, with a repeat of the same label folded away. */
function sequence(found: LifecycleScenario, channel: RecordedFrame["channel"]): string[] {
  return withoutRepeats(
    found.frames
      .filter((entry) => entry.channel === channel)
      .map(frameLabel)
      .filter((label): label is string => label !== undefined),
  );
}

/**
 * Where the row, the program status, and the CLI wait stood after each step, listing only the steps
 * where one of them moved or the row was saved.
 */
function steps(found: LifecycleScenario): string[] {
  const out: string[] = [];
  let previous: string | undefined;
  for (const checkpoint of found.checkpoints) {
    const program = checkpoint.row.programStatus;
    const standing = `${checkpoint.row.status}/${program ? programLabel(program) : "-"}${
      checkpoint.live ? "" : " not live"
    } wait:${checkpoint.cliWait}${checkpoint.pendingWake ? " wake" : ""}`;
    const saved = checkpoint.persisted.length > 0 ? ` saved:${checkpoint.persisted.join(">")}` : "";
    if (standing === previous && saved === "") continue;
    previous = standing;
    out.push(`${checkpoint.step}: ${standing}${saved}`);
  }
  return out;
}

// What a client receives, per scenario. `ws` is the focused session stream, `app` the app-event
// stream, `steps` the server's own standing (row, program status, CLI wait, saves) after each step.
// A row says what happens today; a comment says where a planned slice will change it.
const EXPECTED: Record<string, { ws: string[]; app: string[]; steps: string[] }> = {
  "classic.prompt_settle": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: ["summary busy/working", "summary ready/done"],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  // The trace read inside the gap leaves the row busy, saves nothing, and sends no frame: the
  // only steps listed are the start, the busy run, and the settle after the retry.
  "classic.retry_gap_trace_read": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      'error "429 overloaded"',
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      'session_error "429 overloaded"',
      "summary busy/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "retry_agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  // An error frame reaches both streams while the row stays busy; the program status carries the
  // run's last response, so the failure shows only after the settle.
  "classic.run_error": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      'error "401 invalid credentials second line"',
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/error",
    ],
    app: [
      "summary busy/working",
      'session_error "401 invalid credentials second line"',
      "summary busy/working",
      "summary ready/error",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "agent_settled: ready/error wait:idle saved:ready",
    ],
  },
  // A blocking dialog is visible only to the app-event stream as a blocked summary. The focused
  // stream gets the request and its settle, and no summary until the run ends.
  "classic.dialog_blocked": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "extension_ui_request",
      "extension_ui_settled",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      "extension_ui_request",
      "summary busy/blocked(permission)",
      "extension_ui_settled",
      "summary busy/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "dialog_opened: busy/blocked(permission) wait:waiting",
      "dialog_answered: busy/working wait:waiting",
      "agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  // stop_confirmed arrives at agent_end while the row still says stopping; ready comes only with
  // agent_settled.
  "classic.abort_mid_turn": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "agent_end",
      "stop_confirmed",
      "summary stopping/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      "stop_confirmed",
      "summary stopping/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "abort: stopping/working wait:waiting saved:stopping",
      "agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  "classic.abort_quiet_tool": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "agent_end",
      "stop_confirmed",
      "summary stopping/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      "stop_confirmed",
      "summary stopping/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "abort_pending: stopping/working wait:waiting saved:stopping",
      "agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  // A rejected abort puts the row back to busy, with the state frame before stop_failed.
  "classic.abort_rejected": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "state busy/working",
      'stop_failed "Abort failed: abort rejected"',
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      "summary busy/working",
      'stop_failed "Abort failed: abort rejected"',
      "summary busy/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "abort: busy/working wait:waiting saved:stopping>busy",
      "agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  "classic.abort_idle": {
    ws: ["state ready/idle", 'stop_confirmed "Session already idle"'],
    app: ['stop_confirmed "Session already idle"'],
    steps: ["start: ready/idle wait:idle saved:starting>ready"],
  },
  "classic.terminate_busy": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "agent_end",
      "summary stopping/working",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    app: [
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "stop_requested: stopping/working wait:waiting saved:stopping",
      "agent_end: stopped/idle not live wait:idle saved:stopped",
    ],
  },
  "classic.terminate_idle": {
    ws: [
      "state ready/idle",
      "stop_requested",
      "state stopping/idle",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    app: [
      "stop_requested",
      "summary stopping/idle",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "stop: stopped/idle not live wait:idle saved:stopping>stopped",
    ],
  },
  // No socket can attach before the runtime registers, so only the app-event stream sees this. The
  // start registers (saving ready) and then the stop runs; the row ends stopped.
  "classic.stop_during_start": {
    ws: [],
    app: [
      "stop_requested",
      "summary stopping/idle",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    steps: [
      "start_begun: starting/idle not live wait:waiting saved:starting",
      "create_finished: stopped/idle not live wait:idle saved:ready>stopping>stopped",
    ],
  },
  "classic.start_fails": {
    ws: [],
    app: [],
    steps: [
      "start_begun: starting/idle not live wait:waiting saved:starting",
      "create_failed: stopped/idle not live wait:idle saved:stopped",
    ],
  },
  // Nothing announces the seeded busy: only a socket that attaches afterwards learns it from the
  // initial state frame, and the app-event stream stays silent.
  "classic.start_streaming_snapshot": {
    ws: ["state busy/working"],
    app: [],
    steps: ["start: busy/working wait:waiting saved:starting>ready>busy"],
  },
  // A compact asked for mid-turn is held until the turn settles, then runs on a ready row:
  // program status says working (Compacting context) and the CLI wait holds until it ends. A
  // program status derived from the lifecycle phase alone (idle here) would lose that.
  "classic.compaction_queued": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      'compaction_start "manual"',
      "summary ready/working",
      "compaction_end",
      "summary ready/done",
      "command_result",
    ],
    app: ["summary busy/working", "summary ready/working", "summary ready/done"],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "agent_settled: ready/working wait:waiting saved:ready",
      "compaction_end: ready/done wait:idle",
    ],
  },
  // S5 DELIBERATELY CHANGES the `agent_settled` step of this row. A session idle and waiting on a
  // background job shows Done today (ready/done) while the CLI wait says it is not idle. The owner
  // decided S5 shows Working there instead, so ready/done becomes ready/working in the frames and the
  // steps below, and the wait answer is unchanged.
  "classic.wake_hold": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary busy/working",
      "summary ready/done",
      "summary busy/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "agent_start: busy/working wait:waiting",
      "agent_settled: ready/done wait:waiting wake saved:ready",
      "wake_agent_start: busy/working wait:waiting",
      "wake_agent_settled: ready/done wait:idle saved:ready",
    ],
  },
  // The mirror's row follows the bridge's busy flag, so it flips before the events do, and
  // agent_settled finds the row already ready.
  "mirror.busy_idle_stop": {
    ws: [
      "state ready/idle",
      "state busy/working",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
      "state ready/done",
      "state stopped/done",
      "summary stopped/done",
    ],
    app: [
      "summary ready/idle",
      "summary busy/working",
      "summary ready/done",
      "summary stopped/done",
    ],
    steps: [
      "hello: ready/idle wait:idle saved:ready",
      "state_busy: busy/working wait:waiting saved:busy",
      "agent_start: busy/working wait:waiting saved:busy",
      "message_end: busy/working wait:waiting saved:busy",
      "agent_end: busy/working wait:waiting saved:busy",
      "agent_settled: ready/done wait:idle saved:ready",
      "goodbye: stopped/done wait:idle saved:stopped",
    ],
  },
  // S3 DELIBERATELY CHANGES this row: the mirror's abort sends the bridge command and nothing
  // else today. No stop_requested, no stopping, no stop_confirmed.
  "mirror.abort_mid_turn": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/idle",
    ],
    app: ["summary ready/idle", "summary busy/working", "summary ready/idle"],
    steps: [
      "hello: ready/idle wait:idle saved:ready",
      "agent_start: busy/working wait:waiting saved:busy",
      "agent_end: busy/working wait:waiting saved:busy",
      "agent_settled: ready/idle wait:idle saved:ready",
    ],
  },
  "durable.prompt_settle": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: ["summary ready/idle", "summary busy/working", "summary ready/done"],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "prompt: ready/done wait:idle saved:ready",
    ],
  },
  "durable.abort_mid_turn": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "agent_end",
      "stop_confirmed",
      "summary stopping/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary ready/idle",
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      "stop_confirmed",
      "summary stopping/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "prompt: busy/working wait:waiting",
      "abort: ready/done wait:idle saved:stopping>ready",
    ],
  },
  "durable.terminate_busy": {
    ws: [
      "state ready/idle",
      "agent_start",
      "summary busy/working",
      "stop_requested",
      "state stopping/working",
      "agent_end",
      "summary stopping/working",
      "agent_settled",
      "summary stopping/done",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    app: [
      "summary ready/idle",
      "summary busy/working",
      "stop_requested",
      "summary stopping/working",
      "summary stopping/done",
      'stop_confirmed "Session terminated"',
      'session_ended "stopped"',
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "prompt: busy/working wait:waiting",
      "stop: stopped/done not live wait:idle saved:stopping>stopped",
    ],
  },
  // The store committed the prompt and its run is going, but the session has not seen agent_start:
  // the row is ready, the CLI wait holds (the pending-work read), and an abort answers that the
  // session is idle while the run continues. S1's single turnRunning predicate changes that abort
  // answer; the wait and the frames after the release stay.
  "durable.commit_before_agent_start": {
    ws: [
      "state ready/idle",
      'stop_confirmed "Session already idle"',
      "agent_start",
      "summary busy/working",
      "state busy/working",
      "agent_end",
      "summary busy/working",
      "agent_settled",
      "summary ready/done",
    ],
    app: [
      "summary ready/idle",
      'stop_confirmed "Session already idle"',
      "summary busy/working",
      "summary ready/done",
    ],
    steps: [
      "start: ready/idle wait:idle saved:starting>ready",
      "committed: ready/idle wait:waiting wake",
      "released: ready/done wait:idle saved:busy>ready",
    ],
  },
  "durable.start_fails_after_registration": {
    ws: [],
    app: ['session_ended "start_error"'],
    steps: ["start: stopped/idle not live wait:idle saved:starting>ready>stopped"],
  },
};

describe("recorded fixture", () => {
  it("is exactly what the scenarios record", () => {
    expect(readFileSync(SESSION_LIFECYCLE_WIRE_FILE, "utf8")).toBe(
      serializeSessionLifecycleWire(wire),
    );
  });

  it("has an expectation for every scenario and a scenario for every expectation", () => {
    expect(wire.scenarios.map((found) => found.id).sort()).toEqual(Object.keys(EXPECTED).sort());
  });

  it("names the rows a planned slice changes on purpose, and only those", () => {
    const planned = Object.fromEntries(
      wire.scenarios
        .filter((found) => found.plannedChange)
        .map((found) => [found.id, found.plannedChange?.slice]),
    );
    expect(planned).toEqual({
      "classic.stop_during_start": "S2",
      "classic.wake_hold": "S5",
      "mirror.busy_idle_stop": "S3",
      "mirror.abort_mid_turn": "S3",
      "durable.commit_before_agent_start": "S1",
    });
  });

  it("carries the server's own status on every state and summary frame it delivers", () => {
    for (const found of wire.scenarios) {
      for (const entry of found.frames) {
        const frame = entry.frame as {
          type: string;
          session?: { status: string };
          summary?: { status: string };
        };
        const body = frame.session ?? frame.summary;
        if (!body || entry.step === "attach") continue;
        expect({
          scenario: found.id,
          step: entry.step,
          type: frame.type,
          status: body.status,
        }).toEqual({
          scenario: found.id,
          step: entry.step,
          type: frame.type,
          status: entry.server.status,
        });
      }
    }
  });
});

describe("session lifecycle on the wire", () => {
  it.each(Object.entries(EXPECTED))("%s", (id, expected) => {
    const found = scenario(id);
    expect({
      ws: sequence(found, "focused"),
      app: sequence(found, "app"),
      steps: steps(found),
    }).toEqual(expected);
  });
});

// ─── Input admission: what each input gets at each point of a turn ───
//
// Today five predicates decide whether a turn runs (row status, Pi's streaming and compacting
// flags, in different combinations); S1 replaces them with one `turnRunning`. This table is what a
// client gets for each input at each point, so a slice that moves one cell has to say so.

const ADMISSION_POINTS: Record<string, (world: ClassicWorld) => Promise<void>> = {
  idle: async () => {},
  running: async (world) => {
    setStreaming(world, true);
    world.emit({ type: "agent_start" });
  },
  // Pi reports idle between a failed response's agent_end and its auto-retry.
  retry_gap: async (world) => {
    setStreaming(world, true);
    world.emit({ type: "agent_start" });
    world.emit(assistantEnd("", "error", "429 overloaded"));
    setStreaming(world, false);
    world.emit({ type: "agent_end", messages: [] });
  },
  // An abort whose run has ended but not settled: the row says stopping, Pi is idle.
  aborting_after_agent_end: async (world) => {
    setStreaming(world, true);
    world.emit({ type: "agent_start" });
    await world.manager.sendAbort(SESSION_ID);
    setStreaming(world, false);
    world.emit({ type: "agent_end", messages: [] });
  },
  // A compaction with no turn: the row says ready, Pi is compacting.
  compacting: async (world) => {
    setCompacting(world, true);
    world.emit({ type: "compaction_start", reason: "threshold" });
  },
};

type AdmissionInput = "prompt" | "steer" | "follow_up" | "compact" | "abort";
const ADMISSION_INPUTS: AdmissionInput[] = ["prompt", "steer", "follow_up", "compact", "abort"];

const answered = (pending: Promise<unknown>): Promise<string> =>
  pending.then(
    () => "accepted",
    (error: unknown) => `rejected: ${error instanceof Error ? error.message : String(error)}`,
  );

async function send(
  world: ClassicWorld,
  input: AdmissionInput,
  frames: ServerMessage[],
): Promise<string> {
  switch (input) {
    case "prompt":
      return answered(world.manager.sendPrompt(SESSION_ID, "next"));
    case "steer":
      return answered(world.manager.sendSteer(SESSION_ID, "steer"));
    case "follow_up":
      return answered(world.manager.sendFollowUp(SESSION_ID, "later"));
    case "compact": {
      await world.manager.forwardClientCommand(SESSION_ID, { type: "compact" }, "compact-1");
      await flush();
      const result = frames.find((message) => message.type === "command_result");
      if (!result) return "queued";
      return result.success ? "ran" : `rejected: ${result.error}`;
    }
    case "abort": {
      await world.manager.sendAbort(SESSION_ID);
      await flush();
      const answer = frames.find(
        (message) => message.type === "stop_requested" || message.type === "stop_confirmed",
      );
      if (!answer) return "no answer";
      return answer.type === "stop_confirmed" ? `confirmed: ${answer.reason}` : "stopping";
    }
  }
}

/** What one input gets from a fresh session brought to `point`. */
async function admission(point: string, input: AdmissionInput): Promise<string> {
  const world = await classicWorld({ id: "admission", engine: "classic", description: point });
  try {
    await world.manager.startSession(SESSION_ID, world.workspace);
    await ADMISSION_POINTS[point]?.(world);
    await flush();
    const frames: ServerMessage[] = [];
    const unsubscribe = world.manager.subscribe(SESSION_ID, (message) => frames.push(message));
    try {
      return await send(world, input, frames);
    } finally {
      unsubscribe();
    }
  } finally {
    // End a turn still open, so closing does not wait out the stop grace for it.
    setStreaming(world, false);
    setCompacting(world, false);
    const left = world.manager.getActiveSession(SESSION_ID)?.status;
    if (left === "busy" || left === "stopping") {
      world.emit({ type: "agent_end", messages: [] });
      world.emit({ type: "agent_settled" });
      await flush();
    }
    await world.dispose();
  }
}

const BUSY_PROMPT =
  "rejected: Prompt requires an idle session; use steer or follow_up while a turn is streaming";
const IDLE_STEER = "rejected: Steer requires an active streaming turn";
const IDLE_FOLLOW_UP = "rejected: Follow-up requires an active streaming turn";

const EXPECTED_ADMISSION: Record<string, Record<AdmissionInput, string>> = {
  idle: {
    prompt: "accepted",
    steer: IDLE_STEER,
    follow_up: IDLE_FOLLOW_UP,
    compact: "ran",
    abort: "confirmed: Session already idle",
  },
  running: {
    prompt: BUSY_PROMPT,
    steer: "accepted",
    follow_up: "accepted",
    compact: "queued",
    abort: "stopping",
  },
  retry_gap: {
    prompt: BUSY_PROMPT,
    steer: "accepted",
    follow_up: "accepted",
    compact: "queued",
    abort: "stopping",
  },
  // The row says stopping, but stop_confirmed has gone out and Pi is idle, so a prompt is
  // admitted and a second abort hears "already idle". S1 CHANGES this row: `turnRunning` holds
  // through `aborting`, so the prompt is refused and the steer and follow-up are accepted.
  aborting_after_agent_end: {
    prompt: "accepted",
    steer: IDLE_STEER,
    follow_up: IDLE_FOLLOW_UP,
    compact: "queued",
    abort: "confirmed: Session already idle",
  },
  // Steer and follow-up count a compaction as a running turn; abort reads only the row and
  // answers idle. S1 CHANGES the abort cell: one `turnRunning` makes abort agree with admission.
  compacting: {
    prompt: BUSY_PROMPT,
    steer: "accepted",
    follow_up: "accepted",
    compact: "rejected: compact requires an idle session",
    abort: "confirmed: Session already idle",
  },
};

describe("input admission", () => {
  it.each(Object.keys(EXPECTED_ADMISSION))("%s", async (point) => {
    const answers: Record<string, string> = {};
    for (const input of ADMISSION_INPUTS) answers[input] = await admission(point, input);
    expect(answers).toEqual(EXPECTED_ADMISSION[point]);
  });
});

// ─── Keep-alive: what keeps a session alive, and for how long ───
//
// Timer-driven, so these run on a fake clock and sit outside the recorded fixture. The idle
// timeout is the 10-minute default.

const IDLE_MINUTES = 10;
const QUIET_TURN_LIMIT_MINUTES = 120;

async function minutes(count: number): Promise<void> {
  await vi.advanceTimersByTimeAsync(count * 60_000);
}

async function fakeClockWorld(
  row: Partial<Session> = {},
): Promise<{ world: ClassicWorld; ended: string[] }> {
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
  const world = await classicWorld({
    id: "keep-alive",
    engine: "classic",
    description: "keep-alive",
    row,
  });
  await world.manager.startSession(SESSION_ID, world.workspace);
  const ended: string[] = [];
  world.manager.subscribe(SESSION_ID, (message) => {
    if (message.type === "session_ended") ended.push(message.reason);
  });
  return { world, ended };
}

/**
 * Let a stop that started on the fake clock finish. It runs its grace timers and then real async
 * teardown, which a single advance does not wait for.
 */
async function untilStopped(world: ClassicWorld): Promise<void> {
  for (let tick = 0; tick < 50 && world.manager.isActive(SESSION_ID); tick += 1) {
    await vi.advanceTimersByTimeAsync(1_000);
    await new Promise((resolve) => setImmediate(resolve));
  }
}

/** The live session's status: the stored row trails it between saves. */
const status = (world: ClassicWorld): Session["status"] | undefined =>
  (world.manager.getActiveSession(SESSION_ID) ?? world.storage.getSession(SESSION_ID))?.status;

/**
 * Close on real timers: a test that fails with a stop pending on the fake clock would otherwise
 * hang the close and hide its own failure.
 */
async function closeWorld(world: ClassicWorld): Promise<void> {
  vi.useRealTimers();
  await world.dispose();
}

describe("idle expiry", () => {
  it("stops a session that has been quiet for the idle timeout", async () => {
    const { world, ended } = await fakeClockWorld();
    try {
      await minutes(IDLE_MINUTES - 1);
      expect(world.manager.isActive(SESSION_ID)).toBe(true);

      await minutes(1);
      await untilStopped(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(status(world)).toBe("stopped");
      expect(ended).toEqual(["stopped"]);
    } finally {
      await closeWorld(world);
    }
  });

  it("holds a running turn through the idle timeout until it has been quiet for two hours", async () => {
    const { world, ended } = await fakeClockWorld();
    try {
      setStreaming(world, true);
      world.emit({ type: "agent_start" });

      await minutes(QUIET_TURN_LIMIT_MINUTES - 1);
      expect(world.manager.isActive(SESSION_ID)).toBe(true);
      expect(status(world)).toBe("busy");

      await minutes(1);
      await untilStopped(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(status(world)).toBe("stopped");
      expect(ended).toEqual(["stopped"]);
    } finally {
      await closeWorld(world);
    }
  });

  it("restarts the quiet window with every event the running turn sends", async () => {
    const { world } = await fakeClockWorld();
    try {
      setStreaming(world, true);
      world.emit({ type: "agent_start" });
      await minutes(100);
      world.emit({ type: "tool_execution_start", toolName: "bash", toolCallId: "tc-1", args: {} });

      await minutes(100);

      expect(world.manager.isActive(SESSION_ID)).toBe(true);
      expect(status(world)).toBe("busy");
    } finally {
      await closeWorld(world);
    }
  });

  it("expires a busy row whose backend is not running, at the idle timeout", async () => {
    const { world } = await fakeClockWorld();
    try {
      // A missed settle: the row says busy, the backend is idle.
      setStreaming(world, false);
      world.emit({ type: "agent_start" });
      expect(status(world)).toBe("busy");

      await minutes(IDLE_MINUTES);
      // The stop of a busy turn waits for the run to end, then gives up after its grace.
      await untilStopped(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(status(world)).toBe("stopped");
    } finally {
      await closeWorld(world);
    }
  });

  it("holds an idle session that waits on a reply dialog, and expires it after the answer", async () => {
    const { world } = await fakeClockWorld();
    try {
      world.emit({
        type: "extension_ui_request",
        id: "dialog-1",
        method: "confirm",
        title: "Allow this command?",
      });

      // A dialog with no timeout of its own has none on the server either: a day later it
      // still holds the session.
      await minutes(24 * 60);
      expect(world.manager.isActive(SESSION_ID)).toBe(true);

      world.manager.respondToUIRequest(SESSION_ID, {
        type: "extension_ui_response",
        id: "dialog-1",
        confirmed: true,
      });
      await minutes(IDLE_MINUTES);
      await untilStopped(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
    } finally {
      await closeWorld(world);
    }
  });

  it("holds an idle session that waits on a background job, and expires it once the wake clears", async () => {
    const { world } = await fakeClockWorld();
    try {
      vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(true);

      await minutes(IDLE_MINUTES * 3);
      expect(world.manager.isActive(SESSION_ID)).toBe(true);

      vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(false);
      await minutes(IDLE_MINUTES);
      await untilStopped(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(status(world)).toBe("stopped");
    } finally {
      await closeWorld(world);
    }
  });
});

describe("auto-stop", () => {
  const autoStop = { launch: { autoStop: true } } satisfies Partial<Session>;

  async function settleOneTurn(world: ClassicWorld): Promise<void> {
    setStreaming(world, true);
    world.emit({ type: "agent_start" });
    world.emit(assistantEnd("Done"));
    world.emit({ type: "agent_end", messages: [] });
    setStreaming(world, false);
    world.emit({ type: "agent_settled" });
    await vi.advanceTimersByTimeAsync(5_000);
  }

  it("stops the session as soon as its turn settles", async () => {
    const { world, ended } = await fakeClockWorld(autoStop);
    try {
      await settleOneTurn(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(status(world)).toBe("stopped");
      expect(ended).toEqual(["stopped"]);
    } finally {
      await closeWorld(world);
    }
  });

  it("keeps a settled session while a background job will wake it, and stops it when the wake's turn settles", async () => {
    const { world, ended } = await fakeClockWorld(autoStop);
    try {
      vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(true);
      await settleOneTurn(world);
      expect(world.manager.isActive(SESSION_ID)).toBe(true);
      expect(status(world)).toBe("ready");

      vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(false);
      await settleOneTurn(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(false);
      expect(ended).toEqual(["stopped"]);
    } finally {
      await closeWorld(world);
    }
  });

  it("keeps a settled session that has a reply dialog open", async () => {
    const { world } = await fakeClockWorld(autoStop);
    try {
      world.emit({
        type: "extension_ui_request",
        id: "dialog-1",
        method: "confirm",
        title: "Keep going?",
      });
      await settleOneTurn(world);

      expect(world.manager.isActive(SESSION_ID)).toBe(true);
      expect(status(world)).toBe("ready");
    } finally {
      await closeWorld(world);
    }
  });
});

// ─── Crash recovery: which rows a restart resumes ───
//
// A crash leaves each row as the dying process last saved it. The statuses below are read from the
// recorded scenarios, at the step where a process would have died, so the matrix follows what the
// lifecycle really saves instead of what a test assumes.

const savedStatus = (id: string, step: string): Session["status"] => {
  const checkpoint = scenario(id).checkpoints.find((candidate) => candidate.step === step);
  if (!checkpoint) throw new Error(`No checkpoint ${step} in ${id}`);
  return checkpoint.row.status as Session["status"];
};

describe("a restart after a crash", () => {
  const dirs: string[] = [];
  afterAll(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  function recoveredStore(rows: Record<string, Partial<Session> & Pick<Session, "status">>) {
    const dir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-crash-"));
    dirs.push(dir);
    const storage = new Storage(dir);
    const workspace = storage.createWorkspace({ name: "project", hostMount: dir });
    for (const [id, fields] of Object.entries(rows)) {
      storage.saveSession({
        id,
        workspaceId: workspace.id,
        createdAt: 1,
        lastActivity: 1,
        messageCount: 1,
        tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        cost: 0,
        // A started session recorded its Pi session file before it could idle.
        piSessionFile: join(dir, `${id}.jsonl`),
        ...fields,
      });
    }
    return storage;
  }

  it("resumes a session that was busy, idle, or starting, and leaves one stopping, as saved", () => {
    const storage = recoveredStore({
      busy: { status: savedStatus("classic.prompt_settle", "agent_start") },
      idle: { status: savedStatus("classic.prompt_settle", "agent_settled") },
      starting: { status: savedStatus("classic.stop_during_start", "start_begun") },
      // S1 DELIBERATELY CHANGES this row: a crash during an abort resumes the session, because the
      // live marker knows the abort was not a terminate. Today a stopping row is never resumed.
      aborting: { status: savedStatus("classic.abort_mid_turn", "abort") },
      // A terminate was on its way out; it stays unresumed after S1 too.
      terminating: { status: savedStatus("classic.terminate_busy", "stop_requested") },
    });

    const queued = queueOrphanedSessionsForRestart(storage);

    expect(queued).toEqual(
      expect.arrayContaining([
        { sessionId: "busy", wasBusy: true },
        { sessionId: "idle", wasBusy: false },
        { sessionId: "starting", wasBusy: false },
      ]),
    );
    expect(queued).toHaveLength(3);
    // Every row the dead process left running is stored stopped afterwards; a run the crash cut
    // short has no outcome.
    for (const id of ["busy", "idle", "starting", "aborting", "terminating"]) {
      expect(storage.getSession(id)?.status, id).toBe("stopped");
    }
    expect(storage.getSession("busy")?.programStatus?.state).toBe("idle");
  });

  it("does not resume a create-only row that never ran, and stores it stopped", () => {
    // S1 DELIBERATELY CHANGES the stored status: a dormant row stays ready, because a client
    // treats a stopped session as history-only and could not open it.
    const storage = recoveredStore({
      shell: { status: "ready", piSessionFile: undefined },
    });

    expect(queueOrphanedSessionsForRestart(storage)).toEqual([]);
    expect(storage.getSession("shell")?.status).toBe("stopped");
  });

  it("leaves stopped and error rows as they are", () => {
    const storage = recoveredStore({
      finished: { status: savedStatus("classic.terminate_idle", "stop") },
      failed: { status: "error" },
    });

    expect(queueOrphanedSessionsForRestart(storage)).toEqual([]);
    expect(storage.getSession("finished")?.status).toBe("stopped");
    expect(storage.getSession("failed")?.status).toBe("error");
  });
});
