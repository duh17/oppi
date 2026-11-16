import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { vi } from "vitest";
import { WebSocket } from "ws";

import { DurableBackend } from "../src/durable-backend.js";
import { AppEventStreamMux } from "../src/app-event-stream.js";
import { runSessionWatch } from "../src/cli/commands/session-watch.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import { SessionRuntimes } from "../src/runtime-router.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { AppEventMessage, ServerMessage, Session, Workspace } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

// What a client sees as a session moves through its lifecycle, recorded from the real server
// code: the focused-stream frames and the app-event frames in arrival order, the server's own
// status at the moment each frame was delivered, and the row, `programStatus`, and CLI `wait`
// answer after every step. `tests/session-lifecycle-contract.test.ts` pins it; the Apple replay
// test reads the same bytes. This module imports vitest only for `vi.fn`/`vi.spyOn`, which work
// outside a test run, so `npm run protocol:fixtures:update` can build it. Written only by that
// script; ordinary tests rebuild it in memory and compare bytes.

export const SESSION_LIFECYCLE_WIRE_FILE = fileURLToPath(
  new URL("../../protocol/session-lifecycle-wire.json", import.meta.url),
);
export const SESSION_LIFECYCLE_WIRE_DESCRIPTION =
  "Session lifecycle frames, statuses, and CLI wait answers per engine — updated by npm run protocol:fixtures:update";

export type LifecycleEngine = "classic" | "durable" | "mirror";

/** One frame a client received, with the server's own state the moment it was delivered. */
export interface RecordedFrame {
  channel: "focused" | "app";
  step: string;
  frame: unknown;
  /** The live session's status and program status when this frame was delivered. */
  server: { status: string; programStatus?: { state: string; kind?: string; message?: string } };
}

export interface LifecycleCheckpoint {
  step: string;
  /** Statuses the row was saved with since the previous checkpoint, in order, repeats collapsed. */
  persisted: string[];
  row: { status: string; programStatus?: { state: string; kind?: string; message?: string } };
  /** Whether a runtime holds the session now. */
  live: boolean;
  /** What `oppi session wait --for idle` answers on one poll right now. */
  cliWait: "idle" | "waiting";
  /** The `pendingWake` the events route adds for a ready session. */
  pendingWake: boolean;
}

export interface LifecycleScenario {
  id: string;
  engine: LifecycleEngine;
  description: string;
  frames: RecordedFrame[];
  checkpoints: LifecycleCheckpoint[];
}

export interface SessionLifecycleWire {
  scenarios: LifecycleScenario[];
}

/** A fixed stand-in for every timestamp: the fixture keeps presence, never the clock. */
export const WIRE_TIME = 1_800_000_000_000;
const TIME_KEY = /(At|Time|Timestamp)$|^(since|time|ts|timestamp|lastActivity)$/;

/**
 * Frames whose count depends on streaming speed, not on the lifecycle. They never carry or
 * change a status, so dropping them keeps the fixture deterministic without hiding a status.
 */
const VOLATILE_FRAME_TYPES = new Set([
  "text_delta",
  "thinking_delta",
  "tool_update",
  "tool_output",
  "context_usage",
]);

function isVolatileFrame(message: { type: string; method?: string }): boolean {
  if (VOLATILE_FRAME_TYPES.has(message.type)) return true;
  // The working-words plugin's rotating label: its text and timing are random. Other
  // notifications stay, since a status line (`setStatus`) or the working indicator is state.
  return message.type === "extension_ui_notification" && message.method === "setWorkingMessage";
}

export type IdAliases = Array<[from: string, to: string]>;

function normalizeValue(value: unknown, aliases: IdAliases, key?: string): unknown {
  if (typeof value === "number") {
    if (key !== undefined && TIME_KEY.test(key)) return WIRE_TIME;
    // Estimates that vary with timing or with the length of the temp path in the system prompt.
    return key === "contextTokens" || key === "cacheWrite" || key === "cacheRead" ? 0 : value;
  }
  if (typeof value === "string") {
    let text = value;
    for (const [from, to] of aliases) text = text.split(from).join(to);
    return text;
  }
  if (Array.isArray(value)) return value.map((item) => normalizeValue(item, aliases));
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [name, inner] of Object.entries(value as Record<string, unknown>)) {
      if (inner === undefined) continue;
      out[name] = normalizeValue(inner, aliases, name);
    }
    return out;
  }
  return value;
}

function programOf(session: Session | undefined): RecordedFrame["server"]["programStatus"] {
  const program = session?.programStatus;
  if (!program) return undefined;
  return {
    state: program.state,
    ...(program.kind !== undefined ? { kind: program.kind } : {}),
    ...(program.message !== undefined ? { message: program.message } : {}),
  };
}

export const flush = async (turns = 8): Promise<void> => {
  for (let turn = 0; turn < turns; turn += 1) await new Promise((resolve) => setImmediate(resolve));
};

class FakeAppSocket extends EventEmitter {
  readyState: number = WebSocket.OPEN;
  sent: AppEventMessage[] = [];
  send(data: string): void {
    this.sent.push(JSON.parse(data) as AppEventMessage);
  }
  ping(): void {}
  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }
  close(code = 1000): void {
    this.readyState = WebSocket.CLOSED;
    this.emit("close", code, Buffer.from(""));
  }
}

export interface WorldOptions {
  id: string;
  engine: LifecycleEngine;
  description: string;
}

/**
 * One scenario's recorder. An engine's setup hands it what it observes: the runtime router, a
 * reader for the live session, and (through `attachFocused` and `connectAppEvents`) the places
 * a client would subscribe.
 */
export class LifecycleRecorder {
  readonly frames: RecordedFrame[] = [];
  readonly checkpoints: LifecycleCheckpoint[] = [];
  readonly aliases: IdAliases = [];
  private currentStep = "setup";
  private persistedSinceCheckpoint: string[] = [];
  private readonly app = new FakeAppSocket();
  private readonly unsubscribe: Array<() => void> = [];

  constructor(
    readonly options: WorldOptions,
    private readonly sessionId: string,
    private readonly storage: Storage,
    private readonly runtimes: SessionRuntimes,
    private readonly liveSession: () => Session | undefined,
  ) {
    const saveSession = storage.saveSession.bind(storage);
    vi.spyOn(storage, "saveSession").mockImplementation((session: Session) => {
      if (session.id === sessionId) {
        const last = this.persistedSinceCheckpoint.at(-1);
        if (last !== session.status) this.persistedSinceCheckpoint.push(session.status);
      }
      return saveSession(session);
    });
  }

  /** Alias a value that differs per run (an id, a temp path) to a stable name. */
  alias(from: string, to: string): void {
    this.aliases.push([from, to]);
    // Longest first, so a path is replaced before an id inside it.
    this.aliases.sort((a, b) => b[0].length - a[0].length);
  }

  /** Feed app events from the emitters, the way `server.ts` connects them. */
  connectAppEvents(emitters: EventEmitter[]): void {
    const mux = new AppEventStreamMux({
      storage: this.storage,
      sessionRuntimes: this.runtimes,
      ensureSessionContextWindow: (session) => session,
      trackConnection: () => {},
      untrackConnection: () => {},
    });
    mux.handleWebSocket(this.app as unknown as WebSocket);
    this.app.sent.length = 0;
    for (const emitter of emitters) {
      emitter.on("session_event", (payload) => mux.handleSessionBroadcastEvent(payload));
    }
    const original = this.app.send.bind(this.app);
    this.app.send = (data: string) => {
      original(data);
      const message = JSON.parse(data) as AppEventMessage;
      if (message.type === "app_events_connected") return;
      this.record("app", message);
    };
  }

  /** Subscribe like a focused session socket: the initial `state`, then every broadcast. */
  attachFocused(
    subscribe: (callback: (message: ServerMessage) => void) => () => void,
    options: { initialState?: boolean } = {},
  ): void {
    const live = this.liveSession();
    if (live && options.initialState !== false) {
      const previous = this.currentStep;
      this.currentStep = "attach";
      this.record("focused", { type: "state", session: live });
      this.currentStep = previous;
    }
    this.unsubscribe.push(subscribe((message) => this.record("focused", message)));
  }

  private record(
    channel: RecordedFrame["channel"],
    message: ServerMessage | AppEventMessage,
  ): void {
    if (isVolatileFrame(message as { type: string; method?: string })) return;
    const live = this.liveSession() ?? this.storage.getSession(this.sessionId) ?? undefined;
    const server: RecordedFrame["server"] = {
      status: live?.status ?? "missing",
      ...(programOf(live) ? { programStatus: programOf(live) } : {}),
    };
    this.frames.push({
      channel,
      step: this.currentStep,
      frame: normalizeValue(JSON.parse(JSON.stringify(message)), this.aliases),
      server: normalizeValue(server, this.aliases) as RecordedFrame["server"],
    });
  }

  /** Wait until no frame has arrived for `quietMs`: real engines deliver their tail late. */
  async untilQuiet(quietMs = 200): Promise<void> {
    let seen = -1;
    while (seen !== this.frames.length) {
      seen = this.frames.length;
      await new Promise((resolve) => setTimeout(resolve, quietMs));
    }
  }

  /** Run one step, let async work settle, and record where the session stands. */
  async step(
    label: string,
    action: () => unknown | Promise<unknown>,
    /** Timer-driven work the step starts (the wake watch): wait until its effect shows, then record. */
    until?: (live: Session | undefined) => boolean,
  ): Promise<void> {
    this.currentStep = label;
    await action();
    await flush();
    const deadline = Date.now() + 5_000;
    while (until && !until(this.liveSession()) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    await flush();
    await this.checkpoint(label);
  }

  private async checkpoint(step: string): Promise<void> {
    const row = this.storage.getSession(this.sessionId);
    const live = this.liveSession();
    const shown = live ?? row ?? undefined;
    const wake = await this.runtimes.awaitsNextTurn(this.sessionId);
    this.checkpoints.push({
      step,
      persisted: this.persistedSinceCheckpoint.splice(0),
      row: {
        status: shown?.status ?? "missing",
        ...(programOf(shown) ? { programStatus: programOf(shown) } : {}),
      },
      live: live !== undefined,
      cliWait: await this.cliWaitAnswer(),
      pendingWake: wake,
    });
  }

  /**
   * The CLI's answer on one poll: the real wait loop over the snapshot the events route builds
   * (`writeSessionEvents`: the live session plus `pendingWake`, or the stored row when no
   * runtime holds it).
   */
  private async cliWaitAnswer(): Promise<"idle" | "waiting"> {
    const call = async <T>(path: string): Promise<T> => {
      if (path.endsWith("/dialogs")) return { dialogs: [] } as T;
      const since = Number(new URL(path, "http://x").searchParams.get("since") ?? "0");
      const pendingWake = await this.runtimes.awaitsNextTurn(this.sessionId);
      const catchUp = this.runtimes.getCatchUp(this.sessionId, since);
      const stored = this.storage.getSession(this.sessionId);
      const body = catchUp
        ? {
            events: catchUp.events,
            currentSeq: catchUp.currentSeq,
            session: { ...catchUp.session, ...(pendingWake ? { pendingWake: true } : {}) },
            catchUpComplete: catchUp.catchUpComplete,
            live: true,
          }
        : { events: [], currentSeq: 0, session: stored, catchUpComplete: false, live: false };
      return body as T;
    };
    const outcome = await runSessionWatch(
      [this.sessionId],
      { condition: "idle", requireAll: false, intervalMs: 1, timeoutMs: 1 },
      call,
      () => {},
    );
    return outcome.kind === "session" ? "idle" : "waiting";
  }

  finish(): LifecycleScenario {
    for (const stop of this.unsubscribe.splice(0)) stop();
    this.app.close();
    return {
      id: this.options.id,
      engine: this.options.engine,
      description: this.options.description,
      frames: this.frames,
      checkpoints: this.checkpoints,
    };
  }
}

// ─── Classic engine: the real SessionManager over a stubbed Pi backend ───

export interface ClassicWorld {
  dir: string;
  storage: Storage;
  workspace: Workspace;
  session: Session;
  manager: SessionManager;
  mirror: PiTuiMirrorRuntime;
  runtimes: SessionRuntimes;
  recorder: LifecycleRecorder;
  backend: ReturnType<typeof makeSdkBackendStub>;
  /** Feed one Pi event into the session exactly as the SDK backend would. */
  emit(event: Record<string, unknown>): void;
  /** With `holdCreate`: finish or fail the backend construction a start waits on. */
  finishCreate(): void;
  failCreate(error: Error): void;
  dispose(): Promise<void>;
}

export const SESSION_ID = "lifecycle-session";
const CLASSIC_MODEL = "anthropic/claude-sonnet-4-0";

export async function classicWorld(
  options: WorldOptions & {
    /** Applied to the stored row before anything starts. */
    row?: Partial<Session>;
    /** The Pi snapshot the start-time seed reads. */
    snapshot?: { isStreaming: boolean };
    /** Leave the backend construction pending until `finishCreate` or `failCreate`. */
    holdCreate?: boolean;
  },
): Promise<ClassicWorld> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-wire-"));
  const storage = new Storage(dir);
  const workspace = storage.createWorkspace({ name: "project", hostMount: dir });
  const created = storage.createSession("lifecycle", CLASSIC_MODEL, { id: SESSION_ID });
  Object.assign(created, { workspaceId: workspace.id, ...options.row });
  storage.saveSession(created);
  const manager = new SessionManager(storage);
  const mirror = new PiTuiMirrorRuntime(storage, { mobileRenderers: new MobileRendererRegistry() });
  const runtimes = new SessionRuntimes(storage, manager, mirror);
  const recorder = new LifecycleRecorder(options, SESSION_ID, storage, runtimes, () =>
    manager.getActiveSession(SESSION_ID),
  );
  recorder.alias(dir, "<data-dir>");
  recorder.alias(workspace.id, "workspace-1");
  recorder.connectAppEvents([manager]);

  const backend = makeSdkBackendStub();
  if (options.snapshot) {
    vi.mocked(backend.sdkBackend.getStateSnapshot).mockReturnValue({
      model: { provider: "anthropic", id: "claude-sonnet-4-0" },
      thinkingLevel: "medium",
      isStreaming: options.snapshot.isStreaming,
    } as never);
  }
  (backend.sdkBackend as unknown as { cacheMissSeed: () => Promise<unknown[]> }).cacheMissSeed =
    async () => [];
  let onEvent: ((event: never) => void) | undefined;
  let finishCreate = (): void => {};
  let failCreate: (error: Error) => void = () => {};
  vi.spyOn(SdkBackend, "create").mockImplementation(async (config) => {
    onEvent = config.onEvent as never;
    if (options.holdCreate) {
      await new Promise<void>((resolve, reject) => {
        finishCreate = resolve;
        failCreate = reject;
      });
    }
    return backend.sdkBackend;
  });

  return {
    dir,
    storage,
    workspace,
    session: created,
    manager,
    mirror,
    runtimes,
    recorder,
    backend,
    emit: (event) => onEvent?.(event as never),
    finishCreate: () => finishCreate(),
    failCreate: (error) => failCreate(error),
    async dispose() {
      vi.restoreAllMocks();
      await manager.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** Pi's streaming flag, as the SDK backend reports it to the lifecycle. */
export function setStreaming(world: ClassicWorld, streaming: boolean): void {
  (world.backend.sdkBackend as { isStreaming: boolean }).isStreaming = streaming;
}

/** Pi's compacting flag: set while a compaction runs, with or without a turn. */
export function setCompacting(world: ClassicWorld, compacting: boolean): void {
  (world.backend.sdkBackend as unknown as { isCompacting: boolean }).isCompacting = compacting;
}

export const assistantEnd = (text: string, stopReason = "stop", errorMessage?: string) => ({
  type: "message_end",
  message: {
    role: "assistant",
    content: [{ type: "text", text }],
    stopReason,
    ...(errorMessage ? { errorMessage } : {}),
    usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 15 },
  },
});

// ─── Classic scenarios ───

async function startAndAttach(world: ClassicWorld): Promise<void> {
  await world.recorder.step("start", () => world.manager.startSession(SESSION_ID, world.workspace));
  world.recorder.attachFocused((callback) => world.manager.subscribe(SESSION_ID, callback));
}

async function beginRun(world: ClassicWorld, label = "agent_start"): Promise<void> {
  await world.recorder.step(label, () => {
    setStreaming(world, true);
    world.emit({ type: "agent_start" });
  });
}

async function settleRun(
  world: ClassicWorld,
  text = "Done",
  prefix = "",
  /** The settle starts the wake watch: the step records after its first read has landed. */
  heldForWake = false,
): Promise<void> {
  const { recorder } = world;
  await recorder.step(`${prefix}message_end`, () => world.emit(assistantEnd(text)));
  await recorder.step(`${prefix}agent_end`, () => world.emit({ type: "agent_end", messages: [] }));
  await recorder.step(
    `${prefix}agent_settled`,
    () => {
      setStreaming(world, false);
      world.emit({ type: "agent_settled" });
    },
    heldForWake ? (live) => programOf(live)?.state === "working" : undefined,
  );
}

async function runClassic(
  options: Parameters<typeof classicWorld>[0],
  script: (world: ClassicWorld) => Promise<void>,
): Promise<LifecycleScenario> {
  const world = await classicWorld(options);
  try {
    await script(world);
    return world.recorder.finish();
  } finally {
    await world.dispose();
  }
}

export const CLASSIC_SCENARIOS: Array<() => Promise<LifecycleScenario>> = [
  () =>
    runClassic(
      {
        id: "classic.prompt_settle",
        engine: "classic",
        description: "A prompt runs one turn and settles back to ready.",
      },
      async (world) => {
        await startAndAttach(world);
        await world.recorder.step("prompt", () => world.manager.sendPrompt(SESSION_ID, "hello"));
        await beginRun(world);
        await settleRun(world);
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.retry_gap_trace_read",
        engine: "classic",
        description:
          "A failed response, then a trace read in the gap before the auto-retry: the row stays busy and the retry's success decides the outcome.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        await world.recorder.step("error_response", () =>
          world.emit(assistantEnd("", "error", "429 overloaded")),
        );
        await world.recorder.step("agent_end", () => {
          setStreaming(world, false);
          world.emit({ type: "agent_end", messages: [] });
        });
        // Pi reports idle between agent_end and the retry; a trace read applies that snapshot.
        await world.recorder.step("trace_read_in_gap", () =>
          world.manager.refreshSessionState(SESSION_ID),
        );
        await beginRun(world, "retry_agent_start");
        await settleRun(world, "Recovered", "retry_");
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.run_error",
        engine: "classic",
        description: "A run whose last response failed settles ready with an error program status.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        await world.recorder.step("error_response", () =>
          world.emit(assistantEnd("", "error", "401 invalid credentials\nsecond line")),
        );
        await world.recorder.step("agent_end", () =>
          world.emit({ type: "agent_end", messages: [] }),
        );
        await world.recorder.step("agent_settled", () => {
          setStreaming(world, false);
          world.emit({ type: "agent_settled" });
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.dialog_blocked",
        engine: "classic",
        description:
          "A permission dialog mid-turn: the row stays busy on the wire while program status is blocked; answering it returns to working.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        await world.recorder.step("dialog_opened", () =>
          world.emit({
            type: "extension_ui_request",
            id: "dialog-1",
            method: "confirm",
            title: "Allow this command?\nrm -rf build",
          }),
        );
        await world.recorder.step("dialog_answered", () =>
          world.manager.respondToUIRequest(SESSION_ID, {
            type: "extension_ui_response",
            id: "dialog-1",
            confirmed: true,
          }),
        );
        await settleRun(world);
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.abort_mid_turn",
        engine: "classic",
        description:
          "Abort during a turn: stopping on the wire, stop_confirmed at agent_end while the row is still stopping, ready only at agent_settled.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        await world.recorder.step("abort", () => world.manager.sendAbort(SESSION_ID));
        await world.recorder.step("agent_end", () =>
          world.emit({ type: "agent_end", messages: [] }),
        );
        await world.recorder.step("agent_settled", () => {
          setStreaming(world, false);
          world.emit({ type: "agent_settled" });
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.abort_quiet_tool",
        engine: "classic",
        description:
          "Abort while a tool is quiet and the backend's abort has not returned: the request stays pending, stopping, until the turn ends.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        await world.recorder.step("tool_start", () =>
          world.emit({
            type: "tool_execution_start",
            toolName: "bash",
            toolCallId: "tc-1",
            args: {},
          }),
        );
        let finishAbort!: () => void;
        vi.mocked(world.backend.abort).mockImplementationOnce(
          () => new Promise<void>((resolve) => (finishAbort = resolve)),
        );
        let abort!: Promise<void>;
        await world.recorder.step("abort_pending", () => {
          abort = world.manager.sendAbort(SESSION_ID);
        });
        await world.recorder.step("tool_end", () =>
          world.emit({
            type: "tool_execution_end",
            toolName: "bash",
            toolCallId: "tc-1",
            result: { content: [{ type: "text", text: "interrupted" }] },
            isError: true,
          }),
        );
        await world.recorder.step("agent_end", () =>
          world.emit({ type: "agent_end", messages: [] }),
        );
        await world.recorder.step("agent_settled", async () => {
          setStreaming(world, false);
          world.emit({ type: "agent_settled" });
          finishAbort();
          await abort;
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.abort_rejected",
        engine: "classic",
        description: "The backend rejects an abort: stop_failed, and the row goes back to busy.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        vi.mocked(world.backend.abort).mockRejectedValueOnce(new Error("abort rejected"));
        await world.recorder.step("abort", () =>
          world.manager.sendAbort(SESSION_ID).catch(() => undefined),
        );
        await settleRun(world);
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.abort_idle",
        engine: "classic",
        description: "Abort on an idle session answers stop_confirmed at once and changes nothing.",
      },
      async (world) => {
        await startAndAttach(world);
        await world.recorder.step("abort", () => world.manager.sendAbort(SESSION_ID));
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.terminate_busy",
        engine: "classic",
        description:
          "Stop during a turn: stopping, then stop_confirmed and session_ended with the row stopped.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        let stop!: Promise<void>;
        await world.recorder.step("stop_requested", () => {
          stop = world.manager.stopSession(SESSION_ID);
        });
        // The terminate waits for the run to end, then tears the runtime down.
        await world.recorder.step("agent_end", async () => {
          setStreaming(world, false);
          world.emit({ type: "agent_end", messages: [] });
          await stop;
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.terminate_idle",
        engine: "classic",
        description: "Stop on an idle session ends it: stopping, stop_confirmed, session_ended.",
      },
      async (world) => {
        await startAndAttach(world);
        await world.recorder.step("stop", () => world.manager.stopSession(SESSION_ID));
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.stop_during_start",
        engine: "classic",
        description:
          "Stop while the session is still starting wins before the start registers a runtime: nothing goes live and the row ends stopped, with no ready row along the way and no stop frames of a live session.",
        row: { status: "stopped" },
        holdCreate: true,
      },
      async (world) => {
        let start!: Promise<unknown>;
        await world.recorder.step("start_begun", () => {
          start = world.manager.startSession(SESSION_ID, world.workspace).catch(() => undefined);
        });
        let stop!: Promise<void>;
        await world.recorder.step("stop_requested_during_start", () => {
          stop = world.manager.stopSession(SESSION_ID);
        });
        await world.recorder.step("create_finished", async () => {
          world.finishCreate();
          await Promise.all([start, stop]);
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.start_fails",
        engine: "classic",
        description:
          "The backend fails to build: the start throws and the row ends stopped, never ready.",
        row: { status: "stopped" },
        holdCreate: true,
      },
      async (world) => {
        let start!: Promise<unknown>;
        await world.recorder.step("start_begun", () => {
          start = world.manager.startSession(SESSION_ID, world.workspace).catch(() => undefined);
        });
        await world.recorder.step("create_failed", async () => {
          world.failCreate(new Error("create failed"));
          await start;
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.start_streaming_snapshot",
        engine: "classic",
        description:
          "A start whose Pi runtime is already streaming seeds the row busy from the snapshot.",
        snapshot: { isStreaming: true },
      },
      async (world) => {
        await startAndAttach(world);
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.compaction_queued",
        engine: "classic",
        description:
          "A compact asked for mid-turn waits for the turn to settle, then runs: the row stays ready while program status says it is compacting.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        let finishCompact!: () => void;
        vi.mocked(world.backend.sdkBackend.compact).mockImplementationOnce(
          () =>
            new Promise((resolve) => {
              setCompacting(world, true);
              world.emit({ type: "compaction_start", reason: "manual" });
              finishCompact = () => resolve({} as never);
            }),
        );
        await world.recorder.step("compact_requested", () =>
          world.manager.forwardClientCommand(SESSION_ID, { type: "compact" }, "compact-1"),
        );
        // The queued compact runs once the turn settles.
        await settleRun(world);
        await world.recorder.step("compaction_end", () => {
          setCompacting(world, false);
          world.emit({
            type: "compaction_end",
            aborted: false,
            willRetry: false,
            summary: "Earlier work, summarised",
            tokensBefore: 1_000,
          });
          finishCompact();
        });
      },
    ),
  () =>
    runClassic(
      {
        id: "classic.wake_hold",
        engine: "classic",
        description:
          "A settled session with a background job still pending: ready on the wire and working in program status (after the settle's own Done summary), while the CLI wait says it is not idle. The wake's turn then settles it.",
      },
      async (world) => {
        await startAndAttach(world);
        await beginRun(world);
        vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(true);
        await settleRun(world, "Done", "", true);
        vi.mocked(world.backend.sdkBackend.hasPendingWake).mockResolvedValue(false);
        await beginRun(world, "wake_agent_start");
        await settleRun(world, "Report", "wake_");
      },
    ),
];

// ─── Mirror engine: a terminal Pi's bridge, driven over a fake socket ───

class FakeBridgeSocket extends EventEmitter {
  readyState: number = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];
  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }
  close(): void {
    this.readyState = WebSocket.CLOSED;
  }
  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
  latestCommand(): Record<string, unknown> {
    const command = [...this.sent].reverse().find((message) => message.type === "command");
    if (!command) throw new Error("the bridge was sent no command");
    return command;
  }
}

interface MirrorWorld {
  recorder: LifecycleRecorder;
  mirror: PiTuiMirrorRuntime;
  bridge: FakeBridgeSocket;
  dir: string;
  workspaceId: string;
}

async function until(condition: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    if (condition()) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error(`Timed out waiting for ${what}`);
}

async function runMirror(
  options: WorldOptions,
  script: (world: MirrorWorld) => Promise<void>,
): Promise<LifecycleScenario> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-wire-mirror-"));
  const storage = new Storage(dir);
  const workspace = storage.createWorkspace({ name: "project", hostMount: dir });
  const mirror = new PiTuiMirrorRuntime(storage, { mobileRenderers: new MobileRendererRegistry() });
  const manager = new SessionManager(storage);
  const runtimes = new SessionRuntimes(storage, manager, mirror);
  const recorder = new LifecycleRecorder(options, SESSION_ID, storage, runtimes, () =>
    mirror.getActiveSession(SESSION_ID),
  );
  recorder.alias(dir, "<data-dir>");
  recorder.alias(workspace.id, "workspace-1");
  recorder.connectAppEvents([mirror]);
  const bridge = new FakeBridgeSocket();
  try {
    await script({ recorder, mirror, bridge, dir, workspaceId: workspace.id });
    return recorder.finish();
  } finally {
    bridge.close();
    vi.restoreAllMocks();
    await manager.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

async function connectMirror(world: MirrorWorld): Promise<void> {
  await world.recorder.step("hello", async () => {
    world.mirror.handleBridgeWebSocket(world.bridge as unknown as WebSocket);
    world.bridge.receive({
      type: "hello",
      protocolVersion: 2,
      bridgeId: "bridge-1",
      workspaceId: world.workspaceId,
      cwd: world.dir,
      capabilities: ["input_preflight:v1"],
      state: {
        piSessionId: SESSION_ID,
        sessionFile: join(world.dir, "session.jsonl"),
        sessionName: "terminal session",
        isIdle: true,
      },
    });
    await until(
      () => world.bridge.sent.some((message) => message.type === "hello_ack"),
      "the bridge's hello_ack",
    );
  });
  world.recorder.attachFocused((callback) => world.mirror.subscribe(SESSION_ID, callback));
}

const bridgeEvent = (event: Record<string, unknown>, isIdle: boolean) => ({
  type: "event",
  event,
  state: { isIdle },
});

async function mirrorRun(world: MirrorWorld): Promise<void> {
  const { recorder, bridge } = world;
  await recorder.step("agent_start", () =>
    bridge.receive(bridgeEvent({ type: "agent_start" }, false)),
  );
  await recorder.step("message_end", () =>
    bridge.receive(bridgeEvent(assistantEnd("Done"), false)),
  );
  await recorder.step("agent_end", () =>
    bridge.receive(bridgeEvent({ type: "agent_end", messages: [] }, false)),
  );
  await recorder.step("agent_settled", () =>
    bridge.receive(bridgeEvent({ type: "agent_settled" }, true)),
  );
}

export const MIRROR_SCENARIOS: Array<() => Promise<LifecycleScenario>> = [
  () =>
    runMirror(
      {
        id: "mirror.busy_idle_stop",
        engine: "mirror",
        description:
          "A terminal session: busy from the bridge's state, a run's events, idle again, then stopped through the shared stop states from the terminal side.",
      },
      async (world) => {
        await connectMirror(world);
        await world.recorder.step("state_busy", () =>
          world.bridge.receive({ type: "state", state: { isIdle: false } }),
        );
        await mirrorRun(world);
        await world.recorder.step("state_idle", () =>
          world.bridge.receive({ type: "state", state: { isIdle: true } }),
        );
        let stop!: Promise<void>;
        await world.recorder.step("stop_requested", () => {
          stop = world.mirror.stopSession(SESSION_ID);
        });
        await world.recorder.step("goodbye", async () => {
          world.bridge.receive({ type: "goodbye", reason: "stopped", state: { isIdle: true } });
          world.bridge.emit("close");
          await stop;
        });
      },
    ),
  () =>
    runMirror(
      {
        id: "mirror.abort_mid_turn",
        engine: "mirror",
        description:
          "Abort a terminal run through the shared stop states: stop_requested and stopping go out immediately, and the bridge's idle confirms it.",
      },
      async (world) => {
        await connectMirror(world);
        await world.recorder.step("agent_start", () =>
          world.bridge.receive(bridgeEvent({ type: "agent_start" }, false)),
        );
        let abort!: Promise<void>;
        await world.recorder.step("abort_sent", () => {
          abort = world.mirror.sendAbort(SESSION_ID);
        });
        await world.recorder.step("abort_result", async () => {
          world.bridge.receive({
            type: "command_result",
            id: world.bridge.latestCommand().id,
            success: true,
            data: { aborted: true },
          });
          await abort;
        });
        await world.recorder.step("agent_end", () =>
          world.bridge.receive(bridgeEvent({ type: "agent_end", messages: [] }, false)),
        );
        await world.recorder.step("agent_settled", () =>
          world.bridge.receive(bridgeEvent({ type: "agent_settled", aborted: true }, true)),
        );
      },
    ),
];

// ─── Durable engine: the real SessionManager over a real Harness and the faux provider ───

interface DurableWorld {
  recorder: LifecycleRecorder;
  manager: SessionManager;
  storage: Storage;
  workspace: Workspace;
  faux: ReturnType<typeof fauxProvider>;
}

async function runDurable(
  options: WorldOptions,
  responses: FauxResponseStep[],
  script: (world: DurableWorld) => Promise<void>,
): Promise<LifecycleScenario> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-wire-durable-"));
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-wire-agent-"));
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  // Durable sessions discover Skills and AGENTS files under the agent dir: never the developer's.
  process.env.PI_CODING_AGENT_DIR = agentDir;
  let manager: SessionManager | undefined;
  try {
    const models = await ModelRuntime.create({
      authPath: join(dir, "auth.json"),
      modelsPath: null,
      modelsStorePath: join(dir, "models-cache.json"),
      refreshOnCreate: false,
    });
    const faux = fauxProvider();
    faux.setResponses(responses);
    models.registerNativeProvider(faux.provider);
    await models.setRuntimeApiKey("faux", "test-only-faux-credential");
    await models.refresh({ allowNetwork: false });
    vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
    vi.spyOn(SettingsManager, "create").mockImplementation(() =>
      SettingsManager.inMemory({
        defaultProvider: "faux",
        defaultModel: "faux-1",
        defaultThinkingLevel: "off",
        compaction: { enabled: false },
      }),
    );
    const storage = new Storage(dir);
    storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
    const workspace = storage.createWorkspace({ name: "project", hostMount: dir });
    const row = storage.createSession("lifecycle", "faux/faux-1", { id: SESSION_ID });
    row.serverDurable = { storeId: row.id };
    row.workspaceId = workspace.id;
    storage.saveSession(row);
    manager = new SessionManager(storage);
    const mirror = new PiTuiMirrorRuntime(storage, {
      mobileRenderers: new MobileRendererRegistry(),
    });
    const runtimes = new SessionRuntimes(storage, manager, mirror);
    const recorder = new LifecycleRecorder(options, SESSION_ID, storage, runtimes, () =>
      manager?.getActiveSession(SESSION_ID),
    );
    recorder.alias(dir, "<data-dir>");
    recorder.alias(workspace.id, "workspace-1");
    recorder.connectAppEvents([manager]);
    await manager.resumeDurableSessions();
    await script({ recorder, manager, storage, workspace, faux });
    return recorder.finish();
  } finally {
    vi.restoreAllMocks();
    await manager?.close();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(agentDir, { recursive: true, force: true });
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Wait until a frame matching `predicate` has arrived since the step began. */
async function untilFrame(
  recorder: LifecycleRecorder,
  what: string,
  predicate: (frame: { type: string; [key: string]: unknown }, channel: string) => boolean,
): Promise<void> {
  const from = recorder.frames.length;
  await until(
    () =>
      recorder.frames
        .slice(from)
        .some((entry) => predicate(entry.frame as { type: string }, entry.channel)),
    what,
  );
}

type HandlePiEvent = (key: string, event: { type: string }) => void;

const focusedType = (type: string) => (frame: { type: string }, channel: string) =>
  channel === "focused" && frame.type === type;

/** The frame a client sees once a settled run's row is ready again. */
const readySummary = (frame: { type: string; summary?: unknown }, channel: string): boolean =>
  channel === "focused" &&
  frame.type === "session_summary" &&
  (frame.summary as { status?: string }).status === "ready";

const LONG_ANSWER = Array.from({ length: 80 }, (_, index) => `word${index}`).join(" ");

/**
 * A model that answers only once aborted, so the turn stays running until a step stops it and
 * records no partial answer whose length depends on timing: the stream sees the abort before
 * its first token.
 */
const ANSWER_ONCE_ABORTED: FauxResponseStep = (_context, options) =>
  new Promise((resolve) => {
    const answer = () => resolve(fauxAssistantMessage(LONG_ANSWER));
    if (!options?.signal) throw new Error("the faux model needs an abort signal");
    if (options.signal.aborted) answer();
    else options.signal.addEventListener("abort", answer, { once: true });
  });

async function startDurable(world: DurableWorld): Promise<void> {
  const { recorder, manager, workspace } = world;
  await recorder.step("start", () => manager.startSession(SESSION_ID, workspace));
  recorder.attachFocused((callback) => manager.subscribe(SESSION_ID, callback));
}

/** Submit a prompt and wait for the turn to be running. */
async function startDurableRun(world: DurableWorld, prompt: string): Promise<void> {
  const { recorder, manager } = world;
  await recorder.step("prompt", async () => {
    const started = untilFrame(recorder, "agent_start", focusedType("agent_start"));
    await manager.sendPrompt(SESSION_ID, prompt);
    await started;
    await recorder.untilQuiet();
  });
}

export const DURABLE_SCENARIOS: Array<() => Promise<LifecycleScenario>> = [
  () =>
    runDurable(
      {
        id: "durable.prompt_settle",
        engine: "durable",
        description: "A durable prompt runs one turn and settles back to ready.",
      },
      [fauxAssistantMessage("Hello from the durable engine")],
      async (world) => {
        const { recorder, manager } = world;
        await startDurable(world);
        await recorder.step("prompt", async () => {
          const settled = untilFrame(recorder, "settled and ready", readySummary);
          await manager.sendPrompt(SESSION_ID, "hello");
          await settled;
          await recorder.untilQuiet();
        });
      },
    ),
  () =>
    runDurable(
      {
        id: "durable.abort_mid_turn",
        engine: "durable",
        description:
          "Abort a running durable turn: stopping, stop_confirmed at agent_end, ready at agent_settled.",
      },
      [ANSWER_ONCE_ABORTED],
      async (world) => {
        const { recorder, manager } = world;
        await startDurable(world);
        await startDurableRun(world, "write a long answer");
        await recorder.step("abort", async () => {
          const settled = untilFrame(recorder, "settled and ready", readySummary);
          await manager.sendAbort(SESSION_ID);
          await settled;
          await recorder.untilQuiet();
        });
      },
    ),
  () =>
    runDurable(
      {
        id: "durable.terminate_busy",
        engine: "durable",
        description:
          "Stop a durable session mid-turn: stopping, then stop_confirmed and session_ended with the row stopped.",
      },
      [ANSWER_ONCE_ABORTED],
      async (world) => {
        const { recorder, manager } = world;
        await startDurable(world);
        await startDurableRun(world, "write a long answer");
        await recorder.step("stop", async () => {
          const ended = untilFrame(recorder, "session_ended", focusedType("session_ended"));
          await manager.stopSession(SESSION_ID);
          await ended;
          await recorder.untilQuiet();
        });
      },
    ),
  () =>
    runDurable(
      {
        id: "durable.commit_before_agent_start",
        engine: "durable",
        description:
          "A prompt the store committed whose agent_start the session has not seen yet: the row is still ready while the backend runs. The CLI wait is not idle, and an abort stops the run.",
      },
      [ANSWER_ONCE_ABORTED],
      async (world) => {
        const { recorder, manager } = world;
        await startDurable(world);
        // Hold every event from agent_start on, as a store that commits before the session
        // hears of the run: the backend is running, the lifecycle has not heard of it.
        const held: Array<[string, unknown]> = [];
        let holding = true;
        const handle = (SessionManager.prototype as unknown as { handlePiEvent: HandlePiEvent })
          .handlePiEvent;
        vi.spyOn(
          SessionManager.prototype as unknown as { handlePiEvent: HandlePiEvent },
          "handlePiEvent",
        ).mockImplementation(function (this: SessionManager, key, event) {
          if (holding && (held.length > 0 || event.type === "agent_start")) {
            held.push([key, event]);
            return;
          }
          return handle.call(this, key, event);
        });
        await recorder.step("committed", async () => {
          await manager.sendPrompt(SESSION_ID, "hello");
          await until(() => held.length > 0, "the held agent_start");
          await recorder.untilQuiet();
        });
        await recorder.step("abort_in_gap", () => manager.sendAbort(SESSION_ID));
        await recorder.step("released", async () => {
          const settled = untilFrame(recorder, "settled and ready", readySummary);
          holding = false;
          for (const [key, event] of held.splice(0)) {
            handle.call(manager, key, event as { type: string });
          }
          await settled;
          await recorder.untilQuiet();
        });
      },
    ),
  () =>
    runDurable(
      {
        id: "durable.start_fails_after_registration",
        engine: "durable",
        description:
          "The start fails after the runtime registered: the session is ended and the row stored stopped, not ready.",
      },
      [],
      async (world) => {
        const { recorder, manager, workspace } = world;
        vi.spyOn(DurableBackend.prototype, "startEvents").mockRejectedValueOnce(
          new Error("startEvents failed"),
        );
        await recorder.step("start", () =>
          manager.startSession(SESSION_ID, workspace).catch(() => undefined),
        );
      },
    ),
];

// ─── The fixture ───

export const ALL_SCENARIOS = [...CLASSIC_SCENARIOS, ...MIRROR_SCENARIOS, ...DURABLE_SCENARIOS];

/** Runs one scenario at a time: they share process-wide spies. */
export async function buildSessionLifecycleWire(): Promise<SessionLifecycleWire> {
  const scenarios: LifecycleScenario[] = [];
  for (const run of ALL_SCENARIOS) scenarios.push(await run());
  return { scenarios };
}

/**
 * One line per frame and per checkpoint: a scenario's order reads top to bottom, and a change
 * to one frame is a one-line diff.
 */
export function serializeSessionLifecycleWire(wire: SessionLifecycleWire): string {
  const lines = (items: unknown[], indent: string): string =>
    items.map((item) => `${indent}${JSON.stringify(item)}`).join(",\n");
  const scenarios = wire.scenarios.map((scenario) => {
    const { frames, checkpoints, ...head } = scenario;
    return [
      "    {",
      `      ${JSON.stringify(head).slice(1, -1)},`,
      `      "frames": [\n${lines(frames, "        ")}\n      ],`,
      `      "checkpoints": [\n${lines(checkpoints, "        ")}\n      ]`,
      "    }",
    ].join("\n");
  });
  const meta = {
    description: SESSION_LIFECYCLE_WIRE_DESCRIPTION,
    scenarioCount: wire.scenarios.length,
  };
  return `{\n  "_meta": ${JSON.stringify(meta)},\n  "scenarios": [\n${scenarios.join(",\n")}\n  ]\n}\n`;
}
