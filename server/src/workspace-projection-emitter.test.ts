import { afterEach, describe, expect, it, vi } from "vitest";
import { WorkspaceProjectionEmitter } from "./workspace-projection-emitter.js";
import type { WorkspaceStreamMux } from "./stream.js";
import type { ServerMessage, Session } from "./types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "s1",
    workspaceId: "w1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeEmitter(options?: { minIntervalMs?: number }): {
  emitter: WorkspaceProjectionEmitter;
  record: ReturnType<typeof vi.fn>;
} {
  const record = vi.fn();
  const mux = {
    recordAndFanOutWorkspaceEvent: record,
  } as unknown as WorkspaceStreamMux;
  return { emitter: new WorkspaceProjectionEmitter(mux, options), record };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("WorkspaceProjectionEmitter", () => {
  it("emits a session_projection with the cold SessionSummary shape", () => {
    const { emitter, record } = makeEmitter();
    const session = makeSession({ name: "Demo", piSessionFile: "/private.trace.jsonl" });

    expect(emitter.emitSessionProjection(session, "test")).toBe(true);

    expect(record).toHaveBeenCalledOnce();
    const [workspaceId, message] = record.mock.calls[0] as [string, ServerMessage];
    expect(workspaceId).toBe("w1");
    expect(message.type).toBe("session_projection");
    if (message.type !== "session_projection") return;
    expect(message.summary.id).toBe("s1");
    expect(message.summary.name).toBe("Demo");
    expect("piSessionFile" in message.summary).toBe(false);
  });

  it("dedupes unchanged summaries and emits after list-visible changes", () => {
    const { emitter, record } = makeEmitter();
    const session = makeSession();

    expect(emitter.emitSessionProjection(session, "first")).toBe(true);
    expect(emitter.emitSessionProjection({ ...session }, "same")).toBe(false);

    expect(record).toHaveBeenCalledTimes(1);

    expect(
      emitter.emitSessionProjection({ ...session, status: "busy", lastActivity: 2 }, "changed"),
    ).toBe(true);
    expect(record).toHaveBeenCalledTimes(2);
  });

  it("coalesces noisy projection updates per session", async () => {
    vi.useFakeTimers();
    const { emitter, record } = makeEmitter({ minIntervalMs: 100 });
    const session = makeSession({ status: "busy", contextTokens: 1_000, contextWindow: 10_000 });

    expect(emitter.emitSessionProjection(session, "agent_start")).toBe(true);
    expect(record).toHaveBeenCalledTimes(1);

    session.contextTokens = 1_500;
    expect(emitter.scheduleSessionProjection(session, "message_end")).toBe(true);
    session.contextTokens = 2_000;
    expect(emitter.scheduleSessionProjection(session, "tool_end")).toBe(true);
    expect(record).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(99);
    expect(record).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(1);
    expect(record).toHaveBeenCalledTimes(2);
    const [, message] = record.mock.calls[1] as [string, ServerMessage];
    expect(message.type).toBe("session_projection");
    if (message.type !== "session_projection") return;
    expect(message.summary.contextTokens).toBe(2_000);
  });

  it("clears dedupe state when a session is deleted", () => {
    const { emitter, record } = makeEmitter();
    const session = makeSession();

    expect(emitter.emitSessionProjection(session, "first")).toBe(true);
    emitter.emitSessionDeleted("w1", "s1");
    expect(emitter.emitSessionProjection(session, "recreated")).toBe(true);

    expect(record.mock.calls.map((call) => (call[1] as ServerMessage).type)).toEqual([
      "session_projection",
      "session_deleted",
      "session_projection",
    ]);
  });

  it("skips sessions without a workspace", () => {
    const { emitter, record } = makeEmitter();

    expect(
      emitter.emitSessionProjection(makeSession({ workspaceId: undefined }), "no-workspace"),
    ).toBe(false);
    expect(record).not.toHaveBeenCalled();
  });
});
