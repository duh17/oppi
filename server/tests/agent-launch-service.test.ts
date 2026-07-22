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

function makeService(
  options: { sessions?: Session[]; nowMs?: number; recoveryClaim?: "win" | "lose" } = {},
) {
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
  const getSession = vi.fn((sessionId: string) =>
    storedSessions.find((session) => session.id === sessionId),
  );
  const findSessionByLaunchIdempotencyKey = vi.fn((key: string) =>
    storedSessions.find((session) => session.launch?.idempotencyKey === key),
  );
  const claimSessionLaunchRecovery = vi.fn(
    (session: Session, leaseOwner: string, nowMs: number, leaseTtlMs: number) => {
      if (options.recoveryClaim === "lose") return undefined;
      const index = storedSessions.findIndex((candidate) => candidate.id === session.id);
      const current = index >= 0 ? storedSessions[index] : undefined;
      if (!current?.launch || !session.launch) return undefined;
      if (current.launch.status !== session.launch.status) return undefined;
      if (current.launch.lease?.owner !== session.launch.lease?.owner) return undefined;
      if (current.launch.lease?.expiresAt !== session.launch.lease?.expiresAt) return undefined;
      const recovered: Session = {
        ...current,
        launch: {
          ...current.launch,
          status: "launching",
          lease: { owner: leaseOwner, acquiredAt: nowMs, expiresAt: nowMs + leaseTtlMs },
        },
      };
      storedSessions[index] = recovered;
      return recovered;
    },
  );
  const startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
  const sendPrompt = vi.fn(async () => undefined);

  const service = new AgentLaunchService({
    storage: {
      createSession,
      saveSession,
      getSession,
      listSessions,
      findSessionByLaunchIdempotencyKey,
      claimSessionLaunchRecovery,
    },
    sessions: { startSession, sendPrompt },
    ensureSessionContextWindow: (session) => ({ ...session, contextWindow: 200_000 }),
    nowMs: () => options.nowMs ?? 1_000,
    leaseTtlMs: 60_000,
  });

  return {
    service,
    createSession,
    saveSession,
    getSession,
    listSessions,
    findSessionByLaunchIdempotencyKey,
    claimSessionLaunchRecovery,
    startSession,
    sendPrompt,
  };
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
        launch: {
          status: "accepted",
          source: "workspace-wrapper",
          promptDispatch: "not_sent",
          target: { workspaceId: "ws-1", worktreeId: "feature", runtime: "host" },
        },
      });
    }
    expect(createSession).toHaveBeenCalledWith("Launch me", "openai/gpt-5.5");
    expect(saveSession).toHaveBeenCalledTimes(2);
  });

  it("snapshots the saved Agent icon without changing execution identity", async () => {
    const { service } = makeService();

    const result = await service.launch({
      agent: { name: "Reviewer", icon: { kind: "symbol", name: "checkmark.shield" } },
      agentId: "agent-reviewer",
      agentVersion: 4,
      target: { workspace: makeWorkspace() },
    });

    expect(result).toMatchObject({
      kind: "created",
      session: {
        launch: {
          agentId: "agent-reviewer",
          agentVersion: 4,
          agentIcon: { kind: "symbol", name: "checkmark.shield" },
        },
      },
    });
  });

  it("does not attach Agent presentation to workspace-wrapper sessions", async () => {
    const { service } = makeService();

    const result = await service.launch({
      agent: { name: "Workspace wrapper", icon: { kind: "symbol", name: "sparkles" } },
      target: { workspace: makeWorkspace() },
    });

    expect(result.kind).toBe("created");
    if (result.kind === "created") {
      expect(result.session.launch).not.toHaveProperty("agentIcon");
      expect(result.session.launch).not.toHaveProperty("agentId");
    }
  });

  it("keeps the original Agent icon on an idempotent retry", async () => {
    const existing = makeSession({
      id: "existing-1",
      launch: {
        agentId: "agent-reviewer",
        agentVersion: 4,
        agentIcon: { kind: "emoji", value: "🧘" },
        idempotencyKey: "launch-1",
        status: "accepted",
        requestedAt: 900,
      },
    });
    const { service } = makeService({ sessions: [existing] });

    const result = await service.launch({
      agent: { name: "Reviewer", icon: { kind: "symbol", name: "checkmark.shield" } },
      agentId: "agent-reviewer",
      agentVersion: 5,
      target: { workspace: makeWorkspace() },
      idempotencyKey: "launch-1",
    });

    expect(result).toMatchObject({
      kind: "existing",
      session: { launch: { agentVersion: 4, agentIcon: { kind: "emoji", value: "🧘" } } },
    });
  });

  it("stamps managed child sessions with their caller identity", async () => {
    const parent = makeSession({ id: "root-1" });
    const { service } = makeService({ sessions: [parent] });

    const result = await service.launch({
      agent: { name: "child" },
      target: { workspace: makeWorkspace() },
      parentSessionId: parent.id,
    });

    expect(result).toMatchObject({
      kind: "created",
      session: {
        launch: { parentSessionId: "root-1", allowsNestedDelegation: undefined },
      },
    });
  });

  it("rejects nested delegation by default", async () => {
    const root = makeSession({ id: "root-1" });
    const child = makeSession({
      id: "child-1",
      launch: { parentSessionId: root.id, status: "accepted", requestedAt: 1 },
    });
    const { service, createSession } = makeService({ sessions: [root, child] });

    await expect(
      service.launch({
        agent: { name: "grandchild" },
        target: { workspace: makeWorkspace() },
        parentSessionId: child.id,
      }),
    ).rejects.toThrow("Nested delegation is not authorized");
    expect(createSession).not.toHaveBeenCalled();
  });

  it("allows multiple grandchildren at one explicitly authorized nested level", async () => {
    const root = makeSession({ id: "root-1" });
    const { service, createSession } = makeService({ sessions: [root] });

    const child = await service.launch({
      agent: { name: "child" },
      target: { workspace: makeWorkspace() },
      parentSessionId: root.id,
      allowNestedDelegation: true,
    });
    expect(child).toMatchObject({
      kind: "created",
      session: { launch: { parentSessionId: root.id, allowsNestedDelegation: true } },
    });
    if (child.kind === "launch_in_progress") throw new Error("Expected child session");

    const grandchildren = await Promise.all(
      ["grandchild-a", "grandchild-b"].map((name) =>
        service.launch({
          agent: { name },
          target: { workspace: makeWorkspace() },
          parentSessionId: child.session.id,
        }),
      ),
    );
    for (const grandchild of grandchildren) {
      expect(grandchild).toMatchObject({
        kind: "created",
        session: {
          launch: {
            parentSessionId: child.session.id,
            allowsNestedDelegation: undefined,
          },
        },
      });
      if (grandchild.kind === "launch_in_progress") throw new Error("Expected grandchild session");
    }

    const [grandchild] = grandchildren;
    if (!grandchild || grandchild.kind === "launch_in_progress") {
      throw new Error("Expected a grandchild session");
    }
    await expect(
      service.launch({
        agent: { name: "great-grandchild" },
        target: { workspace: makeWorkspace() },
        parentSessionId: grandchild.session.id,
        allowNestedDelegation: true,
      }),
    ).rejects.toThrow("Nested delegation is not authorized");
    expect(createSession).toHaveBeenCalledTimes(3);
  });

  it("returns an existing launch for an authorized idempotent retry", async () => {
    const root = makeSession({ id: "root-1" });
    const existing = makeSession({
      id: "child-1",
      firstMessage: "already delivered",
      launch: {
        parentSessionId: root.id,
        idempotencyKey: "delegated-retry",
        status: "accepted",
        requestedAt: 1,
        promptDispatch: "delivered",
      },
    });
    const { service, createSession, getSession } = makeService({ sessions: [root, existing] });

    await expect(
      service.launch({
        agent: { name: "child" },
        target: { workspace: makeWorkspace() },
        parentSessionId: root.id,
        idempotencyKey: "delegated-retry",
      }),
    ).resolves.toMatchObject({ kind: "existing", session: { id: existing.id } });
    expect(getSession).toHaveBeenCalledWith(root.id);
    expect(createSession).not.toHaveBeenCalled();
  });

  it("rejects a normal idempotent retry with a different delegation lineage", async () => {
    const root = makeSession({ id: "root-1" });
    const existing = makeSession({
      id: "child-1",
      launch: {
        parentSessionId: root.id,
        allowsNestedDelegation: true,
        idempotencyKey: "delegated-retry",
        status: "accepted",
        requestedAt: 1,
      },
    });
    const { service, createSession } = makeService({ sessions: [root, existing] });

    await expect(
      service.launch({
        agent: { name: "child" },
        target: { workspace: makeWorkspace() },
        parentSessionId: root.id,
        idempotencyKey: "delegated-retry",
      }),
    ).rejects.toThrow("Idempotency key is already associated with a different delegation lineage");
    expect(createSession).not.toHaveBeenCalled();
  });

  it("rejects an idempotent retry from a different authorized root parent", async () => {
    const firstRoot = makeSession({ id: "root-1" });
    const secondRoot = makeSession({ id: "root-2" });
    const existing = makeSession({
      id: "child-1",
      launch: {
        parentSessionId: firstRoot.id,
        idempotencyKey: "delegated-retry",
        status: "accepted",
        requestedAt: 1,
      },
    });
    const { service, createSession, getSession } = makeService({
      sessions: [firstRoot, secondRoot, existing],
    });

    await expect(
      service.launch({
        agent: { name: "child" },
        target: { workspace: makeWorkspace() },
        parentSessionId: secondRoot.id,
        idempotencyKey: "delegated-retry",
      }),
    ).rejects.toThrow("Idempotency key is already associated with a different delegation lineage");
    expect(getSession).toHaveBeenCalledWith(secondRoot.id);
    expect(createSession).not.toHaveBeenCalled();
  });

  it("rejects an unauthorized caller before matching an idempotent retry", async () => {
    const root = makeSession({ id: "root-1" });
    const unauthorizedChild = makeSession({
      id: "child-1",
      launch: { parentSessionId: root.id, status: "accepted", requestedAt: 1 },
    });
    const existing = makeSession({
      id: "existing-1",
      launch: { idempotencyKey: "delegated-retry", status: "accepted", requestedAt: 1 },
    });
    const { service, findSessionByLaunchIdempotencyKey } = makeService({
      sessions: [root, unauthorizedChild, existing],
    });

    await expect(
      service.launch({
        agent: { name: "grandchild" },
        target: { workspace: makeWorkspace() },
        parentSessionId: unauthorizedChild.id,
        idempotencyKey: "delegated-retry",
      }),
    ).rejects.toThrow("Nested delegation is not authorized");
    expect(findSessionByLaunchIdempotencyKey).not.toHaveBeenCalled();
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

  it("returns the original launch for a conflicting prompt on the same idempotency key", async () => {
    const existing = makeSession({
      id: "existing-1",
      firstMessage: "original prompt",
      workspaceId: "ws-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "accepted",
        requestedAt: 900,
        completedAt: 950,
        promptDispatch: "delivered",
        target: { workspaceId: "ws-1", runtime: "host" },
      },
    });
    const { service, createSession, startSession, sendPrompt } = makeService({
      sessions: [existing],
    });

    const result = await service.launch({
      agent: { name: "Conflicting launch" },
      target: { workspace: makeWorkspace() },
      prompt: "different prompt",
      idempotencyKey: "launch-1",
    });

    expect(result).toMatchObject({
      kind: "existing",
      session: { id: "existing-1", firstMessage: "original prompt" },
      promptDispatch: "delivered",
    });
    expect(createSession).not.toHaveBeenCalled();
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
  });

  it("recovers the winning session when initial idempotent persistence loses a race", async () => {
    const winner = makeSession({
      id: "winner-1",
      workspaceId: "ws-1",
      launch: {
        idempotencyKey: "launch-race",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "other-worker", acquiredAt: 1_000, expiresAt: 61_000 },
      },
    });
    let persistedWinner: Session | undefined;
    const saveSession = vi.fn(() => {
      persistedWinner = winner;
      throw new Error("UNIQUE constraint failed: launch.idempotency_key");
    });
    const startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
    const sendPrompt = vi.fn(async () => undefined);
    const service = new AgentLaunchService({
      storage: {
        createSession: vi.fn(),
        saveSession,
        getSession: vi.fn(),
        listSessions: vi.fn(() => (persistedWinner ? [persistedWinner] : [])),
        findSessionByLaunchIdempotencyKey: vi.fn(() => persistedWinner),
        claimSessionLaunchRecovery: vi.fn(() => undefined),
      },
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 2_000,
      leaseTtlMs: 60_000,
    });

    const result = await service.launch({
      agent: { name: "Race loser" },
      target: { workspace: makeWorkspace() },
      prompt: "must be sent by the winner",
      idempotencyKey: "launch-race",
      leaseOwner: "this-worker",
    });

    expect(result).toMatchObject({
      kind: "launch_in_progress",
      retryable: true,
      session: { id: "winner-1" },
      retryAfterMs: 59_000,
    });
    expect(saveSession).toHaveBeenCalledTimes(1);
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
  });

  it("rejects a persistence-race idempotency recovery with a different delegation lineage", async () => {
    const root = makeSession({ id: "root-1" });
    const winner = makeSession({
      id: "winner-1",
      workspaceId: "ws-1",
      launch: {
        parentSessionId: root.id,
        allowsNestedDelegation: true,
        idempotencyKey: "launch-race",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "other-worker", acquiredAt: 1_000, expiresAt: 61_000 },
      },
    });
    let persistedWinner: Session | undefined;
    const saveSession = vi.fn(() => {
      persistedWinner = winner;
      throw new Error("UNIQUE constraint failed: launch.idempotency_key");
    });
    const startSession = vi.fn(async (sessionId: string) => makeSession({ id: sessionId }));
    const sendPrompt = vi.fn(async () => undefined);
    const service = new AgentLaunchService({
      storage: {
        createSession: vi.fn(),
        saveSession,
        getSession: vi.fn((sessionId: string) => (sessionId === root.id ? root : undefined)),
        listSessions: vi.fn(() => (persistedWinner ? [persistedWinner] : [root])),
        findSessionByLaunchIdempotencyKey: vi.fn(() => persistedWinner),
        claimSessionLaunchRecovery: vi.fn(() => undefined),
      },
      sessions: { startSession, sendPrompt },
      ensureSessionContextWindow: (session) => session,
      nowMs: () => 2_000,
      leaseTtlMs: 60_000,
    });

    await expect(
      service.launch({
        agent: { name: "Race loser" },
        target: { workspace: makeWorkspace() },
        prompt: "must not be sent",
        parentSessionId: root.id,
        idempotencyKey: "launch-race",
        leaseOwner: "this-worker",
      }),
    ).rejects.toThrow("Idempotency key is already associated with a different delegation lineage");
    expect(saveSession).toHaveBeenCalledTimes(1);
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
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

  it("does not recover an unexpired launching lease held by the same owner", async () => {
    const launching = makeSession({
      id: "launching-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "worker", acquiredAt: 1_000, expiresAt: 61_000 },
      },
    });
    const { service, createSession, startSession, sendPrompt } = makeService({
      sessions: [launching],
      nowMs: 2_000,
    });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: "must not send twice",
      idempotencyKey: "launch-1",
      leaseOwner: "worker",
    });

    expect(result).toMatchObject({
      kind: "launch_in_progress",
      retryable: true,
      retryAfterMs: 59_000,
      session: { id: "launching-1" },
    });
    expect(createSession).not.toHaveBeenCalled();
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
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

  it("recovers an expired launching lease and sends the prompt on retry", async () => {
    const launching = makeSession({
      id: "launching-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "worker-a", acquiredAt: 1_000, expiresAt: 1_500 },
      },
    });
    const { service, createSession, startSession, sendPrompt } = makeService({
      sessions: [launching],
      nowMs: 2_000,
    });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: "recover prompt",
      idempotencyKey: "launch-1",
      leaseOwner: "worker-b",
    });

    expect(result).toMatchObject({
      kind: "existing",
      session: { id: "launching-1", firstMessage: "recover prompt" },
      promptDispatch: "delivered",
    });
    expect(createSession).not.toHaveBeenCalled();
    expect(startSession).toHaveBeenCalledWith("launching-1", makeWorkspace());
    expect(sendPrompt).toHaveBeenCalledWith("launching-1", "recover prompt", {});
  });

  it("does not recover an expired launch when the retry target differs", async () => {
    const launching = makeSession({
      id: "launching-1",
      workspaceId: "ws-1",
      worktreeId: "feature-a",
      launch: {
        idempotencyKey: "launch-1",
        status: "launching",
        requestedAt: 1_000,
        target: { workspaceId: "ws-1", worktreeId: "feature-a", runtime: "host" },
        lease: { owner: "worker-a", acquiredAt: 1_000, expiresAt: 1_500 },
      },
    });
    const { service, claimSessionLaunchRecovery, startSession, sendPrompt } = makeService({
      sessions: [launching],
      nowMs: 2_000,
    });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace(), worktreeId: "feature-b" },
      prompt: "must not recover into feature-b",
      idempotencyKey: "launch-1",
      leaseOwner: "worker-b",
    });

    expect(result).toMatchObject({
      kind: "existing",
      session: { id: "launching-1" },
      promptDispatch: "not_sent",
    });
    expect(claimSessionLaunchRecovery).not.toHaveBeenCalled();
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
  });

  it("does not send the prompt when expired launch recovery loses the lease race", async () => {
    const launching = makeSession({
      id: "launching-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "launching",
        requestedAt: 1_000,
        lease: { owner: "worker-a", acquiredAt: 1_000, expiresAt: 1_500 },
      },
    });
    const { service, startSession, sendPrompt } = makeService({
      sessions: [launching],
      nowMs: 2_000,
      recoveryClaim: "lose",
    });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: "recover prompt",
      idempotencyKey: "launch-1",
      leaseOwner: "worker-b",
    });

    expect(result).toMatchObject({
      kind: "launch_in_progress",
      retryable: true,
      session: { id: "launching-1" },
    });
    expect(startSession).not.toHaveBeenCalled();
    expect(sendPrompt).not.toHaveBeenCalled();
  });

  it("retries a failed launch whose prompt was not delivered", async () => {
    const failed = makeSession({
      id: "failed-1",
      launch: {
        idempotencyKey: "launch-1",
        status: "failed",
        requestedAt: 1_000,
        completedAt: 1_500,
        promptDispatch: "not_sent",
        promptError: "transport down",
      },
    });
    const { service, createSession, sendPrompt } = makeService({
      sessions: [failed],
      nowMs: 2_000,
    });

    const result = await service.launch({
      agent: { name: "test" },
      target: { workspace: makeWorkspace() },
      prompt: "retry prompt",
      idempotencyKey: "launch-1",
      leaseOwner: "worker-b",
    });

    expect(result).toMatchObject({
      kind: "existing",
      session: { id: "failed-1", firstMessage: "retry prompt" },
      promptDispatch: "delivered",
    });
    expect(
      result.kind === "existing" ? result.session.launch?.promptError : undefined,
    ).toBeUndefined();
    expect(createSession).not.toHaveBeenCalled();
    expect(sendPrompt).toHaveBeenCalledWith("failed-1", "retry prompt", {});
  });
});
