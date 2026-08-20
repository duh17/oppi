import { afterEach, describe, expect, it, vi } from "vitest";

import {
  formatWaitLiveSnapshot,
  parseWatchCondition,
  runSessionWatch,
} from "../src/cli/commands/session-watch.js";
import { sleepWithSignal } from "../src/cli/commands/wait.js";

function errorWithStatus(message: string, status: number): Error & { status: number } {
  return Object.assign(new Error(message), { status });
}

describe("session wait poller contract", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it.each([
    [undefined, "idle", "idle"],
    [" ATTENTION ", "idle", "attention"],
    ["either", "idle", "either"],
    ["any-change", "idle", "any-change"],
  ] as const)("parses condition %s", (raw, fallback, expected) => {
    expect(parseWatchCondition(raw, fallback)).toBe(expected);
  });

  it("rejects unknown conditions", () => {
    expect(() => parseWatchCondition("done", "idle")).toThrow("condition must be");
  });

  it("resolves immediately when a session baseline is idle", async () => {
    const emit = vi.fn();
    const outcome = await runSessionWatch(
      ["s/1"],
      { condition: "idle", requireAll: false, intervalMs: 10, timeoutMs: 100 },
      async <T>(path: string): Promise<T> => {
        expect(path).toBe("/sessions/s%2F1/events?since=0");
        return {
          session: { status: "ready", messageCount: 3, lastMessage: "finished" },
          events: [],
          currentSeq: 4,
        } as T;
      },
      emit,
    );

    expect(outcome).toEqual({
      kind: "session",
      sessionId: "s/1",
      reason: "idle",
      status: "ready",
      outputDelta: "finished",
      outputDeltaKind: "latest",
    });
    expect(emit).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: "resolved",
        sessionId: "s/1",
        reason: "idle",
        status: "ready",
        messageCount: 3,
        last: "finished",
      }),
    );
  });

  it("returns newly observed assistant output as the wait delta", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    let polls = 0;
    const promise = runSessionWatch(
      ["s"],
      { condition: "idle", requireAll: false, intervalMs: 20, timeoutMs: 100 },
      async <T>(): Promise<T> => {
        polls += 1;
        return (
          polls === 1
            ? { session: { status: "busy" }, events: [], currentSeq: 1 }
            : {
                session: { status: "ready", messageCount: 4 },
                events: [
                  { type: "message_end", role: "assistant", content: "  final answer  " },
                ],
                currentSeq: 2,
              }
        ) as T;
      },
      vi.fn(),
    );

    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20);
    await expect(promise).resolves.toMatchObject({
      kind: "session",
      reason: "idle",
      outputDelta: "final answer",
      outputDeltaKind: "delta",
    });
  });

  it("does not append a truncated session snapshot after a full assistant event", async () => {
    vi.useFakeTimers();
    let polls = 0;
    const fullOutput = "full assistant response ".repeat(12).trim();
    const promise = runSessionWatch(
      ["s"],
      { condition: "idle", requireAll: false, intervalMs: 20, timeoutMs: 100 },
      async <T>(): Promise<T> => {
        polls += 1;
        if (polls === 1) {
          return { session: { status: "busy" }, events: [], currentSeq: 1 } as T;
        }
        if (polls === 2) {
          return {
            session: { status: "busy", lastMessage: fullOutput.slice(0, 100) },
            events: [{ type: "message_end", role: "assistant", content: fullOutput }],
            currentSeq: 2,
          } as T;
        }
        return {
          session: { status: "ready", lastMessage: fullOutput.slice(0, 100) },
          events: [],
          currentSeq: 2,
        } as T;
      },
      vi.fn(),
    );

    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20);
    await vi.advanceTimersByTimeAsync(20);
    await expect(promise).resolves.toMatchObject({
      kind: "session",
      outputDelta: fullOutput,
      outputDeltaKind: "delta",
    });
  });

  it("preserves repeated assistant messages as separate output delta entries", async () => {
    vi.useFakeTimers();
    let polls = 0;
    const promise = runSessionWatch(
      ["s"],
      { condition: "idle", requireAll: false, intervalMs: 20, timeoutMs: 100 },
      async <T>(): Promise<T> => {
        polls += 1;
        return (
          polls === 1
            ? { session: { status: "busy" }, events: [], currentSeq: 1 }
            : {
                session: { status: "ready", lastMessage: "same" },
                events: [
                  { type: "message_end", role: "assistant", content: "same" },
                  { type: "message_end", role: "assistant", content: "same" },
                ],
                currentSeq: 3,
              }
        ) as T;
      },
      vi.fn(),
    );

    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20);
    await expect(promise).resolves.toMatchObject({
      kind: "session",
      outputDelta: "same\n\nsame",
      outputDeltaKind: "delta",
    });
  });

  it("bounds oversized latest output used as the wait fallback", async () => {
    const output = "x".repeat(60_000);
    const outcome = await runSessionWatch(
      ["s"],
      { condition: "idle", requireAll: false, intervalMs: 10, timeoutMs: 100 },
      async <T>(): Promise<T> =>
        ({ session: { status: "ready", lastMessage: output }, events: [], currentSeq: 1 }) as T,
      vi.fn(),
    );

    expect(outcome.kind).toBe("session");
    if (outcome.kind !== "session") return;
    expect(outcome.outputDeltaKind).toBe("latest");
    expect(outcome.outputDelta).toHaveLength(50_000);
    expect(outcome.outputDelta).toContain("earlier output omitted");
  });

  it("resolves any-change only after baseline event activity", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(1_000);
    let polls = 0;
    const emit = vi.fn();
    const promise = runSessionWatch(
      ["s"],
      { condition: "any-change", requireAll: false, intervalMs: 20, timeoutMs: 100 },
      async <T>(path: string): Promise<T> => {
        if (path.endsWith("/dialogs")) return { dialogs: [] } as T;
        polls += 1;
        return {
          session: { status: "busy", messageCount: polls },
          events:
            polls === 1
              ? []
              : [
                  { type: "agent_start" },
                  { type: "tool_start" },
                  { type: "message_end", role: "assistant", content: "  completed work  " },
                ],
          currentSeq: polls,
        } as T;
      },
      emit,
    );

    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(20);
    await expect(promise).resolves.toMatchObject({ kind: "session", reason: "change" });
    expect(emit).toHaveBeenCalledWith(
      expect.objectContaining({ toolsThisTurn: 1, last: "completed work", messageCount: 2 }),
    );
  });

  it("polls dialogs for attention and resolves all sessions together", async () => {
    const calls: string[] = [];
    const outcome = await runSessionWatch(
      ["one", "two"],
      { condition: "attention", requireAll: true, intervalMs: 10, timeoutMs: 100 },
      async <T>(path: string): Promise<T> => {
        calls.push(path);
        if (path.endsWith("/events?since=0")) {
          return { session: { status: "busy" }, events: [], currentSeq: 1 } as T;
        }
        return { dialogs: [{}] } as T;
      },
      vi.fn(),
    );

    expect(outcome).toEqual({
      kind: "all",
      condition: "attention",
      sessions: [
        { sessionId: "one", status: "busy", pendingDialogs: 1 },
        { sessionId: "two", status: "busy", pendingDialogs: 1 },
      ],
    });
    expect(calls).toEqual([
      "/sessions/one/events?since=0",
      "/sessions/one/dialogs",
      "/sessions/two/events?since=0",
      "/sessions/two/dialogs",
    ]);
  });

  it("falls back to a session snapshot when the events route is unavailable", async () => {
    const paths: string[] = [];
    const outcome = await runSessionWatch(
      ["s"],
      { condition: "idle", requireAll: false, intervalMs: 10, timeoutMs: 100 },
      async <T>(path: string): Promise<T> => {
        paths.push(path);
        if (path.includes("/events")) throw errorWithStatus("missing", 404);
        return { session: { status: "stopped", messageCount: 9, lastMessage: "snapshot" } } as T;
      },
      vi.fn(),
    );

    expect(outcome).toMatchObject({ kind: "session", reason: "idle", status: "stopped" });
    expect(paths).toEqual(["/sessions/s/events?since=0", "/sessions/s"]);
  });

  it("preserves disconnect failures instead of treating them as state", async () => {
    await expect(
      runSessionWatch(
        ["s"],
        { condition: "idle", requireAll: false, intervalMs: 10, timeoutMs: 100 },
        async () => {
          throw new Error("socket disconnected");
        },
        vi.fn(),
      ),
    ).rejects.toThrow("socket disconnected");
  });

  it("times out exactly at the deadline with only unresolved sessions", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(10_000);
    const promise = runSessionWatch(
      ["one", "two"],
      { condition: "idle", requireAll: true, intervalMs: 50, timeoutMs: 20 },
      async <T>(path: string): Promise<T> => {
        const ready = path.includes("/one/");
        return { session: { status: ready ? "ready" : "busy" }, events: [] } as T;
      },
      vi.fn(),
    );

    const rejection = expect(promise).rejects.toMatchObject({
      name: "SessionWatchTimeout",
      condition: "idle",
      pending: ["two"],
    });
    await vi.advanceTimersByTimeAsync(20);
    await rejection;
  });

  it.each([
    [{ condition: "idle", requireAll: false, intervalMs: 0, timeoutMs: 10 }, "--interval"],
    [{ condition: "idle", requireAll: false, intervalMs: 10, timeoutMs: 0 }, "--timeout"],
  ] as const)("rejects invalid timing options %#", async (options, message) => {
    await expect(
      runSessionWatch(["s"], options, async <T>() => ({}) as T, vi.fn()),
    ).rejects.toThrow(message);
  });

  it("clears a pending polling delay when the signal aborts", async () => {
    vi.useFakeTimers();
    const controller = new AbortController();
    const promise = sleepWithSignal(60_000, controller.signal);

    expect(vi.getTimerCount()).toBe(1);
    controller.abort();

    await expect(promise).rejects.toMatchObject({ name: "AbortError" });
    expect(vi.getTimerCount()).toBe(0);
  });

  it("emits compact wait summaries on a timer, not a transition stream", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(0);
    const summaries = vi.fn();
    const promise = runSessionWatch(
      ["a", "b"],
      {
        condition: "idle",
        requireAll: true,
        intervalMs: 10,
        timeoutMs: 80,
        summaryEveryMs: 25,
        onSummary: summaries,
      },
      async <T>(path: string): Promise<T> => {
        const id = path.includes("/sessions/a/") ? "a" : "b";
        return {
          session: { status: "busy" },
          events: id === "a" ? [{ type: "tool_start" }] : [],
          currentSeq: 1,
        } as T;
      },
      vi.fn(),
    );
    const settled = promise.then(
      (value) => ({ status: "resolved" as const, value }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );

    await vi.advanceTimersByTimeAsync(0);
    expect(summaries).not.toHaveBeenCalled();
    await vi.advanceTimersByTimeAsync(30);
    await vi.advanceTimersByTimeAsync(30);
    await vi.advanceTimersByTimeAsync(20);
    const result = await settled;
    expect(result.status).toBe("rejected");
    expect(result.status === "rejected" && result.error).toMatchObject({
      message: expect.stringContaining("Timed out"),
    });
    expect(summaries.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(summaries.mock.calls.length).toBeLessThan(6);
    expect(summaries.mock.calls[0]?.[0]).toMatchObject({
      sessions: [{ sessionId: "a", status: "busy" }, { sessionId: "b", status: "busy" }],
    });
  });

  it("skips wait summaries when summaryEveryMs is 0", async () => {
    vi.useFakeTimers();
    const summaries = vi.fn();
    const promise = runSessionWatch(
      ["s"],
      {
        condition: "idle",
        requireAll: false,
        intervalMs: 10,
        timeoutMs: 30,
        summaryEveryMs: 0,
        onSummary: summaries,
      },
      async <T>(): Promise<T> => ({ session: { status: "busy" }, events: [] }) as T,
      vi.fn(),
    );
    const settled = promise.then(
      (value) => ({ status: "resolved" as const, value }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );

    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(30);
    const result = await settled;
    expect(result.status).toBe("rejected");
    expect(summaries).not.toHaveBeenCalled();
  });

  it("formats a live wait card with name, deep link, status, tools, and last snippet", () => {
    expect(
      formatWaitLiveSnapshot("either", {
        ts: 1,
        elapsedMs: 2_000,
        sessions: [
          {
            sessionId: "5c6965d2-591a-4f6c-9676-f7fa400cf370",
            name: "impl-detached-timeline-follow-20260819",
            status: "busy",
            toolsThisTurn: 3,
            last: "Good, it's busy and already working...",
          },
        ],
      }),
    ).toBe(
      [
        "Waiting for either",
        "",
        "impl\\-detached\\-timeline\\-follow\\-20260819",
        "[Open session](oppi://session/5c6965d2-591a-4f6c-9676-f7fa400cf370)",
        "status=busy  tools=3",
        "",
        "Last:",
        "Good, it's busy and already working\\.\\.\\.",
      ].join("\n"),
    );
  });

  it("escapes markdown and bounds untrusted live card text", () => {
    const name = `# [session](javascript:bad) *bold* ${"x".repeat(200)}`;
    const last = `**restyle** [untrusted](https://bad.example) ${"x".repeat(400)}`;
    const rendered = formatWaitLiveSnapshot("either", {
      ts: 1,
      elapsedMs: 2_000,
      sessions: [{ sessionId: "special", name, status: "busy", toolsThisTurn: 1, last }],
    });

    expect(rendered).toContain("\\# \\[session\\]\\(javascript\\:bad\\) \\*bold\\*");
    expect(rendered).toContain("[Open session](oppi://session/special)");
    expect(rendered).toContain(
      "Last:\n\\*\\*restyle\\*\\* \\[untrusted\\]\\(https\\://bad\\.example\\)",
    );
    expect(rendered.split("\n")[2]).toMatch(/…$/);
    expect(rendered.split("\n")[7]).toMatch(/…$/);
    expect(rendered).not.toContain("**restyle**");
    expect(rendered).not.toContain("[session](javascript:bad)");
  });

  it("emits a live snapshot after the first incomplete poll", async () => {
    vi.useFakeTimers();
    const live = vi.fn();
    const summaries = vi.fn();
    const promise = runSessionWatch(
      ["5c6965d2-591a-4f6c-9676-f7fa400cf370"],
      {
        condition: "either",
        requireAll: false,
        intervalMs: 20,
        timeoutMs: 80,
        summaryEveryMs: 60_000,
        onSummary: summaries,
        onLiveSnapshot: live,
      },
      async <T>(path: string): Promise<T> => {
        if (path.endsWith("/dialogs")) return { dialogs: [] } as T;
        return {
          session: {
            status: "busy",
            name: "impl-detached-timeline-follow-20260819",
            lastMessage: "Good, it's busy and already working...",
          },
          events: [{ type: "tool_start" }, { type: "tool_start" }, { type: "tool_start" }],
          currentSeq: 1,
        } as T;
      },
      vi.fn(),
    );
    const settled = promise.then(
      (value) => ({ status: "resolved" as const, value }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );

    await vi.advanceTimersByTimeAsync(0);
    expect(summaries).not.toHaveBeenCalled();
    expect(live).toHaveBeenCalledTimes(1);
    expect(live.mock.calls[0]?.[0]).toContain("Waiting for either");
    expect(live.mock.calls[0]?.[0]).toContain("impl\\-detached\\-timeline\\-follow\\-20260819");
    expect(live.mock.calls[0]?.[0]).toContain(
      "oppi://session/5c6965d2-591a-4f6c-9676-f7fa400cf370",
    );
    expect(live.mock.calls[0]?.[0]).toContain("status=busy  tools=3");
    expect(live.mock.calls[0]?.[0]).toContain("Good, it's busy and already working\\.\\.\\.");

    await vi.advanceTimersByTimeAsync(80);
    const result = await settled;
    expect(result.status).toBe("rejected");
    expect(live).toHaveBeenCalledTimes(1);
  });

  it("does not emit a live snapshot when the baseline is already idle", async () => {
    const live = vi.fn();
    await runSessionWatch(
      ["s"],
      {
        condition: "idle",
        requireAll: false,
        intervalMs: 10,
        timeoutMs: 100,
        onLiveSnapshot: live,
      },
      async <T>(): Promise<T> =>
        ({ session: { status: "ready", name: "done-child" }, events: [], currentSeq: 1 }) as T,
      vi.fn(),
    );

    expect(live).not.toHaveBeenCalled();
  });

  it("replaces the live snapshot on 60s summaries", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(0);
    const live = vi.fn();
    const summaries = vi.fn();
    const promise = runSessionWatch(
      ["s"],
      {
        condition: "idle",
        requireAll: false,
        intervalMs: 10,
        timeoutMs: 80,
        summaryEveryMs: 25,
        onSummary: summaries,
        onLiveSnapshot: live,
      },
      async <T>(): Promise<T> => ({ session: { status: "busy", name: "child" }, events: [] }) as T,
      vi.fn(),
    );
    const settled = promise.then(
      (value) => ({ status: "resolved" as const, value }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );

    await vi.advanceTimersByTimeAsync(0);
    expect(live).toHaveBeenCalledTimes(1);
    expect(summaries).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(30);
    await vi.advanceTimersByTimeAsync(30);
    await vi.advanceTimersByTimeAsync(20);
    const result = await settled;
    expect(result.status).toBe("rejected");
    expect(summaries.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(live.mock.calls.length).toBe(1 + summaries.mock.calls.length);
  });

  it("still emits the initial live snapshot when summaryEveryMs is 0", async () => {
    vi.useFakeTimers();
    const live = vi.fn();
    const summaries = vi.fn();
    const promise = runSessionWatch(
      ["s"],
      {
        condition: "idle",
        requireAll: false,
        intervalMs: 10,
        timeoutMs: 30,
        summaryEveryMs: 0,
        onSummary: summaries,
        onLiveSnapshot: live,
      },
      async <T>(): Promise<T> => ({ session: { status: "busy" }, events: [] }) as T,
      vi.fn(),
    );
    const settled = promise.then(
      (value) => ({ status: "resolved" as const, value }),
      (error: unknown) => ({ status: "rejected" as const, error }),
    );

    await vi.advanceTimersByTimeAsync(0);
    expect(live).toHaveBeenCalledTimes(1);
    expect(live.mock.calls[0]?.[0]).toContain("Waiting for idle");
    expect(summaries).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(30);
    const result = await settled;
    expect(result.status).toBe("rejected");
    expect(live).toHaveBeenCalledTimes(1);
    expect(summaries).not.toHaveBeenCalled();
  });
});
