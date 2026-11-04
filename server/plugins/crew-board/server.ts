import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import {
  Extensions,
  actionBar,
  checklist,
  dataTable,
  defineExtension,
  defineFacet,
  defineTool,
  oppiHost,
  surface,
  type ChecklistFields,
  type DurableChildSession,
  type DurableSessionsHost,
  type Extension,
  type Surface,
  type SurfaceCompositeFields,
  type SurfacePublisher,
  type SurfaceView,
} from "oppi/v1";
import type { ExecutionEnv } from "@earendil-works/pi-durable/env";
import { obj } from "oppi/v1/schema";

/**
 * `crew_board`: a live panel of the sessions this one launched, beside the land queue their work
 * goes into. The board reads and never writes: the queue belongs to the integrator's own script,
 * and the only thing the panel changes is a worker's current work, stopped the way `subagent
 * stop` stops it.
 *
 * Everything it shows comes from the host (`oppiHost().sessions(env).children()`): Session rows
 * read back from the store's conversations. Which rows it may *stop* is narrower: the host refuses
 * a Session the Harness does not record as this conversation's own child, so a listed row that is
 * not owned answers with the host's words on the card rather than stopping anything. The land
 * queue is a file the agent-workflow skill's script owns, read here as data.
 */

const SURFACE_ID = "crew-board";
/** How often a live board re-reads. */
export const REFRESH_INTERVAL_MS = 25_000;
/** How many re-reads one board may do before it stops on its own (about 50 minutes). */
export const REFRESH_LIMIT = 120;
/** Failed reads in a row before the board widens its interval: a broken read is retried, not hammered. */
export const FAILURE_BACKOFF_AFTER = 3;
/** How much wider the interval gets once reads keep failing. */
export const FAILURE_BACKOFF_FACTOR = 4;
/** A queue file larger than this is not read: the counts are not worth an unbounded read. */
export const MAX_QUEUE_BYTES = 1024 * 1024;
/** Worker lines a fallback shows before it counts the rest. */
export const FALLBACK_WORKER_LINES = 8;
/** Every fallback stays well under the wire's 2,000-character field cap. */
export const FALLBACK_MAX_CHARS = 1_900;
/** One fallback line, however long a worker's name and newest reply are. */
const FALLBACK_LINE_CHARS = 160;
/** A table cell's words; the wire takes 200 characters a cell. */
const CELL_MAX_CHARS = 140;
/** A failure's words in a state message or a fallback; the wire takes 200 there. */
const MESSAGE_MAX_CHARS = 180;
/** Where the land-queue script keeps its queue, under the repository's common git directory. */
const QUEUE_FILE = ["oppi", "land-queue", "queue.jsonl"] as const;

/** What the board needs of a session's workers: `oppiHost().sessions(env)` and its stop. */
export type CrewSessions = Pick<DurableSessionsHost, "storeId" | "children" | "stop">;

/** What the board needs of Oppi. The package's entry binds it to `oppiHost()`; tests bind their own. */
export interface CrewBoardHost {
  sessions(env: ExecutionEnv | undefined): CrewSessions | undefined;
  surfaces(env: ExecutionEnv | undefined): SurfacePublisher | undefined;
}

/** A worker as the board shows it: the Session's own row, with the status narrowed to four. */
interface Worker {
  sessionId: string;
  name?: string;
  status: "busy" | "ready" | "stopped" | "error";
  worktree?: string;
  lastActivity: number;
  latest?: string;
}

/** The land queue as the panel reads it: counts, or why it has none. */
export type LandQueue =
  | { kind: "counts"; counts: LandQueueCounts }
  | { kind: "none" }
  | { kind: "unreadable"; message: string };

export interface LandQueueCounts {
  ready: number;
  blocked: number;
  conflict: number;
  failed: number;
  invalid: number;
}

/** One board's state: what the panel renders, and what a Stop republishes. */
export interface BoardState {
  /** Undefined when the caller's children could not be read, with the reason. */
  workers?: Worker[];
  workersError?: string;
  queue: LandQueue;
  /** When this state was read, for the relative "last activity" cells. */
  readAt: number;
  /**
   * Whether the board is still re-reading this state. The last state it publishes before it stops
   * says so in the subtitle, so a stale board never passes for a live one.
   */
  refreshing: boolean;
}

/**
 * One conversation's board: its panel, the surface loop it publishes into, and the interval that
 * re-reads while it lives. The plugin module is shared by every session in the server, so a panel
 * is per conversation, never per module.
 */
interface Board {
  panel: Surface<BoardState>;
  env: ExecutionEnv | undefined;
  cwd: string | undefined;
  /** Re-reads done since the budget was reset; `start` resets it. */
  ticks: number;
  /** Reads that failed in a row, which widen the interval. */
  failures: number;
  /** The interval the running timer was scheduled with. */
  interval: number;
  timer?: ReturnType<typeof setInterval>;
  /** One read at a time: a slow read must not stack ticks behind it. */
  reading: boolean;
}

/**
 * The four states a row shows; a Session on its way up reads as busy, a failed one as error rather
 * than as cleanly stopped, and anything else on its way out as stopped.
 */
function workerStatus(status: DurableChildSession["status"]): Worker["status"] {
  if (status === "starting" || status === "busy") return "busy";
  if (status === "ready") return "ready";
  if (status === "error") return "error";
  return "stopped";
}

/** Only a worker with work of its own offers Stop. */
function canStop(status: Worker["status"]): boolean {
  return status === "busy" || status === "ready";
}

/** `text` cut to `chars` characters, the ellipsis counting toward it, as the wire counts them. */
function clamp(text: string, chars: number): string {
  const characters = Array.from(text);
  if (characters.length <= chars) return text;
  return `${characters.slice(0, chars - 1).join("")}…`;
}

function shortId(sessionId: string): string {
  return sessionId.replace(/-/g, "").slice(0, 8);
}

/** Epoch-relative words for a row, as the app writes them. */
function ago(elapsed: number): string {
  if (elapsed < 60_000) return "just now";
  const minutes = Math.floor(elapsed / 60_000);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function plural(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? "" : "s"}`;
}

// --- the land queue ---------------------------------------------------------------------------

/**
 * The repository's common git directory for a checkout: `.git` itself, or for a worktree the
 * directory its `.git` file points at, followed to the main repository's via `commondir`. Every
 * worktree of a repository therefore reads the one queue.
 */
export function gitCommonDir(cwd: string): string | undefined {
  let dir = resolve(cwd);
  for (;;) {
    const dotGit = join(dir, ".git");
    if (existsSync(dotGit)) {
      try {
        // The main checkout's own directory, or a worktree's `.git` file naming its git dir.
        if (statSync(dotGit).isDirectory()) return dotGit;
        const text = readFileSync(dotGit, "utf8");
        if (!text.startsWith("gitdir:")) return undefined;
        const gitDir = resolve(dir, text.slice("gitdir:".length).trim());
        const common = join(gitDir, "commondir");
        if (!existsSync(common)) return gitDir;
        const relative = readFileSync(common, "utf8").trim();
        return isAbsolute(relative) ? relative : resolve(gitDir, relative);
      } catch {
        // An unreadable `.git` is not a repository this board can name a queue in.
        return undefined;
      }
    }
    const parent = dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

type QueueEntry = { branch: string; after: string[]; status: string };

function queueEntries(text: string): QueueEntry[] {
  const entries: QueueEntry[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof value !== "object" || value === null) continue;
    const record = value as { branch?: unknown; after?: unknown; status?: unknown };
    if (typeof record.branch !== "string" || typeof record.status !== "string") continue;
    entries.push({
      branch: record.branch,
      status: record.status,
      after: Array.isArray(record.after)
        ? record.after.filter((one): one is string => typeof one === "string")
        : [],
    });
  }
  return entries;
}

/**
 * The queue's counts, read from the file the integrator's script owns, oldest first. A queued
 * entry is blocked while a branch it waits for is still in the queue under any status: `conflict`,
 * `failed`, and `invalid` hold their dependents back exactly as `queued` does, which is the
 * integrator's own readiness rule. A dependency the file no longer names has landed or been
 * removed — the one thing a read without git cannot tell apart from a branch that never existed —
 * so an entry whose dependency is gone counts as ready here. Conflict, failed, and invalid entries
 * are counted by the status the file records. A file too large to read is reported, not parsed.
 */
export function readLandQueue(cwd: string | undefined): LandQueue {
  if (!cwd) return { kind: "none" };
  const common = gitCommonDir(cwd);
  if (!common) return { kind: "none" };
  const file = join(common, ...QUEUE_FILE);
  if (!existsSync(file)) return { kind: "none" };
  let text: string;
  try {
    const { size } = statSync(file);
    if (size > MAX_QUEUE_BYTES)
      return {
        kind: "unreadable",
        message: `the queue file is ${Math.ceil(size / 1024)} KiB, more than this board reads`,
      };
    text = readFileSync(file, "utf8");
  } catch (error) {
    return { kind: "unreadable", message: clamp(messageOf(error), MESSAGE_MAX_CHARS) };
  }
  const entries = queueEntries(text);
  const present = new Set(entries.map((entry) => entry.branch));
  const counts: LandQueueCounts = { ready: 0, blocked: 0, conflict: 0, failed: 0, invalid: 0 };
  for (const entry of entries) {
    if (entry.status === "conflict") counts.conflict += 1;
    else if (entry.status === "failed") counts.failed += 1;
    else if (entry.status === "invalid") counts.invalid += 1;
    else if (entry.status === "queued")
      counts[
        entry.after.some((branch) => branch !== entry.branch && present.has(branch))
          ? "blocked"
          : "ready"
      ] += 1;
    // An entry with any other status is the script's business, not the board's.
  }
  return { kind: "counts", counts };
}

// --- the view ---------------------------------------------------------------------------------

const COLUMNS = [
  { id: "name", title: "Name" },
  { id: "status", title: "Status" },
  { id: "worktree", title: "Worktree" },
  { id: "activity", title: "Last activity" },
  { id: "latest", title: "Latest" },
] as const;

/** One worker's row: its Session id, the cells its columns name, and the action it offers. */
interface WorkerRow {
  id: string;
  cells: Record<string, string>;
  actions?: string[];
}

function rowsOf(state: BoardState): WorkerRow[] {
  return (state.workers ?? []).map((worker) => workerRow(worker, state.readAt));
}

function workerRow(worker: Worker, readAt: number): WorkerRow {
  return {
    id: worker.sessionId,
    cells: {
      name: clamp(worker.name ?? shortId(worker.sessionId), CELL_MAX_CHARS),
      status: worker.status,
      worktree: clamp(worker.worktree ?? "—", CELL_MAX_CHARS),
      activity: ago(Math.max(0, readAt - worker.lastActivity)),
      latest: clamp(worker.latest ?? "—", CELL_MAX_CHARS),
    },
    // A stopped or failed worker has nothing to stop; the row keeps its identity and no action.
    ...(canStop(worker.status) ? { actions: ["stop"] } : {}),
  };
}

/** One worker as the line an older client reads. */
function workerLine(row: WorkerRow): string {
  return clamp(
    `${row.cells.name} — ${row.cells.status} — ${row.cells.latest}`,
    FALLBACK_LINE_CHARS,
  );
}

/**
 * The crew as lines for a client that draws no grid: the first `FALLBACK_WORKER_LINES` of them,
 * then a count of the rest. A crew of twenty must not push the whole surface past the wire's
 * field cap — a board that fails for a big crew fails exactly when it is most useful.
 */
function workersFallback(state: BoardState): string {
  if (state.workers === undefined)
    return clamp(
      `Workers unavailable: ${state.workersError ?? "the host did not answer"}`,
      FALLBACK_MAX_CHARS,
    );
  if (state.workers.length === 0) return "No workers.";
  const rows = rowsOf(state);
  const lines = rows.slice(0, FALLBACK_WORKER_LINES).map(workerLine);
  const rest = rows.length - lines.length;
  if (rest > 0) lines.push(`…and ${rest} more`);
  return clamp(lines.join("\n"), FALLBACK_MAX_CHARS);
}

function queueCountsText(counts: LandQueueCounts): string {
  const base = `ready ${counts.ready}, blocked ${counts.blocked}, conflict ${counts.conflict}, failed ${counts.failed}`;
  return counts.invalid > 0 ? `${base}, invalid ${counts.invalid}` : base;
}

/** The queue as one phrase, for a line that names it already: "ready 1, blocked 0". */
function queuePhrase(queue: LandQueue): string {
  if (queue.kind === "none") return "none";
  if (queue.kind === "unreadable") return `unreadable (${queue.message})`;
  return queueCountsText(queue.counts);
}

function queueFallback(queue: LandQueue): string {
  return clamp(`Land queue: ${queuePhrase(queue)}.`, FALLBACK_MAX_CHARS);
}

function workingCount(state: BoardState): number {
  return (state.workers ?? []).filter((worker) => worker.status === "busy").length;
}

function boardTitle(state: BoardState): string {
  return `Crew · ${workingCount(state)} working`;
}

function boardSubtitle(state: BoardState): string {
  const crew =
    state.workers === undefined
      ? "workers unavailable"
      : state.workers.length === 0
        ? "no workers"
        : plural(state.workers.length, "worker");
  const queue =
    state.queue.kind === "counts"
      ? `queue: ${state.queue.counts.ready} ready`
      : state.queue.kind === "none"
        ? "queue: none"
        : "queue: unreadable";
  // A board that stopped re-reading says so where its words are, not only in its code.
  return `${crew} · ${queue}${state.refreshing ? "" : " · not refreshing"}`;
}

function workersState(state: BoardState): NonNullable<SurfaceCompositeFields["state"]> {
  if (state.workers === undefined)
    return {
      kind: "failure" as const,
      title: "Workers unavailable",
      message: state.workersError ?? "The host did not list this session's workers.",
    };
  if (state.workers.length === 0)
    return {
      kind: "empty" as const,
      title: "No workers",
      message: "This session has not started any workers.",
    };
  return "content" as const;
}

function queueState(queue: LandQueue): NonNullable<SurfaceCompositeFields["state"]> {
  if (queue.kind === "counts") return "content";
  if (queue.kind === "unreadable")
    return {
      kind: "failure" as const,
      title: "Land queue unreadable",
      message: queue.message,
    };
  return {
    kind: "empty" as const,
    title: "No land queue",
    message: "This workspace has no land queue yet.",
  };
}

function queueItems(queue: LandQueue): ChecklistFields["items"] {
  if (queue.kind !== "counts") return [];
  const { counts } = queue;
  const items = [
    { id: "ready", count: counts.ready, state: counts.ready > 0 ? "success" : "inactive" },
    { id: "blocked", count: counts.blocked, state: counts.blocked > 0 ? "warning" : "inactive" },
    { id: "conflict", count: counts.conflict, state: counts.conflict > 0 ? "error" : "inactive" },
    { id: "failed", count: counts.failed, state: counts.failed > 0 ? "error" : "inactive" },
  ] as const;
  const invalid =
    counts.invalid > 0 ? [{ id: "invalid", count: counts.invalid, state: "error" as const }] : [];
  return [...items, ...invalid].map((item) => ({
    id: item.id,
    title: `${item.count} ${item.id}`,
    state: item.state,
  }));
}

function view(state: BoardState): SurfaceView {
  return {
    header: { title: boardTitle(state), subtitle: boardSubtitle(state) },
    sections: [
      dataTable({
        id: "workers",
        header: { title: "Workers" },
        state: workersState(state),
        columns: [...COLUMNS],
        rows: rowsOf(state),
        fallback: workersFallback(state),
      }),
      checklist({
        id: "queue",
        header: { title: "Land queue" },
        state: queueState(state.queue),
        items: queueItems(state.queue),
        fallback: queueFallback(state.queue),
      }),
      actionBar({
        id: "actions",
        header: { title: "Board" },
        state: "content",
        // The rows carry the surface's other action; the bar offers the one that reads.
        actions: ["refresh"],
        fallback: "Refresh the board.",
      }),
    ],
  };
}

// --- reading, refreshing, and stopping --------------------------------------------------------

async function readBoard(
  host: CrewBoardHost,
  env: ExecutionEnv | undefined,
  cwd: string | undefined,
): Promise<BoardState> {
  const readAt = Date.now();
  const queue = readLandQueue(cwd);
  const sessions = host.sessions(env);
  if (!sessions)
    return {
      workersError: "The Oppi host is not available for this session.",
      queue,
      readAt,
      refreshing: true,
    };
  try {
    const children = await sessions.children();
    return {
      workers: children.map((child) => ({
        sessionId: child.sessionId,
        ...(child.name ? { name: child.name } : {}),
        status: workerStatus(child.status),
        ...(child.worktree ? { worktree: child.worktree } : {}),
        lastActivity: child.lastActivity,
        ...(child.latest ? { latest: child.latest } : {}),
      })),
      queue,
      readAt,
      refreshing: true,
    };
  } catch (error) {
    return {
      workersError: clamp(messageOf(error), MESSAGE_MAX_CHARS),
      queue,
      readAt,
      refreshing: true,
    };
  }
}

/**
 * Whether a read came back with a failure: a read that could not reach the host or the queue is
 * retried at the next tick, and a run of them widens the interval.
 */
function failedRead(state: BoardState): boolean {
  return state.workersError !== undefined || state.queue.kind === "unreadable";
}

/** What a summary line for the model says, and what the panel's own header says. */
function summaryOf(state: BoardState): string {
  const crew =
    state.workers === undefined
      ? `workers unavailable (${state.workersError ?? "the host did not answer"})`
      : `${plural(state.workers.length, "worker")}, ${workingCount(state)} working`;
  return `Crew board: ${crew} · queue: ${queuePhrase(state.queue)}`;
}

export function createCrewBoard(host: CrewBoardHost): Extension {
  /**
   * This extension's boards, one per conversation. It belongs to the instance, not the module: a
   * module-level map would be shared by every instance in the process, so a second host would
   * read and patch the first one's boards.
   */
  const boards = new Map<string, Board>();

  /** The board of one conversation, with its actions bound to that conversation's own panel. */
  function boardFor(key: string): Board {
    const known = boards.get(key);
    if (known) return known;
    const board = {} as Board;
    const panel = surface<BoardState>({
      id: SURFACE_ID,
      title: "Crew",
      placement: { kind: "strip" },
      lifecycle: "persistent",
      empty: {
        title: "No workers",
        message: "This session has not started any workers.",
      },
      // What an older client shows instead: the first workers on lines, then the queue.
      fallback: (state) =>
        clamp(`${workersFallback(state)}\n${queueFallback(state.queue)}`, FALLBACK_MAX_CHARS),
      actions: {
        refresh: { title: "Refresh", role: "primary" },
        // Declared optimistic state for the round trip: the row keeps its data until the stop
        // answers, and the answer is the row as the host reads it afterwards.
        stop: { title: "Stop", pending: { title: "Stopping…" } },
      },
      view,
    });
    panel.action("refresh", async (_state, tap) => {
      const next = await readBoard(host, board.env, board.cwd);
      const wire = panel.publish(tap.ctx, next);
      // A tap restarts the budget: a board that stopped re-reading is live again, and if it never
      // quietens it stops again after its own bounded ticks.
      start(board);
      return wire;
    });
    panel.action("stop", async (state, tap) => {
      const worker = state.workers?.find((one) => one.sessionId === tap.rowId);
      if (!worker)
        return {
          error: {
            compositeId: tap.compositeId,
            message: `Session ${tap.rowId ?? "(none)"} is not a child of this session.`,
          },
        };
      const sessions = host.sessions(board.env);
      if (!sessions)
        return {
          error: {
            compositeId: tap.compositeId,
            message: "The Oppi host is not available, so nothing was stopped.",
          },
        };
      try {
        await sessions.stop(worker.sessionId);
      } catch (error) {
        // The host refuses a Session that is not this caller's child; the card says so.
        return { error: { compositeId: tap.compositeId, message: messageOf(error) } };
      }
      // The whole board, not a patch of its rows: a client that subscribes later reads the
      // fallback words too, and a patch would leave those describing the crew before the stop.
      return panel.publish(tap.ctx, await readBoard(host, board.env, board.cwd));
    });
    board.panel = panel;
    board.ticks = 0;
    board.failures = 0;
    board.interval = 0;
    board.reading = false;
    boards.set(key, board);
    return board;
  }

  /**
   * Re-read while the board lives. Everything a board can throw is caught here: an escaping
   * rejection reaches the process's unhandled-rejection handler, which stops the server, and no
   * board is worth that.
   */
  async function tick(board: Board): Promise<void> {
    if (board.reading) return;
    board.reading = true;
    try {
      const surfaces = host.surfaces(board.env);
      if (!surfaces) {
        // The Session stopped: its loop is gone, so this board has nothing to publish into.
        end(board);
        return;
      }
      if (board.ticks >= REFRESH_LIMIT) {
        // The budget is spent. Say so in the words, then stop: a board that went quiet without
        // saying so reads as live forever. A tap on Refresh starts the reads again.
        stopReading(board, surfaces);
        return;
      }
      board.ticks += 1;
      const next = await readBoard(host, board.env, board.cwd);
      board.failures = failedRead(next) ? board.failures + 1 : 0;
      publishIfChanged(board, surfaces, next);
      // A run of failed reads widens the interval; one good read brings it back.
      if (intervalOf(board) !== board.interval) schedule(board);
    } catch (error) {
      fail(board, error);
    } finally {
      board.reading = false;
    }
  }

  /** Publish `next` unless it renders the same as what is out: a quiet board writes nothing. */
  function publishIfChanged(board: Board, surfaces: SurfacePublisher, next: BoardState): void {
    const published = board.panel.current();
    const same =
      published !== undefined &&
      JSON.stringify(board.panel.render(next)) === JSON.stringify(board.panel.render(published));
    if (!same) board.panel.publish({ surfaces }, next);
  }

  /** The interval this board's reads are due on, widened while reads keep failing. */
  function intervalOf(board: Board): number {
    return board.failures >= FAILURE_BACKOFF_AFTER
      ? REFRESH_INTERVAL_MS * FAILURE_BACKOFF_FACTOR
      : REFRESH_INTERVAL_MS;
  }

  function schedule(board: Board): void {
    stopTimer(board);
    const interval = intervalOf(board);
    board.interval = interval;
    const timer = setInterval(() => {
      // Caught inside `tick` already; this is the belt for anything outside its try.
      void tick(board).catch((error: unknown) => fail(board, error));
    }, interval);
    // A board must never be the reason the server process stays alive.
    timer.unref?.();
    board.timer = timer;
  }

  /** Begin, or restart with a fresh budget, the board's re-reads. */
  function start(board: Board): void {
    board.ticks = 0;
    board.failures = 0;
    schedule(board);
  }

  function stopTimer(board: Board): void {
    if (board.timer !== undefined) clearInterval(board.timer);
    board.timer = undefined;
  }

  /** Keep the board with its last state, saying it is not re-reading it any more. */
  function stopReading(board: Board, surfaces: SurfacePublisher): void {
    const last = board.panel.current();
    try {
      if (last) board.panel.publish({ surfaces }, { ...last, refreshing: false });
    } catch {
      // Nothing to say in words: stopping the reads is the whole answer.
    }
    // The board stays known, so a later `crew_board` reuses this panel instead of publishing a
    // second one over the same surface id.
    stopTimer(board);
  }

  /**
   * A board that cannot render or publish is not a board: the card says what went wrong, once,
   * and the re-reads stop. This is what catching in `tick` is for.
   */
  function fail(board: Board, error: unknown): void {
    const surfaces = host.surfaces(board.env);
    if (surfaces) {
      try {
        board.panel.publish(
          { surfaces },
          {
            workersError: clamp(messageOf(error), MESSAGE_MAX_CHARS),
            queue: readLandQueue(board.cwd),
            readAt: Date.now(),
            refreshing: false,
          },
        );
      } catch {
        // Even the failure card could not be drawn; ending the board is all that is left.
      }
    }
    end(board);
  }

  /** Forget this board and stop its timer: the surface loop is gone, or the board is unfixable. */
  function end(board: Board): void {
    stopTimer(board);
    for (const [key, known] of boards) if (known === board) boards.delete(key);
  }

  const crewBoard = defineTool({
    name: "crew_board",
    description:
      "Show or refresh the crew board for this session: its worker sessions and the land queue. " +
      "A live panel of the sessions this one launched (name, status, worktree, last activity, " +
      "newest reply), each of which can be stopped from the panel, beside the land queue's " +
      "ready, blocked, conflict, and failed counts. Reads only; the queue belongs to whoever " +
      "lands.",
    parameters: obj({}),
    async execute(_args, api) {
      const env = api.env;
      const surfaces = host.surfaces(env);
      if (!surfaces)
        return {
          output: [
            {
              type: "text" as const,
              text: "This session has no live surface loop, so the crew board was not published.",
            },
          ],
          isError: true,
        };
      const storeId = host.sessions(env)?.storeId ?? "session";
      const board = boardFor(`${storeId}:${api.conversationId}`);
      board.env = env;
      board.cwd = env?.cwd;
      const state = await readBoard(host, env, board.cwd);
      try {
        board.panel.publish({ surfaces }, state);
      } catch (error) {
        // The words the wire refused: the model should hear it from the tool, not from a silence.
        return {
          output: [
            {
              type: "text" as const,
              text: `The crew board could not be published: ${messageOf(error)}`,
            },
          ],
          isError: true,
        };
      }
      start(board);
      return { output: [{ type: "text" as const, text: summaryOf(state) }] };
    },
  });

  return defineExtension({
    name: "oppi.crew-board",
    runtimes: ["host"],
    tools: [crewBoard],
  });
}

const DurableCrewBoard = createCrewBoard({
  sessions: (env) => oppiHost().sessions(env),
  surfaces: (env) => oppiHost().surfaces(env),
});

export default defineFacet((_host, self) => self.contribute(Extensions, DurableCrewBoard));
