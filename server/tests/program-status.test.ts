import { describe, expect, it } from "vitest";

import {
  programRunFor,
  syncProgramStatus,
  trackProgramRunEvent,
  type ProgramStatusHost,
} from "../src/program-status.js";
import type { Session } from "../src/types.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "s1",
    name: "Fix login",
    status: "ready",
    createdAt: 1_000,
    lastActivity: 1_000,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeHost(
  session: Session,
  requests: Array<Record<string, unknown>> = [],
): ProgramStatusHost {
  return {
    session,
    pendingUIRequests: new Map(
      requests.map((req, index) => [
        String(index),
        { type: "extension_ui_request", ...req } as never,
      ]),
    ),
  };
}

function status(host: ProgramStatusHost, now = 5_000) {
  syncProgramStatus(host, now);
  const { since: _since, ...rest } = host.session.programStatus!;
  return rest;
}

function feed(host: ProgramStatusHost, ...events: Array<Record<string, unknown>>) {
  const run = programRunFor(host);
  for (const event of events) {
    trackProgramRunEvent(run, event as never);
  }
}

const assistantEnd = (stopReason: string, errorMessage?: string) => ({
  type: "message_end",
  message: { role: "assistant", stopReason, ...(errorMessage ? { errorMessage } : {}) },
});

describe("program status derivation", () => {
  it.each(["starting", "busy"] as const)("%s is working with the session name", (lifecycle) => {
    expect(status(makeHost(makeSession({ status: lifecycle })))).toEqual({
      state: "working",
      message: "Fix login",
    });
  });

  it("stopping with an active turn is working; without one it falls through to the outcome", () => {
    const active = makeSession({ status: "stopping", currentTurnStartedAt: 10 });
    expect(status(makeHost(active)).state).toBe("working");
    expect(status(makeHost(makeSession({ status: "stopping" }))).state).toBe("idle");
  });

  it("a stop between agent_end and agent_settled is still working, not the previous outcome", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"), { type: "agent_settled" });
    feed(host, { type: "agent_start" });
    // Stop requested, then agent_end cleared the turn marker; the run has not settled yet.
    host.session.status = "stopping";
    host.session.currentTurnStartedAt = undefined;
    expect(status(host).state).toBe("working");

    feed(host, { type: "agent_settled", aborted: true });
    expect(status(host).state).toBe("idle");
  });

  it("a run the lifecycle calls settled ends with its own result, not the previous run's", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"), { type: "agent_settled" });
    feed(host, { type: "agent_start" }, assistantEnd("error", "overloaded"));
    host.session.status = "ready"; // a mirrored TUI reported idle before agent_settled arrived
    expect(status(host)).toEqual({ state: "error", message: "overloaded" });
  });

  it("compaction is working with a fixed message", () => {
    const host = makeHost(makeSession());
    feed(host, { type: "compaction_start", reason: "threshold" });
    expect(status(host)).toEqual({ state: "working", message: "Compacting context" });
  });

  it("confirm blocks as permission with the dialog title", () => {
    const host = makeHost(makeSession({ status: "busy" }), [
      { method: "confirm", title: "Allow rm -rf?" },
    ]);
    expect(status(host)).toEqual({
      state: "blocked",
      kind: "permission",
      message: "Allow rm -rf?",
    });
  });

  it.each([
    ["select", { method: "select", title: "Pick one", options: ["a", "b"] }, "Pick one"],
    ["input", { method: "input", title: "Your name" }, "Your name"],
    ["editor", { method: "editor", title: "Edit the plan" }, "Edit the plan"],
    [
      "ask",
      {
        method: "ask",
        title: "ignored",
        questions: [{ id: "q", question: "Which database?", options: [] }],
      },
      "Which database?",
    ],
  ])("%s blocks as question", (_name, request, message) => {
    const host = makeHost(makeSession({ status: "busy" }), [request]);
    expect(status(host)).toEqual({ state: "blocked", kind: "question", message });
  });

  it("the most recent pending dialog wins", () => {
    const host = makeHost(makeSession({ status: "busy" }), [
      { method: "confirm", title: "First" },
      { method: "input", title: "Second" },
    ]);
    expect(status(host)).toMatchObject({ kind: "question", message: "Second" });
  });

  it("dialogs that need no reply do not block", () => {
    const host = makeHost(makeSession({ status: "busy" }), [
      { method: "notify", message: "hi" },
      { method: "select", title: "empty", options: [] },
    ]);
    expect(status(host).state).toBe("working");
  });

  it("a blocked dialog beats compaction and the busy turn", () => {
    const host = makeHost(makeSession({ status: "busy" }), [{ method: "confirm", title: "Ok?" }]);
    feed(host, { type: "compaction_start", reason: "manual" });
    expect(status(host).state).toBe("blocked");
  });

  it("a settled run is done with the session name", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"), {
      type: "agent_settled",
      aborted: false,
    });
    host.session.status = "ready";
    expect(status(host)).toEqual({ state: "done", message: "Fix login" });
  });

  it("an unretried assistant error settles as error with the first line only", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(
      host,
      { type: "agent_start" },
      assistantEnd("error", "429 rate limited\nsecret detail: sk-live-123"),
      { type: "agent_settled", aborted: false },
    );
    host.session.status = "ready";
    expect(status(host)).toEqual({ state: "error", message: "429 rate limited" });
  });

  it("a retry that succeeds replaces the earlier error", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(
      host,
      { type: "agent_start" },
      assistantEnd("error", "overloaded"),
      { type: "auto_retry_start", attempt: 1 },
      assistantEnd("stop"),
      { type: "agent_settled", aborted: false },
    );
    host.session.status = "ready";
    expect(status(host).state).toBe("done");
  });

  it("settled with aborted: true is idle", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"), {
      type: "agent_settled",
      aborted: true,
    });
    host.session.status = "ready";
    expect(status(host)).toEqual({ state: "idle" });
  });

  it("a mirrored settle without the aborted field counts as finished", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"), { type: "agent_settled" });
    host.session.status = "ready";
    expect(status(host).state).toBe("done");
  });

  it("a session awaiting its first prompt is idle", () => {
    expect(status(makeHost(makeSession()))).toEqual({ state: "idle" });
  });

  it("lifecycle error is error with the launch reason", () => {
    const session = makeSession({
      status: "error",
      launch: { status: "failed", requestedAt: 1, promptError: "Model unavailable\nmore" },
    });
    expect(status(makeHost(session))).toEqual({ state: "error", message: "Model unavailable" });
  });

  it("a typed launch failure is error without its machine code as the message", () => {
    const session = makeSession({
      status: "error",
      launch: {
        status: "failed",
        requestedAt: 1,
        promptError: "agent_tools_unavailable",
        failure: { code: "agent_tools_unavailable", retryable: false, details: {} },
      },
    });
    expect(status(makeHost(session))).toEqual({ state: "error" });

    session.warnings = ["Tool bash is unavailable\nmore"];
    expect(status(makeHost(session))).toEqual({
      state: "error",
      message: "Tool bash is unavailable",
    });
  });

  it("stopped retains the last outcome without kind or message", () => {
    const done = makeHost(makeSession({ status: "busy" }));
    feed(done, { type: "agent_start" }, assistantEnd("stop"), { type: "agent_settled" });
    done.session.status = "stopped";
    expect(status(done)).toEqual({ state: "done" });

    const failed = makeHost(makeSession({ status: "busy" }));
    feed(failed, { type: "agent_start" }, assistantEnd("error", "boom"), {
      type: "agent_settled",
    });
    failed.session.status = "stopped";
    expect(status(failed)).toEqual({ state: "error" });
  });

  it("stopping mid-run leaves no outcome to retain", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    feed(host, { type: "agent_start" }, assistantEnd("stop"));
    host.session.status = "stopped";
    expect(status(host)).toEqual({ state: "idle" });
  });

  it("manual compaction outside a run is a done/error outcome", () => {
    const ok = makeHost(makeSession());
    feed(ok, { type: "compaction_start", reason: "manual" });
    feed(ok, { type: "compaction_end", reason: "manual", aborted: false });
    expect(status(ok).state).toBe("done");

    const failed = makeHost(makeSession());
    feed(failed, { type: "compaction_end", reason: "manual", errorMessage: "too big" });
    expect(status(failed)).toEqual({ state: "error", message: "too big" });
  });

  it("restores the last outcome from the persisted value after a restart", () => {
    // A fresh host (new server process) for a stopped session that last finished with an error.
    const restored = makeSession({
      status: "stopped",
      programStatus: { state: "error", since: 1_234 },
    });
    expect(syncProgramStatus({ session: restored }, 9_999).current).toEqual({
      state: "error",
      since: 1_234,
    });

    // Interrupted by a crash: the persisted value was working, so there is no outcome.
    const crashed = makeSession({
      status: "stopped",
      programStatus: { state: "working", message: "Fix login", since: 1_000 },
    });
    expect(syncProgramStatus({ session: crashed }, 9_999).current).toEqual({
      state: "idle",
      since: 9_999,
    });
  });

  it("keeps `since` while state and kind are unchanged and resets it on a transition", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    syncProgramStatus(host, 100);
    syncProgramStatus(host, 200);
    expect(host.session.programStatus?.since).toBe(100);

    host.session.name = "Renamed";
    const sync = syncProgramStatus(host, 300);
    expect(sync.changed).toBe(true);
    expect(sync.current).toMatchObject({ message: "Renamed", since: 100 });

    host.session.status = "ready";
    syncProgramStatus(host, 400);
    expect(host.session.programStatus?.since).toBe(400);
  });

  it("reports unchanged on a repeat sync", () => {
    const host = makeHost(makeSession({ status: "busy" }));
    syncProgramStatus(host, 100);
    expect(syncProgramStatus(host, 200).changed).toBe(false);
  });

  it("strips control characters and caps long messages to one line", () => {
    const host = makeHost(makeSession({ status: "busy" }), [
      { method: "input", title: `Name\u001b[31m\n${"x".repeat(2000)}` },
    ]);
    const message = status(host).message!;
    expect(message).not.toMatch(/[\u0000-\u001f]/);
    expect(message.length).toBeLessThanOrEqual(512);
  });
});
