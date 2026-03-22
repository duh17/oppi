/**
 * Permission routing tests — RQ-PERM-002.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AuditLog } from "../src/audit.js";
import { GateServer, buildPermissionMessage, type PendingDecision } from "../src/gate.js";
import { LiveActivityBridge } from "../src/live-activity.js";
import { PolicyEngine, defaultPresetRules } from "../src/policy.js";
import type { PushClient } from "../src/push.js";
import { RuleStore } from "../src/rules.js";
import type { SessionBroadcastEvent } from "../src/sessions.js";
import type { Storage } from "../src/storage.js";
import type { ServerMessage, Session } from "../src/types.js";

let testDir: string;

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), "oppi-perm-routing-"));
});

afterEach(() => {
  rmSync(testDir, { recursive: true, force: true });
});

function createGate(approvalTimeoutMs?: number): GateServer {
  const policy = new PolicyEngine("host");
  const ruleStore = new RuleStore(join(testDir, "rules.json"));
  ruleStore.seedIfEmpty(defaultPresetRules());
  const auditLog = new AuditLog(join(testDir, "audit.jsonl"));
  return new GateServer(policy, ruleStore, auditLog, { approvalTimeoutMs });
}

function makeSession(id: string, overrides?: Partial<Session>): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
    ...overrides,
  };
}

function makePush(): PushClient {
  return {
    sendPermissionPush: vi.fn(async () => true),
    sendSessionEventPush: vi.fn(async () => true),
    sendLiveActivityUpdate: vi.fn(async () => true),
    endLiveActivity: vi.fn(async () => true),
    shutdown: vi.fn(),
  } as unknown as PushClient;
}

function makeDangerousBashCall(sessionId: string, command: string, toolCallId: string) {
  return {
    sessionId,
    tool: "bash",
    input: { command },
    toolCallId,
  };
}

async function waitForPendingCount(list: PendingDecision[], count: number): Promise<void> {
  const deadline = Date.now() + 1000;
  while (list.length < count && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  expect(list).toHaveLength(count);
}

function findPendingBySession(pending: PendingDecision[], sessionId: string): PendingDecision {
  const match = pending.find((decision) => decision.sessionId === sessionId);
  expect(match).toBeDefined();
  if (!match) {
    throw new Error(`Missing pending decision for session ${sessionId}`);
  }
  return match;
}

function makePending(overrides?: Partial<PendingDecision>): PendingDecision {
  return {
    id: "p1",
    sessionId: "target-session",
    workspaceId: "w1",
    tool: "bash",
    input: { command: "rm -rf /" },
    toolCallId: "tc-1",
    displaySummary: "Run: rm -rf /",
    reason: "destructive",
    createdAt: Date.now(),
    timeoutAt: Date.now() + 30000,
    expires: true,
    resolve: () => {},
    ...overrides,
  };
}

describe("RQ-PERM-002: checkToolCall creates session-scoped pending", () => {
  it("pending decision from checkToolCall carries correct sessionId", async () => {
    const gate = createGate(0);
    try {
      gate.createGuard("session-target", "w1");

      const pending: PendingDecision[] = [];
      gate.on("approval_needed", (decision: PendingDecision) => {
        pending.push(decision);
        gate.resolveDecision(decision.id, "allow");
      });

      await gate.checkToolCall(
        "session-target",
        makeDangerousBashCall("session-target", "git push --force origin main", "tc-1"),
      );

      expect(pending).toHaveLength(1);
      expect(pending[0].sessionId).toBe("session-target");
    } finally {
      await gate.shutdown();
    }
  });

  it("multiple sessions create independent pending decisions", async () => {
    const gate = createGate(0);
    try {
      gate.createGuard("session-a", "w1");
      gate.createGuard("session-b", "w2");

      const pending: PendingDecision[] = [];
      gate.on("approval_needed", (decision: PendingDecision) => pending.push(decision));

      const promiseA = gate.checkToolCall(
        "session-a",
        makeDangerousBashCall("session-a", "git push --force origin main", "tc-a"),
      );
      const promiseB = gate.checkToolCall(
        "session-b",
        makeDangerousBashCall("session-b", "git push --force origin dev", "tc-b"),
      );

      await waitForPendingCount(pending, 2);
      expect(new Set(pending.map((decision) => decision.sessionId))).toEqual(
        new Set(["session-a", "session-b"]),
      );
      expect(gate.getPendingForUser()).toHaveLength(2);

      for (const decision of pending) {
        gate.resolveDecision(decision.id, "allow");
      }
      await Promise.all([promiseA, promiseB]);
    } finally {
      await gate.shutdown();
    }
  });

  it("resolving one session does not affect another session's pending", async () => {
    const gate = createGate(0);
    try {
      gate.createGuard("sa", "w1");
      gate.createGuard("sb", "w1");

      const pending: PendingDecision[] = [];
      gate.on("approval_needed", (decision: PendingDecision) => pending.push(decision));

      const promiseA = gate.checkToolCall(
        "sa",
        makeDangerousBashCall("sa", "git push --force origin main", "tc-a"),
      );
      const promiseB = gate.checkToolCall(
        "sb",
        makeDangerousBashCall("sb", "git push --force origin dev", "tc-b"),
      );

      await waitForPendingCount(pending, 2);

      const sa = findPendingBySession(pending, "sa");
      const sb = findPendingBySession(pending, "sb");

      gate.resolveDecision(sa.id, "allow");
      await promiseA;

      const remaining = gate.getPendingForUser();
      expect(remaining).toHaveLength(1);
      expect(remaining[0].sessionId).toBe("sb");

      gate.resolveDecision(sb.id, "deny");
      await promiseB;
    } finally {
      await gate.shutdown();
    }
  });

  it("resolving nonexistent ID returns false", () => {
    const gate = createGate();
    expect(gate.resolveDecision("nonexistent-id", "allow")).toBe(false);
  });
});

describe("RQ-PERM-002: buildPermissionMessage session context", () => {
  it("permission payload mirrors pending decision fields", () => {
    const message = buildPermissionMessage(makePending()) as Extract<
      ServerMessage,
      { type: "permission_request" }
    >;

    expect(message).toMatchObject({
      type: "permission_request",
      id: "p1",
      sessionId: "target-session",
      tool: "bash",
      displaySummary: "Run: rm -rf /",
      reason: "destructive",
      timeoutAt: expect.any(Number),
    });
  });

  it("non-bash tools preserve full input context", () => {
    const message = buildPermissionMessage(
      makePending({
        id: "p2",
        sessionId: "edit-session",
        workspaceId: "w2",
        tool: "edit",
        input: { path: "secret.env", oldText: "KEY=old", newText: "KEY=new" },
        toolCallId: "tc-edit",
        displaySummary: "Edit: secret.env",
        reason: "modifying sensitive file",
      }),
    ) as Extract<ServerMessage, { type: "permission_request" }>;

    expect(message.tool).toBe("edit");
    expect(message.sessionId).toBe("edit-session");
    expect(message.input).toEqual({
      path: "secret.env",
      oldText: "KEY=old",
      newText: "KEY=new",
    });
  });
});

describe("RQ-PERM-002: pending permission filtering and cleanup", () => {
  it("getPendingForUser returns decisions from all sessions", async () => {
    const gate = createGate(0);
    try {
      gate.createGuard("s1", "w1");
      gate.createGuard("s2", "w2");

      const pending: PendingDecision[] = [];
      gate.on("approval_needed", (decision: PendingDecision) => pending.push(decision));

      const p1 = gate.checkToolCall(
        "s1",
        makeDangerousBashCall("s1", "git push --force origin main", "tc-1"),
      );
      const p2 = gate.checkToolCall(
        "s2",
        makeDangerousBashCall("s2", "git push --force origin dev", "tc-2"),
      );

      await waitForPendingCount(pending, 2);

      const all = gate.getPendingForUser();
      expect(all.filter((decision) => decision.sessionId === "s1")).toHaveLength(1);
      expect(all.filter((decision) => decision.sessionId === "s2")).toHaveLength(1);

      for (const decision of pending) {
        gate.resolveDecision(decision.id, "deny");
      }
      await Promise.allSettled([p1, p2]);
    } finally {
      await gate.shutdown();
    }
  });

  it("destroySessionGuard cleans up only that session pending", async () => {
    const gate = createGate(0);
    try {
      gate.createGuard("s1", "w1");
      gate.createGuard("s2", "w1");

      const pending: PendingDecision[] = [];
      const cancelled: Array<{ requestId: string; sessionId: string; reason: string }> = [];
      gate.on("approval_needed", (decision: PendingDecision) => pending.push(decision));
      gate.on(
        "approval_cancelled",
        (event: { requestId: string; sessionId: string; reason: string }) => cancelled.push(event),
      );

      const p1 = gate.checkToolCall(
        "s1",
        makeDangerousBashCall("s1", "git push --force origin main", "tc-1"),
      );
      const p2 = gate.checkToolCall(
        "s2",
        makeDangerousBashCall("s2", "git push --force origin dev", "tc-2"),
      );

      await waitForPendingCount(pending, 2);
      const s1Pending = findPendingBySession(pending, "s1");

      gate.destroySessionGuard("s1");
      await expect(p1).resolves.toEqual({ action: "deny", reason: "Session ended" });

      const remaining = gate.getPendingForUser();
      expect(remaining).toHaveLength(1);
      expect(remaining[0].sessionId).toBe("s2");
      expect(cancelled).toEqual([
        {
          requestId: s1Pending.id,
          sessionId: "s1",
          reason: "Session ended",
        },
      ]);

      gate.resolveDecision(remaining[0].id, "deny");
      await p2;
    } finally {
      await gate.shutdown();
    }
  });
});

describe("RQ-PERM-002: Live Activity session event routing", () => {
  function makeBridgeStorage(): Storage {
    return {
      getLiveActivityToken: vi.fn(() => "la-token"),
      setLiveActivityToken: vi.fn(),
      listSessions: vi.fn(() => [makeSession("s1", { status: "busy" })]),
    } as unknown as Storage;
  }

  function makeBridgeGate(): GateServer {
    return {
      getPendingForUser: vi.fn(() => []),
    } as unknown as GateServer;
  }

  it("state and agent_start events are accepted with session context", () => {
    const bridge = new LiveActivityBridge(makePush(), makeBridgeStorage(), makeBridgeGate());

    const stateEvent: SessionBroadcastEvent = {
      sessionId: "s1",
      event: { type: "state", session: makeSession("s1", { status: "busy" }) },
      durable: false,
    };

    const startEvent: SessionBroadcastEvent = {
      sessionId: "s1",
      event: { type: "agent_start" },
      durable: true,
    };

    expect(() => bridge.handleSessionEvent(stateEvent)).not.toThrow();
    expect(() => bridge.handleSessionEvent(startEvent)).not.toThrow();
  });
});
