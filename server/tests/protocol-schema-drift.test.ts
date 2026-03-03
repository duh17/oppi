/**
 * Protocol schema drift tests — RQ-PROTO-002.
 */

import { describe, expect, it } from "vitest";
import type { ClientMessage, ServerMessage, Session } from "../src/types.js";

function minimalSession(): Session {
  const now = Date.now();
  return {
    id: "s1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function roundTrip<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

function withExtraFields<T extends object>(value: T, extras: Record<string, unknown>): T {
  return { ...value, ...extras };
}

function expectUndefinedKeys<T extends object>(value: T, keys: Array<keyof T>): void {
  for (const key of keys) {
    expect(value[key]).toBeUndefined();
  }
}

describe("RQ-PROTO-002: ServerMessage schema drift", () => {
  describe("extra fields are tolerated (forward compat)", () => {
    it("connected with unknown session fields survives round-trip", () => {
      const parsed = roundTrip<ServerMessage>({
        type: "connected",
        session: withExtraFields(minimalSession(), {
          futureField: "unknown-value",
          nestedFuture: { x: 1 },
        }),
        currentSeq: 5,
      }) as Extract<ServerMessage, { type: "connected" }> & {
        session: Session & Record<string, unknown>;
      };

      expect(parsed.type).toBe("connected");
      expect(parsed.session.id).toBe("s1");
      expect(parsed.session.futureField).toBe("unknown-value");
    });

    it("state with unknown top-level fields", () => {
      const parsed = roundTrip(
        withExtraFields(
          { type: "state" as const, session: minimalSession() },
          { serverVersion: "99.0.0", experimental: true },
        ),
      ) as Record<string, unknown>;

      expect(parsed.type).toBe("state");
      expect(parsed.serverVersion).toBe("99.0.0");
    });

    it("tool_start with unknown args keys", () => {
      const parsed = roundTrip<ServerMessage>({
        type: "tool_start",
        tool: "bash",
        args: { command: "echo hi", futureArg: [1, 2, 3] },
        toolCallId: "tc-1",
      }) as Extract<ServerMessage, { type: "tool_start" }> & {
        args: Record<string, unknown>;
      };

      expect(parsed.type).toBe("tool_start");
      expect(parsed.args.futureArg).toEqual([1, 2, 3]);
    });

    it("permission_request with extra security fields", () => {
      const parsed = roundTrip(
        withExtraFields(
          {
            type: "permission_request" as const,
            id: "p1",
            sessionId: "s1",
            tool: "bash",
            input: { command: "rm -rf /" },
            displaySummary: "Run: rm -rf /",
            reason: "destructive",
            timeoutAt: Date.now() + 30000,
            expires: true,
          },
          { riskScore: 0.95, policyVersion: 3 },
        ),
      ) as Record<string, unknown>;

      expect(parsed.type).toBe("permission_request");
      expect(parsed.riskScore).toBe(0.95);
    });

    it("command_result with unknown data shape", () => {
      const parsed = roundTrip<ServerMessage>({
        type: "command_result",
        command: "future_command",
        requestId: "req-1",
        success: true,
        data: { unknown: { deeply: { nested: true } } },
      }) as Extract<ServerMessage, { type: "command_result" }>;

      expect(parsed.data).toEqual({ unknown: { deeply: { nested: true } } });
    });
  });

  describe("missing optional fields", () => {
    it("session without optional fields parses cleanly", () => {
      const connected = roundTrip<ServerMessage>({
        type: "connected",
        session: minimalSession(),
      }) as Extract<ServerMessage, { type: "connected" }>;

      expect(connected.session.id).toBe("s1");
      expectUndefinedKeys(connected.session, [
        "workspaceId",
        "name",
        "model",
        "changeStats",
        "contextTokens",
        "contextWindow",
        "thinkingLevel",
        "piSessionFile",
        "warnings",
      ]);
    });

    it("tool_start and tool_end omit optional payload fields", () => {
      const start = roundTrip<ServerMessage>({
        type: "tool_start",
        tool: "read",
        args: { path: "file.ts" },
      }) as Extract<ServerMessage, { type: "tool_start" }>;
      const end = roundTrip<ServerMessage>({ type: "tool_end", tool: "bash" }) as Extract<
        ServerMessage,
        { type: "tool_end" }
      >;

      expect(start.callSegments).toBeUndefined();
      expect(start.toolCallId).toBeUndefined();
      expect(end.resultSegments).toBeUndefined();
      expect(end.details).toBeUndefined();
      expect(end.isError).toBeUndefined();
    });

    it("error/stop_requested omit optional fields", () => {
      const error = roundTrip<ServerMessage>({
        type: "error",
        error: "Something went wrong",
      }) as Extract<ServerMessage, { type: "error" }>;
      const stop = roundTrip<ServerMessage>({
        type: "stop_requested",
        source: "server",
      }) as Extract<ServerMessage, { type: "stop_requested" }>;

      expect(error.code).toBeUndefined();
      expect(error.fatal).toBeUndefined();
      expect(stop.reason).toBeUndefined();
    });
  });

  describe("type discriminator stability", () => {
    it("every ServerMessage type round-trips to same discriminator", () => {
      const messages: ServerMessage[] = [
        { type: "connected", session: minimalSession() },
        { type: "stream_connected", userName: "test" },
        { type: "state", session: minimalSession() },
        { type: "session_ended", reason: "done" },
        { type: "session_deleted", sessionId: "s1" },
        { type: "stop_requested", source: "user" },
        { type: "stop_confirmed", source: "user" },
        { type: "stop_failed", source: "user", reason: "timeout" },
        { type: "error", error: "bad" },
        { type: "agent_start" },
        { type: "agent_end" },
        { type: "message_end", role: "assistant", content: "done" },
        { type: "text_delta", delta: "hi" },
        { type: "thinking_delta", delta: "hmm" },
        { type: "tool_start", tool: "bash", args: {} },
        { type: "tool_output", output: "ok" },
        { type: "tool_end", tool: "bash" },
        { type: "turn_ack", command: "prompt", clientTurnId: "t1", stage: "accepted" },
        { type: "command_result", command: "get_state", success: true },
        { type: "compaction_start", reason: "full" },
        { type: "compaction_end", aborted: false, willRetry: false },
        {
          type: "retry_start",
          attempt: 1,
          maxAttempts: 3,
          delayMs: 1000,
          errorMessage: "err",
        },
        { type: "retry_end", success: true, attempt: 1 },
        {
          type: "permission_request",
          id: "p1",
          sessionId: "s1",
          tool: "bash",
          input: {},
          displaySummary: "run",
          reason: "ask",
          timeoutAt: Date.now(),
        },
        { type: "permission_expired", id: "p1", reason: "timeout" },
        { type: "permission_cancelled", id: "p1" },
        { type: "extension_ui_request", id: "u1", sessionId: "s1", method: "select" },
        { type: "extension_ui_notification", method: "notify" },
        {
          type: "git_status",
          workspaceId: "w1",
          status: {
            isGitRepo: true,
            branch: "main",
            headSha: "abc",
            ahead: 0,
            behind: 0,
            dirtyCount: 0,
            untrackedCount: 0,
            stagedCount: 0,
            files: [],
            totalFiles: 0,
            addedLines: 0,
            removedLines: 0,
            stashCount: 0,
            lastCommitMessage: null,
            lastCommitDate: null,
          },
        },
        { type: "queue_state", queue: { version: 0, steering: [], followUp: [] } },
        {
          type: "queue_item_started",
          kind: "steer",
          item: { id: "qi1", message: "hi", createdAt: Date.now() },
          queueVersion: 1,
        },
      ];

      for (const message of messages) {
        expect(roundTrip(message).type).toBe(message.type);
      }
    });
  });

  describe("session changeStats schema evolution", () => {
    it("session without changeStats (pre-v2 server)", () => {
      expect(roundTrip(minimalSession()).changeStats).toBeUndefined();
    });

    it("session with partial + future changeStats fields", () => {
      const parsed = roundTrip({
        ...minimalSession(),
        changeStats: {
          mutatingToolCalls: 5,
          filesChanged: 2,
          changedFiles: ["a.ts"],
          addedLines: 10,
          removedLines: 3,
          futureMetric: 42,
        },
      });

      expect(parsed.changeStats?.mutatingToolCalls).toBe(5);
      expect((parsed.changeStats as Record<string, unknown>).futureMetric).toBe(42);
    });
  });
});

describe("RQ-PROTO-002: ClientMessage schema drift", () => {
  it("prompt with extra fields round-trips", () => {
    const parsed = roundTrip(
      withExtraFields<ClientMessage>(
        {
          type: "prompt",
          message: "hello",
          sessionId: "s1",
          requestId: "r1",
        },
        { priority: "high", metadata: { source: "voice" } },
      ),
    );

    expect(parsed.type).toBe("prompt");
    expect(parsed.message).toBe("hello");
  });

  it("permission_response with extra fields round-trips", () => {
    const parsed = roundTrip(
      withExtraFields<ClientMessage>(
        {
          type: "permission_response",
          id: "p1",
          action: "allow",
          scope: "session",
        },
        { approvedBy: "user", confidence: 0.9 },
      ),
    ) as Record<string, unknown>;

    expect(parsed.type).toBe("permission_response");
    expect(parsed.approvedBy).toBe("user");
  });

  it("subscribe with future level values preserved as string", () => {
    const parsed = roundTrip({
      type: "subscribe" as const,
      sessionId: "s1",
      level: "background" as "full" | "notifications",
    });

    expect(parsed.level).toBe("background");
  });

  it("set_queue with extra item fields", () => {
    const msg: ClientMessage = {
      type: "set_queue",
      baseVersion: 1,
      steering: [{ message: "do X", images: [] }],
      followUp: [],
    };

    const parsed = roundTrip({
      ...msg,
      steering: [{ ...msg.steering[0], priority: 1, tags: ["urgent"] }],
    });

    expect((parsed.steering[0] as Record<string, unknown>).priority).toBe(1);
  });
});

describe("RQ-PROTO-002: cross-platform invariants", () => {
  it("Session.tokens always has input and output", () => {
    const parsed = roundTrip(minimalSession());
    expect(parsed.tokens).toMatchObject({ input: expect.any(Number), output: expect.any(Number) });
  });

  it("connected/state always include a session", () => {
    const connected = roundTrip<ServerMessage>({ type: "connected", session: minimalSession() });
    const state = roundTrip<ServerMessage>({ type: "state", session: minimalSession() });

    expect((connected as { session: Session }).session.id).toBeTypeOf("string");
    expect((state as { session: Session }).session).toBeDefined();
  });

  it("permission_request required fields are present", () => {
    const parsed = roundTrip<ServerMessage>({
      type: "permission_request",
      id: "p1",
      sessionId: "s1",
      tool: "bash",
      input: { command: "echo" },
      displaySummary: "Run: echo",
      reason: "needs approval",
      timeoutAt: Date.now() + 30000,
    }) as Extract<ServerMessage, { type: "permission_request" }>;

    expect(parsed).toMatchObject({
      id: expect.any(String),
      sessionId: expect.any(String),
      tool: expect.any(String),
      input: expect.any(Object),
      displaySummary: expect.any(String),
      reason: expect.any(String),
      timeoutAt: expect.any(Number),
    });
  });

  it("turn_ack required fields are present and stage is recognized", () => {
    const parsed = roundTrip<ServerMessage>({
      type: "turn_ack",
      command: "prompt",
      clientTurnId: "t1",
      stage: "dispatched",
    }) as Extract<ServerMessage, { type: "turn_ack" }>;

    expect(parsed.command).toBeTypeOf("string");
    expect(parsed.clientTurnId).toBeTypeOf("string");
    expect(["accepted", "dispatched", "started"]).toContain(parsed.stage);
  });
});
