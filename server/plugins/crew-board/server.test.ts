import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import { projectExtensionUISurfaceToV1 } from "../../src/extension-surface.js";
import type {
  ConversationId,
  ExecutionEnv,
  ExtensionUISurface,
  SurfaceDispatch,
  SurfacePublisher,
  ToolExecutionApi,
  ToolRegistration,
} from "oppi/v1";
import {
  FAILURE_BACKOFF_AFTER,
  FAILURE_BACKOFF_FACTOR,
  FALLBACK_MAX_CHARS,
  FALLBACK_WORKER_LINES,
  MAX_QUEUE_BYTES,
  REFRESH_INTERVAL_MS,
  REFRESH_LIMIT,
  createCrewBoard,
  gitCommonDir,
  readLandQueue,
  type CrewBoardHost,
  type CrewSessions,
} from "./server.js";
import { makeTempDir } from "../../tests/harness/temp-dir.js";

/**
 * The board's own code, over a fake host: the child Sessions are fixtures, the land queue is a
 * real file in a temp repository, and the surface loop is a recorder. The session-level wiring is
 * `tests/crew-board-session.test.ts`.
 */

const NOW = Date.parse("2026-11-03T12:00:00.000Z");

/** `setImmediate` as the process has it: the tests below fake timers and still need one real turn. */
const realSetImmediate = setImmediate;

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

type Child = Awaited<ReturnType<CrewSessions["children"]>>[number];

function child(overrides: Partial<Child> & { sessionId: string }): Child {
  return {
    conversationId: 1 as ConversationId,
    status: "ready",
    lastActivity: NOW - 5_000,
    ...overrides,
  } as Child;
}

interface Recorded {
  surface: ExtensionUISurface;
  dispatch: SurfaceDispatch | undefined;
}

/** The surface loop as a plugin sees it: what was published, and the handler that goes with it. */
function surfaceLoop(): {
  live: boolean;
  publisher: SurfacePublisher;
  published: Recorded[];
  dismiss: (
    dispatch: SurfaceDispatch | undefined,
    actionId: string,
    rowId?: string,
  ) => ReturnType<SurfaceDispatch>;
} {
  const published: Recorded[] = [];
  const loop = {
    live: true,
    publisher: {
      publish(surface: ExtensionUISurface, dispatch?: SurfaceDispatch) {
        published.push({ surface, dispatch });
        return undefined;
      },
      dismiss() {
        return undefined;
      },
    },
    published,
    dismiss(dispatch: SurfaceDispatch | undefined, actionId: string, rowId?: string) {
      if (!dispatch) throw new Error("nothing was published to act on");
      return dispatch({
        compositeId: actionId === "refresh" ? "actions" : "workers",
        actionId,
        ...(rowId === undefined ? {} : { rowId }),
        revision: 1,
        signal: new AbortController().signal,
      });
    },
  };
  return loop;
}

function fakeHost(options: {
  children?: () => Promise<Child[]>;
  stop?: (sessionId: string) => Promise<void>;
  surfaces?: () => SurfacePublisher | undefined;
}): { host: CrewBoardHost; stopped: string[] } {
  const stopped: string[] = [];
  const host: CrewBoardHost = {
    sessions: () =>
      ({
        storeId: "store-1",
        children: options.children ?? (async () => []),
        stop: async (sessionId: string) => {
          stopped.push(sessionId);
          await options.stop?.(sessionId);
        },
      }) satisfies CrewSessions,
    surfaces: options.surfaces ?? (() => undefined),
  };
  return { host, stopped };
}

/** A temp repository: `.git` next to a queue file the script owns, in its own JSON-lines format. */
function repository(entries?: Array<Record<string, unknown>>): string {
  const dir = makeTempDir("oppi-crew-board-");
  const queue = join(dir, ".git", "oppi", "land-queue");
  mkdirSync(queue, { recursive: true });
  if (entries)
    writeFileSync(join(queue, "queue.jsonl"), entries.map((e) => JSON.stringify(e)).join("\n"));
  return dir;
}

const QUEUE = [
  { branch: "worker-a", after: [], status: "queued" },
  { branch: "worker-b", after: ["worker-a"], status: "queued" },
  { branch: "worker-c", after: [], status: "conflict" },
  { branch: "worker-d", after: [], status: "failed" },
  { branch: "worker-e", after: [], status: "invalid" },
];

function tool(host: CrewBoardHost): ToolRegistration {
  const extension = createCrewBoard(host);
  const registration = extension.tools?.[0];
  if (!registration) throw new Error("the board registers no tool");
  return registration;
}

/** The queue repo as the tool's own env: a workspace checkout with a queue in its git dir. */
function apiFor(cwd: string, conversationId = nextConversation++): ToolExecutionApi {
  return {
    env: { cwd } as ExecutionEnv,
    conversationId: conversationId as ConversationId,
  } as unknown as ToolExecutionApi;
}

/** The plugin keeps one board per conversation per instance, so every test takes its own. */
let nextConversation = 100;

function sectionsOf(surface: ExtensionUISurface): {
  workers: ExtensionUISurface["sections"][number] | undefined;
  queue: ExtensionUISurface["sections"][number] | undefined;
  actions: ExtensionUISurface["sections"][number] | undefined;
} {
  const [workers, queue, actions] = surface.sections;
  return { workers, queue, actions };
}

describe("crew board", () => {
  test("publishes the workers it launched and the land queue's counts", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const children = [
      child({
        sessionId: "s-1",
        name: "builder",
        status: "busy",
        lastActivity: NOW - 2 * 60_000,
        latest: "Refactoring the parser",
        worktree: "subagent/builder",
      }),
      child({ sessionId: "s-2", name: "reviewer", lastActivity: NOW - 5_000 }),
    ];
    const { host } = fakeHost({
      children: async () => children,
      surfaces: () => loop.publisher,
    });
    const result = await tool(host).execute({}, apiFor(repository(QUEUE)));

    expect(loop.published).toHaveLength(1);
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    expect(surface.id).toBe("crew-board");
    expect(surface.placement).toEqual({ kind: "strip" });
    expect(surface.lifecycle).toBe("persistent");
    expect(surface.header).toMatchObject({
      title: "Crew · 1 working",
      subtitle: "2 workers · queue: 1 ready",
    });
    // Stop is offered with the optimistic words for its round trip.
    expect(surface.actions.stop).toMatchObject({ title: "Stop", pending: { title: "Stopping…" } });
    expect(surface.actions.refresh).toMatchObject({ role: "primary" });

    const { workers, queue, actions } = sectionsOf(surface);
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    expect(workers.state).toEqual({ kind: "content" });
    expect(workers.columns.map((column) => column.title)).toEqual([
      "Name",
      "Status",
      "Worktree",
      "Last activity",
      "Latest",
    ]);
    expect(workers.rows).toEqual([
      {
        id: "s-1",
        cells: {
          name: "builder",
          status: "busy",
          worktree: "subagent/builder",
          activity: "2m ago",
          latest: "Refactoring the parser",
        },
        actions: ["stop"],
      },
      {
        id: "s-2",
        cells: {
          name: "reviewer",
          status: "ready",
          worktree: "—",
          activity: "just now",
          latest: "—",
        },
        actions: ["stop"],
      },
    ]);

    if (queue?.composite !== "checklist") throw new Error("queue is not a checklist");
    expect(queue.items.map((item) => [item.title, item.state])).toEqual([
      ["1 ready", "success"],
      ["1 blocked", "warning"],
      ["1 conflict", "error"],
      ["1 failed", "error"],
      ["1 invalid", "error"],
    ]);
    expect(queue.fallback).toEqual({
      text: "Land queue: ready 1, blocked 1, conflict 1, failed 1, invalid 1.",
    });
    if (actions?.composite !== "actionBar") throw new Error("actions is not a bar");
    expect(actions.actions).toEqual(["refresh"]);

    // The words an older client shows: one line per worker, then the queue.
    expect(surface.fallback.text).toBe(
      [
        "builder — busy — Refactoring the parser",
        "reviewer — ready — —",
        "Land queue: ready 1, blocked 1, conflict 1, failed 1, invalid 1.",
      ].join("\n"),
    );
    expect(result.output).toEqual([
      {
        type: "text",
        text: "Crew board: 2 workers, 1 working · queue: ready 1, blocked 1, conflict 1, failed 1, invalid 1",
      },
    ]);
  });

  test("an older client's projection is the grid plus the queue's words", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host } = fakeHost({
      children: async () => [
        child({ sessionId: "s-1", name: "builder", status: "busy", latest: "Building" }),
      ],
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    const projection = projectExtensionUISurfaceToV1(surface);
    expect(projection.presentation).toMatchObject({
      style: "surfacePanel",
      title: "Crew",
      subtitle: "1 worker · queue: 1 ready",
    });
    // The workers table projects to the v1 grid; the queue section projects to its own words.
    expect(projection.blocks[0]).toMatchObject({
      type: "table",
      columns: ["Name", "Status", "Worktree", "Last activity", "Latest"],
      rows: [["builder", "busy", "—", "just now", "Building"]],
    });
    expect(projection.blocks[1]).toMatchObject({
      type: "text",
      spans: [{ text: "Land queue: ready 1, blocked 1, conflict 1, failed 1, invalid 1." }],
    });
    expect(projection.fallback.text).toBe(surface.fallback.text);
  });

  test("says so when the session has no workers, and when the workspace has no queue", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host } = fakeHost({ surfaces: () => loop.publisher });
    const result = await tool(host).execute({}, apiFor(makeTempDir("oppi-crew-board-none-")));
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    expect(surface.header).toMatchObject({
      title: "Crew · 0 working",
      subtitle: "no workers · queue: none",
    });
    const { workers, queue } = sectionsOf(surface);
    expect(workers?.state).toEqual({
      kind: "empty",
      title: "No workers",
      message: "This session has not started any workers.",
    });
    expect(queue?.state).toEqual({
      kind: "empty",
      title: "No land queue",
      message: "This workspace has no land queue yet.",
    });
    expect(surface.fallback.text).toBe("No workers.\nLand queue: none.");
    expect(result.output).toEqual([
      { type: "text", text: "Crew board: 0 workers, 0 working · queue: none" },
    ]);
  });

  test("a queue file it cannot read is a failure with the words, not an empty queue", () => {
    const dir = makeTempDir("oppi-crew-board-broken-");
    mkdirSync(join(dir, ".git", "oppi", "land-queue", "queue.jsonl"), { recursive: true });
    expect(readLandQueue(dir)).toMatchObject({ kind: "unreadable" });
  });

  test("failures name what could not be read", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host } = fakeHost({
      children: async () => {
        throw new Error("the store is closing");
      },
      surfaces: () => loop.publisher,
    });
    const result = await tool(host).execute({}, apiFor(repository()));
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    expect(surface.header.title).toBe("Crew · 0 working");
    expect(surface.header.subtitle).toBe("workers unavailable · queue: none");
    expect(sectionsOf(surface).workers?.state).toEqual({
      kind: "failure",
      title: "Workers unavailable",
      message: "the store is closing",
    });
    expect(surface.fallback.text).toContain("Workers unavailable: the store is closing");
    expect(result.output?.[0]).toMatchObject({
      text: "Crew board: workers unavailable (the store is closing) · queue: none",
    });
  });

  test("a session with no live surface loop publishes nothing and says why", async () => {
    const { host } = fakeHost({});
    const result = await tool(host).execute({}, apiFor(repository(QUEUE)));
    expect(result.isError).toBe(true);
    expect(result.output?.[0]).toMatchObject({
      text: "This session has no live surface loop, so the crew board was not published.",
    });
  });

  test("stopping a child stops it through the host and republishes the board", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let children = [
      child({ sessionId: "s-1", name: "builder", status: "busy", latest: "Building" }),
      child({ sessionId: "s-2", name: "reviewer", status: "busy", latest: "Reviewing" }),
    ];
    const { host, stopped } = fakeHost({
      children: async () => children,
      stop: async (sessionId) => {
        // What the session actually does: the child's work is aborted, its row reads stopped.
        children = children.map((one) =>
          one.sessionId === sessionId ? { ...one, status: "stopped" as const } : one,
        );
      },
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    const dispatch = loop.published[0]?.dispatch;

    const answer = await loop.dismiss(dispatch, "stop", "s-1");
    expect(stopped).toEqual(["s-1"]);
    const board = "surface" in answer ? answer.surface : undefined;
    if (!board) throw new Error(`expected the board, got ${JSON.stringify(answer)}`);
    const workers = sectionsOf(board).workers;
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    expect(workers.rows.map((row) => [row.id, row.cells.status, row.actions])).toEqual([
      ["s-1", "stopped", undefined],
      ["s-2", "busy", ["stop"]],
    ]);
    // The header counts the working ones.
    expect(board.header.title).toBe("Crew · 1 working");
    // The words an older client reads describe the crew after the stop, not before it: the board
    // is republished whole rather than patched, so the fallback cannot go stale.
    expect(board.fallback.text).toBe(
      [
        "builder — stopped — Building",
        "reviewer — busy — Reviewing",
        "Land queue: ready 1, blocked 1, conflict 1, failed 1, invalid 1.",
      ].join("\n"),
    );
  });

  test("a failed worker reads as an error, not as a clean stop, and offers no Stop", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host } = fakeHost({
      children: async () => [
        child({ sessionId: "s-1", name: "builder", status: "error", latest: "the store failed" }),
      ],
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    const workers = sectionsOf(surface).workers;
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    expect(workers.rows[0]).toMatchObject({
      cells: { name: "builder", status: "error", latest: "the store failed" },
    });
    expect(workers.rows[0]?.actions).toBeUndefined();
    expect(surface.fallback.text).toContain("builder — error — the store failed");
  });

  test("stopping a Session that is not a child is refused on the card", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host, stopped } = fakeHost({
      children: async () => [child({ sessionId: "s-1", name: "builder" })],
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    const answer = await loop.dismiss(loop.published[0]?.dispatch, "stop", "s-other");
    expect(stopped).toEqual([]);
    expect(answer).toEqual({
      error: {
        compositeId: "workers",
        message: "Session s-other is not a child of this session.",
      },
    });
  });

  test("a refusal from the host reaches the card as its own words", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const { host } = fakeHost({
      children: async () => [child({ sessionId: "s-1", name: "builder" })],
      stop: async () => {
        throw new Error("Session s-1 is not a child of this session.");
      },
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    const answer = await loop.dismiss(loop.published[0]?.dispatch, "stop", "s-1");
    expect(answer).toEqual({
      error: {
        compositeId: "workers",
        message: "Session s-1 is not a child of this session.",
      },
    });
  });

  test("Refresh re-reads the workers and publishes what changed", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let children = [child({ sessionId: "s-1", name: "builder", status: "busy" })];
    const { host } = fakeHost({
      children: async () => children,
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    children = [...children, child({ sessionId: "s-2", name: "reviewer" })];

    const answer = await loop.dismiss(loop.published[0]?.dispatch, "refresh");
    if (!("surface" in answer) || !answer.surface) throw new Error("Refresh published no surface");
    expect(answer.surface.header.subtitle).toBe("2 workers · queue: 1 ready");
    const workers = answer.surface.sections[0];
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    expect(workers.rows.map((row) => row.cells.name)).toEqual(["builder", "reviewer"]);
  });

  test("the board re-reads on its own until the surface loop is gone", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let children = [child({ sessionId: "s-1", name: "builder", status: "busy" })];
    const { host } = fakeHost({
      children: async () => children,
      surfaces: () => (loop.live ? loop.publisher : undefined),
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    expect(loop.published).toHaveLength(1);

    // Nothing changed: the interval reads and publishes nothing new.
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    expect(loop.published).toHaveLength(1);

    // A worker appears: the next re-read publishes it.
    children = [...children, child({ sessionId: "s-2", name: "reviewer" })];
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    expect(loop.published).toHaveLength(2);
    const surface = loop.published[1]?.surface;
    if (!surface) throw new Error("the interval published nothing");
    expect(surface.header.subtitle).toBe("2 workers · queue: 1 ready");
    // A re-publish keeps the panel's actions bound: a tap still reaches the board.
    expect(loop.published[1]?.dispatch).toBeDefined();

    // The Session stops: its loop is gone, so the interval ends with it.
    loop.live = false;
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS * 4);
    expect(loop.published).toHaveLength(2);
  });

  test("a board stops re-reading after its bounded refresh count, and says so", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let reads = 0;
    const { host } = fakeHost({
      // Every read differs, so every tick publishes.
      children: async () => {
        reads += 1;
        return [child({ sessionId: `s-${reads}`, name: `worker-${reads}`, status: "busy" })];
      },
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    for (let tick = 0; tick < REFRESH_LIMIT + 3; tick += 1)
      await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    // The budget's reads, then one last board whose subtitle says it stopped reading.
    expect(loop.published).toHaveLength(1 + REFRESH_LIMIT + 1);
    const last = loop.published.at(-1)?.surface;
    if (!last) throw new Error("nothing was published");
    expect(last.header.subtitle).toBe("1 worker · queue: 1 ready · not refreshing");
    expect(reads).toBe(1 + REFRESH_LIMIT);
  });

  test("a Refresh after the budget restarts the reads with a fresh budget", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let children = [child({ sessionId: "s-1", name: "builder", status: "busy" })];
    const { host } = fakeHost({
      children: async () => children,
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    for (let tick = 0; tick <= REFRESH_LIMIT; tick += 1)
      await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    const stopped = loop.published.at(-1)?.surface;
    expect(stopped?.header.subtitle).toContain("not refreshing");

    // A tap reads the board again, in one reply, and starts the reads over.
    children = [...children, child({ sessionId: "s-2", name: "reviewer" })];
    const answer = await loop.dismiss(loop.published.at(-1)?.dispatch, "refresh");
    const board = "surface" in answer ? answer.surface : undefined;
    if (!board) throw new Error(`expected the board, got ${JSON.stringify(answer)}`);
    expect(board.header.subtitle).toBe("2 workers · queue: 1 ready");

    // The interval is live again: the next re-read publishes what changed.
    const published = loop.published.length;
    children = [...children, child({ sessionId: "s-3", name: "scout" })];
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    expect(loop.published).toHaveLength(published + 1);
  });

  test("a big crew publishes, and its fallbacks stay under the wire's field cap", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    const latest = "x".repeat(120);
    const children = Array.from({ length: 20 }, (_unused, index) =>
      child({
        sessionId: `s-${index}`,
        name: `worker-${index}`,
        status: "busy" as const,
        latest,
      }),
    );
    const { host } = fakeHost({ children: async () => children, surfaces: () => loop.publisher });
    const result = await tool(host).execute({}, apiFor(repository(QUEUE)));
    expect(result.isError).toBeFalsy();
    const surface = loop.published[0]?.surface;
    if (!surface) throw new Error("nothing was published");
    const workers = sectionsOf(surface).workers;
    if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
    // The grid shows the whole crew…
    expect(workers.rows).toHaveLength(20);
    // …and the fallback shows eight lines, then counts the rest.
    const lines = workers.fallback.text.split("\n");
    expect(lines).toHaveLength(FALLBACK_WORKER_LINES + 1);
    expect(lines.at(-1)).toBe("…and 12 more");
    expect(Array.from(lines[0] ?? "").length).toBeLessThanOrEqual(160);
    expect(Array.from(workers.fallback.text).length).toBeLessThan(2_000);
    expect(Array.from(surface.fallback.text).length).toBeLessThan(2_000);
    expect(Array.from(surface.fallback.text).length).toBeLessThanOrEqual(FALLBACK_MAX_CHARS);
  });

  test("a render throw during a re-read is caught: no unhandled rejection, no timer left", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let children = [child({ sessionId: "s-1", name: "builder", status: "busy" })];
    const { host } = fakeHost({ children: async () => children, surfaces: () => loop.publisher });
    await tool(host).execute({}, apiFor(repository(QUEUE)));

    const unhandled: unknown[] = [];
    const onUnhandled = (reason: unknown): number => unhandled.push(reason);
    process.on("unhandledRejection", onUnhandled);
    try {
      // A value the wire refuses, which is what an overflowing field used to be.
      children = [
        child({ sessionId: "s-1", name: "builder", latest: { text: "?" } as unknown as string }),
      ];
      await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
      // One real turn, so the process would have reported an escaping rejection by now.
      await new Promise((resolve) => realSetImmediate(resolve));
      expect(unhandled).toEqual([]);

      // The board says what went wrong, once, and stops re-reading rather than throwing every 25s.
      const last = loop.published.at(-1)?.surface;
      if (!last) throw new Error("nothing was published");
      expect(last.sections[0]?.state).toMatchObject({
        kind: "failure",
        title: "Workers unavailable",
      });
      expect(last.header.subtitle).toContain("not refreshing");
      expect(vi.getTimerCount()).toBe(0);
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  test("reads that keep failing widen the interval, which a working read resets", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const loop = surfaceLoop();
    let reads = 0;
    let failing = true;
    const { host } = fakeHost({
      children: async () => {
        reads += 1;
        if (failing) throw new Error("the store is closing");
        return [child({ sessionId: "s-1", name: "builder" })];
      },
      surfaces: () => loop.publisher,
    });
    await tool(host).execute({}, apiFor(repository(QUEUE)));
    expect(reads).toBe(1);
    expect(loop.published.at(-1)?.surface.sections[0]?.state).toMatchObject({ kind: "failure" });

    for (let tick = 0; tick < FAILURE_BACKOFF_AFTER; tick += 1)
      await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    expect(reads).toBe(1 + FAILURE_BACKOFF_AFTER);

    // Three failed reads in a row: the interval is four times as wide, so the next read waits.
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS * (FAILURE_BACKOFF_FACTOR - 1));
    expect(reads).toBe(1 + FAILURE_BACKOFF_AFTER);
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS);
    expect(reads).toBe(2 + FAILURE_BACKOFF_AFTER);

    // A read that works brings the interval back, and the card is content again.
    failing = false;
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS * FAILURE_BACKOFF_FACTOR);
    expect(reads).toBe(3 + FAILURE_BACKOFF_AFTER);
    expect(loop.published.at(-1)?.surface.sections[0]?.state).toEqual({ kind: "content" });
    // …and the interval is back to its own 25 seconds, not the widened one.
    await vi.advanceTimersByTimeAsync(REFRESH_INTERVAL_MS - 1);
    expect(reads).toBe(3 + FAILURE_BACKOFF_AFTER);
    await vi.advanceTimersByTimeAsync(1);
    expect(reads).toBe(4 + FAILURE_BACKOFF_AFTER);
  });

  test("two instances keep their own boards for the same conversation", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
    const dir = repository(QUEUE);
    const conversation = nextConversation++;
    const first = surfaceLoop();
    const second = surfaceLoop();
    const one = fakeHost({
      children: async () => [child({ sessionId: "s-1", name: "builder" })],
      surfaces: () => first.publisher,
    });
    const two = fakeHost({
      children: async () => [child({ sessionId: "s-2", name: "reviewer" })],
      surfaces: () => second.publisher,
    });
    await tool(one.host).execute({}, apiFor(dir, conversation));
    await tool(two.host).execute({}, apiFor(dir, conversation));

    // Each instance published its own crew: neither read or patched the other's board.
    expect(first.published).toHaveLength(1);
    expect(second.published).toHaveLength(1);
    const nameOf = (surface: ExtensionUISurface | undefined): unknown[] => {
      const workers = surface ? sectionsOf(surface).workers : undefined;
      if (workers?.composite !== "dataTable") throw new Error("workers is not a table");
      return workers.rows.map((row) => row.cells.name);
    };
    expect(nameOf(first.published[0]?.surface)).toEqual(["builder"]);
    expect(nameOf(second.published[0]?.surface)).toEqual(["reviewer"]);
  });
});

describe("land queue read path", () => {
  test("a worktree checkout reads the queue of the repository it belongs to", () => {
    const dir = makeTempDir("oppi-crew-board-worktree-");
    const common = join(dir, "main", ".git");
    mkdirSync(join(common, "worktrees", "wt-1"), { recursive: true });
    mkdirSync(join(common, "oppi", "land-queue"), { recursive: true });
    writeFileSync(
      join(common, "oppi", "land-queue", "queue.jsonl"),
      JSON.stringify({ branch: "worker-a", after: [], status: "queued" }),
    );
    const worktree = join(dir, "checkout");
    mkdirSync(worktree, { recursive: true });
    // A worktree's `.git` is a file naming its git dir, which names the common dir.
    writeFileSync(join(common, "worktrees", "wt-1", "commondir"), "../..");
    writeFileSync(join(worktree, ".git"), `gitdir: ${join(common, "worktrees", "wt-1")}\n`);

    expect(gitCommonDir(worktree)).toBe(common);
    expect(readLandQueue(worktree)).toEqual({
      kind: "counts",
      counts: { ready: 1, blocked: 0, conflict: 0, failed: 0, invalid: 0 },
    });
  });

  test("no repository, no queue", () => {
    expect(gitCommonDir("/tmp")).toBeUndefined();
    expect(readLandQueue(undefined)).toEqual({ kind: "none" });
    expect(readLandQueue(makeTempDir("oppi-crew-board-repo-less-"))).toEqual({ kind: "none" });
  });

  test("a dependency the queue still holds blocks its dependent, whatever its status", () => {
    // The integrator's own readiness rule: queued, conflict, failed, and invalid all hold back the
    // entries waiting on them. A dependency the file no longer names is gone, so it does not.
    const dir = repository([
      { branch: "worker-a", after: [], status: "conflict" },
      { branch: "worker-b", after: ["worker-a"], status: "queued" },
      { branch: "worker-c", after: ["worker-gone"], status: "queued" },
      { branch: "worker-d", after: [], status: "failed" },
      { branch: "worker-e", after: ["worker-b"], status: "queued" },
    ]);
    expect(readLandQueue(dir)).toEqual({
      kind: "counts",
      counts: { ready: 1, blocked: 2, conflict: 1, failed: 1, invalid: 0 },
    });
  });

  test("a queue file too large to read is words, not an unbounded read", () => {
    const dir = makeTempDir("oppi-crew-board-huge-");
    const queue = join(dir, ".git", "oppi", "land-queue");
    mkdirSync(queue, { recursive: true });
    writeFileSync(join(queue, "queue.jsonl"), "x".repeat(MAX_QUEUE_BYTES + 1));
    const read = readLandQueue(dir);
    expect(read.kind).toBe("unreadable");
    if (read.kind !== "unreadable") throw new Error("expected the size guard to speak");
    expect(read.message).toContain("KiB");
  });
});
