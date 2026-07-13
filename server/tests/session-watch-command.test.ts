import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import {
  parseWatchCondition,
  runSessionWatch,
  watchSessions,
} from "../src/cli/commands/session-watch.js";
import type { LocalApiRequestOptions } from "../src/cli/local-api-client.js";

type ApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

function errorWithStatus(message: string, status: number): Error & { status: number } {
  return Object.assign(new Error(message), { status });
}

describe("session watch command contract", () => {
  beforeEach(() => {
    process.exitCode = undefined;
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    process.exitCode = undefined;
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

    expect(outcome).toEqual({ kind: "session", sessionId: "s/1", reason: "idle", status: "ready" });
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

  it("writes one parseable JSON error and sets a nonzero exit code on disconnect", async () => {
    const write = vi.spyOn(process.stdout, "write").mockImplementation(() => true);

    await watchSessions(["s"], { timeout: "1s" }, true, async () => {
      throw errorWithStatus("connection lost", 503);
    });

    expect(process.exitCode).toBe(1);
    expect(write).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(write.mock.calls[0]?.[0]))).toEqual({
      event: "error",
      message: "connection lost",
      status: 503,
    });
  });

  it("writes a timeout record and nonzero exit at the command boundary", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(0);
    const write = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const promise = watchSessions(
      ["s"],
      { interval: "10ms", timeout: "10ms", until: "idle" },
      true,
      async <T>(): Promise<T> => ({ session: { status: "busy" }, events: [] }) as T,
    );

    await vi.advanceTimersByTimeAsync(10);
    await promise;

    expect(process.exitCode).toBe(1);
    expect(JSON.parse(String(write.mock.calls[0]?.[0]))).toEqual({
      event: "timeout",
      condition: "idle",
      pending: ["s"],
    });
  });

  it("emits human output without asserting incidental timestamps", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    await watchSessions(["s"], {}, false, async <T>(): Promise<T> => {
      return { session: { status: "error", lastMessage: "failed\nnow" }, events: [] } as T;
    });

    expect(log).toHaveBeenCalledTimes(1);
    expect(String(log.mock.calls[0]?.[0])).toMatch(
      /s status=error reason=idle tools=0 last='failed now'/,
    );
  });

  it.each([
    [[], {}, "at least one session id"],
    [["s", "s"], {}, "session ids must be unique"],
    [["s"], { until: "either" }, "--until must be idle"],
  ] as const)("rejects conflicting watch inputs %#", async (ids, flags, message) => {
    await expect(watchSessions([...ids], flags, true, async <T>() => ({}) as T)).rejects.toThrow(
      message,
    );
  });
});
