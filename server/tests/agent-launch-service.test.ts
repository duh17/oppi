import { describe, expect, it, vi } from "vitest";

import { AgentLaunchService, type AgentDefinition } from "../src/agent-launch-service.js";
import type { Session, Workspace } from "../src/types.js";

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Workspace",
    ...overrides,
  } as Workspace;
}

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

function makeService(options: { sessions?: Session[]; nowMs?: number } = {}) {
  const storedSessions = [...(options.sessions ?? [])];
  const createSession = vi.fn((name?: string, model?: string) => {
    const session = makeSession({ id: `sess-${storedSessions.length + 1}`, name, model });
    storedSessions.push(session);
    return session;
  });
  const saveSession = vi.fn((session: Session) => {
    const index = storedSessions.findIndex((candidate) => candidate.id === session.id);
    if (index >= 0) storedSessions[index] = session;
    else storedSessions.push(session);
  });
  const listSessions = vi.fn(() => storedSessions);
  const startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
  const sendPrompt = vi.fn(async () => undefined);

  const service = new AgentLaunchService({
    storage: { createSession, saveSession, listSessions },
    sessions: { startSession, sendPrompt },
    ensureSessionContextWindow: (session) => ({ ...session, contextWindow: 200_000 }),
    nowMs: () => options.nowMs ?? 1_000,
    leaseTtlMs: 60_000,
  });

  return { service, createSession, saveSession, listSessions, startSession, sendPrompt };
}

describe("AgentLaunchService", () => {
  it("creates a session from instructions/resources/session defaults and target workspace", async () => {
    const { service, createSession, saveSession } = makeService();
    const agent: AgentDefinition = {
      name: "Reusable launch definition",
      instructions: { mode: "append", text: "You are focused." },
      resources: { agentsFiles: [{ path: "AGENTS.md", content: "Stay focused." }] },
      sessionDefaults: {
        model: "openai/gpt-5.5",
        thinkingLevel: "high",
      },
    };

    const result = await service.launch({
      agent,
      target: { workspace: makeWorkspace({ name: "Project" }), worktreeId: "feature" },
      sessionName: "Launch me",
      ephemeral: true,
    });

    expect(result.kind).toBe("created");
    if (result.kind === "created") {
      expect(result.promptDispatch).toBe("not_sent");
      expect(result.session).toMatchObject({
        id: "sess-1",
        workspaceId: "ws-1",
        workspaceName: "Project",
        worktreeId: "feature",
        thinkingLevel: "high",
        ephemeral: true,
        contextWindow: 200_000,
      });
    }
    expect(createSession).toHaveBeenCalledWith("Launch me", "openai/gpt-5.5");
    expect(saveSession).toHaveBeenCalledOnce();
  });

  it("reuses one session for the same idempotency key and reports existing", async () => {
    const existing = makeSession({
      id: "existing-1",
      firstMessage: "hello",
      launch: { idempotencyKey: "launch-1", status: "created", requestedAt: 900, completedAt: 950 },
    });
    const { service, createSession, startSession } = makeService({ sessions: [existing] });

    const result = await service.launch({
      agent: { name: "Ignored" },
      target: { workspace: makeWorkspace() },
      prompt: "hello",
      idempotencyKey: "launch-1",
    });

    expect(result.kind).toBe("existing");
    if (result.kind === "existing") {
      expect(result.session.id).toBe("existing-1");
      expect(result.promptDispatch).toBe("delivered");
    }
    expect(createSession).not.toHaveBeenCalled();
    expect(startSession).not.toHaveBeenCalled();
  });

  it("returns retryable launch_in_progress for an unexpired lease owned by another launcher", async () => {
    const launching = makeSession({
      id: "launching-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "other", acquiredAt: 1_000, expiresAt: 61_000 },
      },
    });
    const { service, createSession } = makeService({ sessions: [launching], nowMs: 2_000 });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      idempotencyKey: "launch-1",
      leaseOwner: "this-worker",
    });

    expect(result).toMatchObject({
      kind: "launch_in_progress",
      retryable: true,
      retryAfterMs: 59_000,
      session: { id: "launching-1" },
    });
    expect(createSession).not.toHaveBeenCalled();
  });

  it("reports prompt dispatch as delivered or not_sent", async () => {
    const delivered = makeService();
    const deliveredResult = await delivered.service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: " hello ",
    });

    expect(deliveredResult.kind).toBe("created");
    if (deliveredResult.kind === "created") {
      expect(deliveredResult.promptDispatch).toBe("delivered");
      expect(deliveredResult.session.firstMessage).toBe("hello");
    }

    const notSent = makeService();
    notSent.sendPrompt.mockRejectedValue(new Error("not ready"));
    const notSentResult = await notSent.service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: "hello",
    });

    expect(notSentResult.kind).toBe("created");
    if (notSentResult.kind === "created") {
      expect(notSentResult.promptDispatch).toBe("not_sent");
      expect(notSentResult.session.firstMessage).toBeUndefined();
    }
  });
});
