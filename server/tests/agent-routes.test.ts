import type { ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: overrides.id ?? "sess-1",
    status: overrides.status ?? "ready",
    createdAt: overrides.createdAt ?? 1,
    lastActivity: overrides.lastActivity ?? 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

describe("agent routes", () => {
  it("creates, lists, gets, updates, and archives durable Agent definitions", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const createRes = makeResponse();
      expect(
        await dispatch({
          method: "POST",
          path: "/agents",
          url: new URL("http://localhost/agents"),
          req: makeRequest({
            name: "Reviewer",
            description: "Reviews diffs",
            instructions: { mode: "append", text: "Focus on risk." },
            sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "medium" },
          }) as never,
          res: createRes as never,
        }),
      ).toBe(true);
      expect(createRes.statusCode).toBe(201);
      const created = JSON.parse(createRes.body).agent as { id: string; version: number };
      expect(created.id).toBeTruthy();
      expect(created.version).toBe(1);

      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: {} as never,
        res: listRes as never,
      });
      expect(JSON.parse(listRes.body).agents).toEqual([
        expect.objectContaining({ id: created.id, name: "Reviewer", status: "active" }),
      ]);

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: `/agents/${encodeURIComponent("Reviewer")}`,
        url: new URL("http://localhost/agents/Reviewer"),
        req: {} as never,
        res: getRes as never,
      });
      expect(JSON.parse(getRes.body).agent).toMatchObject({
        id: created.id,
        definition: { name: "Reviewer", description: "Reviews diffs" },
      });

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: makeRequest({ description: "Reviews risky diffs" }) as never,
        res: updateRes as never,
      });
      expect(JSON.parse(updateRes.body).agent).toMatchObject({
        id: created.id,
        version: 2,
        definition: { name: "Reviewer", description: "Reviews risky diffs" },
      });
      expect(store.getAgentVersion(created.id, 1)?.definition).toMatchObject({
        name: "Reviewer",
        description: "Reviews diffs",
      });
      expect(store.getAgentVersion(created.id, 2)?.definition).toMatchObject({
        name: "Reviewer",
        description: "Reviews risky diffs",
      });

      const archiveRes = makeResponse();
      await dispatch({
        method: "DELETE",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: {} as never,
        res: archiveRes as never,
      });
      expect(JSON.parse(archiveRes.body).agent).toMatchObject({
        id: created.id,
        status: "archived",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("launches a workspace session from a saved Agent with launch metadata", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-launch-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({
        name: "Reviewer",
        sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
      });
      const sessions: Session[] = [];
      const saveSession = vi.fn((session: Session) => {
        const existing = sessions.findIndex((candidate) => candidate.id === session.id);
        const copy = structuredClone(session);
        if (existing >= 0) sessions[existing] = copy;
        else sessions.push(copy);
      });
      const startSession = vi.fn(async (sessionId: string) => {
        const session = sessions.find((candidate) => candidate.id === sessionId);
        if (!session) throw new Error("missing session");
        return session;
      });
      const sendPrompt = vi.fn(async () => undefined);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          createSession: vi.fn((name?: string, model?: string) => {
            const session = makeSession({ id: `sess-${sessions.length + 1}`, name, model });
            sessions.push(structuredClone(session));
            return session;
          }),
          saveSession,
          getSession: vi.fn((sessionId: string) =>
            sessions.find((candidate) => candidate.id === sessionId),
          ),
          listSessions: vi.fn(() => sessions),
          findSessionByLaunchIdempotencyKey: vi.fn((key: string) =>
            sessions.find((candidate) => candidate.launch?.idempotencyKey === key),
          ),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: { startSession, sendPrompt },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
        appEvents: { emitSessionCreated: vi.fn(), emitSessionSummary: vi.fn() },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      expect(
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Review this" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            idempotencyKey: "agent-launch-1",
            sessionName: "Review run",
            overrides: { model: "override-model" },
          }) as never,
          res: res as never,
        }),
      ).toBe(true);

      expect(res.statusCode).toBe(201);
      const body = JSON.parse(res.body) as {
        receipt: { accepted: boolean; agentId: string; agentVersion: number; sessionId: string };
        session: Session;
      };
      expect(body.receipt).toMatchObject({
        accepted: true,
        agentId: agent.id,
        agentVersion: 1,
        promptDispatch: "delivered",
      });
      expect(body.session).toMatchObject({
        id: body.receipt.sessionId,
        workspaceId: "ws-1",
        worktreeId: "main",
        model: "override-model",
        thinkingLevel: "high",
        launch: {
          source: "agent",
          agentId: agent.id,
          agentVersion: 1,
          idempotencyKey: "agent-launch-1",
          promptDispatch: "delivered",
        },
      });
      expect(startSession).toHaveBeenCalledWith(body.receipt.sessionId, {
        id: "ws-1",
        name: "Oppi",
      });
      expect(sendPrompt).toHaveBeenCalledWith(body.receipt.sessionId, "Review this", {});
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects invalid launch override values before creating a session", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-override-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({ name: "Reviewer" });
      const createSession = vi.fn();
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          createSession,
          saveSession: vi.fn(),
          listSessions: vi.fn(() => []),
          findSessionByLaunchIdempotencyKey: vi.fn(),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: { startSession: vi.fn(), sendPrompt: vi.fn() },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          prompt: { text: "Review this" },
          target: { workspaceId: "ws-1", worktreeId: "main" },
          overrides: { thinkingLevel: "turbo" },
        }) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("thinkingLevel");
      expect(createSession).not.toHaveBeenCalled();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects public Agent definitions that include launch targets", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-invalid-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "Bad", target: { workspaceId: "ws-1" } }) as never,
        res: res as unknown as ServerResponse,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("target");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
