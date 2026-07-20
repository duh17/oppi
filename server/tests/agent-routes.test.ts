import type { ServerResponse } from "node:http";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { DEFAULT_AGENT_ID } from "../src/default-agent.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { RouteHandler } from "../src/routes/index.js";
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
  it("mounts saved Agent routes in the main route handler", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-mounted-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const routes = new RouteHandler(ctx);

      const listRes = makeResponse();
      await routes.dispatch(
        "GET",
        "/agents",
        new URL("http://localhost/agents"),
        {} as never,
        listRes as never,
      );
      expect(listRes.statusCode).toBe(200);
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: DEFAULT_AGENT_ID,
            name: "Default Agent",
            status: "active",
          }),
          expect.objectContaining({ id: agent.id, name: "Reviewer", status: "active" }),
        ]),
      );

      const launchRes = makeResponse();
      await routes.dispatch(
        "POST",
        `/agents/${agent.id}/sessions`,
        new URL(`http://localhost/agents/${agent.id}/sessions`),
        makeRequest({}) as never,
        launchRes as never,
      );
      expect(launchRes.statusCode).toBe(400);
      expect(JSON.parse(launchRes.body)).toEqual({ error: "prompt.text required" });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

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
            resources: { skillPaths: [".pi/skills/reviewer"] },
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
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: DEFAULT_AGENT_ID,
            name: "Default Agent",
            status: "active",
          }),
          expect.objectContaining({ id: created.id, name: "Reviewer", status: "active" }),
        ]),
      );

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
        definition: {
          name: "Reviewer",
          description: "Reviews diffs",
          resources: { skillPaths: [".pi/skills/reviewer"] },
        },
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

      const clearRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: makeRequest({
          description: null,
          instructions: null,
          resources: null,
          sessionDefaults: { model: null, thinkingLevel: null },
        }) as never,
        res: clearRes as never,
      });
      const cleared = JSON.parse(clearRes.body).agent as { definition: Record<string, unknown> };
      expect(cleared.definition).not.toHaveProperty("description");
      expect(cleared.definition).not.toHaveProperty("instructions");
      expect(cleared.definition).not.toHaveProperty("resources");
      expect(cleared.definition.sessionDefaults).toEqual({});

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

  it("preserves a historical malformed icon on unrelated updates, then allows clearing it", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-historical-icon-"));
    const databasePath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Historian",
        icon: "sparkles",
        description: "Original description",
      });
      store.close();

      const db = openDatabase(databasePath);
      db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
        JSON.stringify({
          name: "Historian",
          icon: "historical/icon",
          description: "Original description",
        }),
        agent.id,
      );
      db.close();

      store = new AgentDefinitionStore(dataDir);
      const updated = store.updateAgent(agent.id, { description: "Updated description" });
      expect(updated?.definition).toMatchObject({
        icon: "historical/icon",
        description: "Updated description",
      });
      expect(() => store.updateAgent(agent.id, { icon: "still/invalid" })).toThrow(
        /one Unicode emoji or an SF Symbol name/,
      );

      const cleared = store.updateAgent(agent.id, { icon: null });
      expect(cleared?.definition).not.toHaveProperty("icon");
      expect(cleared?.definition.description).toBe("Updated description");
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("updates, persists, returns, and clears a saved Agent icon", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-icon-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Sensei",
        description: "Guides reviews",
        instructions: { mode: "append", text: "Stay calm." },
        sessionDefaults: { model: "openai-codex/gpt-5.5" },
      });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: "  🧘  " }) as never,
        res: updateRes as never,
      });
      expect(updateRes.statusCode).toBe(200);
      expect(JSON.parse(updateRes.body).agent.definition).toMatchObject({
        name: "Sensei",
        icon: "🧘",
        description: "Guides reviews",
        instructions: { mode: "append", text: "Stay calm." },
        sessionDefaults: { model: "openai-codex/gpt-5.5" },
      });

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: {} as never,
        res: getRes as never,
      });
      expect(JSON.parse(getRes.body).agent.definition.icon).toBe("🧘");
      expect(store.getAgentVersion(agent.id, 2)?.definition.icon).toBe("🧘");

      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: {} as never,
        res: listRes as never,
      });
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([expect.objectContaining({ id: agent.id, icon: "🧘" })]),
      );

      const sfSymbolRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: "  checkmark.shield  " }) as never,
        res: sfSymbolRes as never,
      });
      expect(sfSymbolRes.statusCode).toBe(200);
      expect(JSON.parse(sfSymbolRes.body).agent.definition.icon).toBe("checkmark.shield");

      for (const invalidIcon of [
        "two words",
        "🧘🧘",
        "not/a/symbol",
        "x".repeat(129),
        `😀${"‍😀".repeat(64)}`,
      ]) {
        const invalidRes = makeResponse();
        await dispatch({
          method: "PATCH",
          path: `/agents/${agent.id}`,
          url: new URL(`http://localhost/agents/${agent.id}`),
          req: makeRequest({ icon: invalidIcon }) as never,
          res: invalidRes as never,
        });
        expect(invalidRes.statusCode).toBe(400);
        expect(JSON.parse(invalidRes.body).error).toContain("icon");
      }

      const clearRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: null }) as never,
        res: clearRes as never,
      });
      expect(clearRes.statusCode).toBe(200);
      expect(JSON.parse(clearRes.body).agent.definition).not.toHaveProperty("icon");
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("seeds an overwriteable default Agent identity and can reset customization", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents/default",
        url: new URL("http://localhost/agents/default"),
        req: {} as never,
        res: getRes as never,
      });
      expect(getRes.statusCode).toBe(200);
      expect(JSON.parse(getRes.body).agent).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Default Agent",
        status: "active",
        definition: {
          name: "Default Agent",
          description: expect.stringContaining("Manage Oppi"),
          resources: { noContextFiles: true },
          sessionDefaults: { noTools: "builtin", tools: ["oppi", "ask"] },
        },
      });

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: "/agents/default",
        url: new URL("http://localhost/agents/default"),
        req: makeRequest({
          name: "Home Agent",
          icon: "🏠",
          description: "Coordinates Oppi from the app home screen",
          instructions: { mode: "append", text: "Prefer short status summaries." },
          sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" },
        }) as never,
        res: updateRes as never,
      });
      expect(updateRes.statusCode).toBe(200);
      const updated = JSON.parse(updateRes.body).agent;
      expect(updated).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Home Agent",
        version: 2,
        definition: {
          name: "Home Agent",
          icon: "🏠",
          description: "Coordinates Oppi from the app home screen",
          instructions: { mode: "append", text: "Prefer short status summaries." },
          resources: { noContextFiles: true },
          sessionDefaults: {
            model: "openai-codex/gpt-5.5",
            thinkingLevel: "high",
            noTools: "builtin",
            tools: ["oppi", "ask"],
          },
        },
      });

      const rejectRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: "/agents/default",
        url: new URL("http://localhost/agents/default"),
        req: makeRequest({ sessionDefaults: { tools: ["bash"] } }) as never,
        res: rejectRes as never,
      });
      expect(rejectRes.statusCode).toBe(400);
      expect(JSON.parse(rejectRes.body).error).toContain("sessionDefaults.tools");

      const launchOverrideRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents/default/sessions",
        url: new URL("http://localhost/agents/default/sessions"),
        req: makeRequest({
          prompt: { text: "Run safely" },
          target: { workspaceId: "ws-1" },
          overrides: { tools: ["bash"] },
        }) as never,
        res: launchOverrideRes as never,
      });
      expect(launchOverrideRes.statusCode).toBe(400);
      expect(JSON.parse(launchOverrideRes.body).error).toBe(
        "Default Agent launch overrides cannot change tools",
      );

      const resetRes = makeResponse();
      await dispatch({
        method: "DELETE",
        path: "/agents/default/customization",
        url: new URL("http://localhost/agents/default/customization"),
        req: {} as never,
        res: resetRes as never,
      });
      expect(resetRes.statusCode).toBe(200);
      expect(JSON.parse(resetRes.body).agent).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Default Agent",
        version: 3,
        definition: {
          name: "Default Agent",
          resources: { noContextFiles: true },
          sessionDefaults: { noTools: "builtin", tools: ["oppi", "ask"] },
        },
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not archive the reserved default Agent identity", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-archive-routes-"));
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
        method: "DELETE",
        path: "/agents/default",
        url: new URL("http://localhost/agents/default"),
        req: {} as never,
        res: res as never,
      });
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("cannot be archived");
      expect(store.getAgent(DEFAULT_AGENT_ID)).toMatchObject({ status: "active" });
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
        icon: "checkmark.shield",
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
          getDataDir: vi.fn(() => dataDir),
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
          agentIcon: "checkmark.shield",
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

  it("launches an Agent with a historical malformed icon under unrelated overrides", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-historical-icon-launch-"));
    const databasePath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Historian",
        icon: "sparkles",
        sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
      });
      store.close();

      const db = openDatabase(databasePath);
      db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
        JSON.stringify({
          name: "Historian",
          icon: "historical/icon",
          sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
        }),
        agent.id,
      );
      db.close();

      store = new AgentDefinitionStore(dataDir);
      const sessions: Session[] = [];
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          getDataDir: vi.fn(() => dataDir),
          createSession: vi.fn((name?: string, model?: string) => {
            const session = makeSession({ id: `sess-${sessions.length + 1}`, name, model });
            sessions.push(structuredClone(session));
            return session;
          }),
          saveSession: vi.fn((session: Session) => {
            const existing = sessions.findIndex((candidate) => candidate.id === session.id);
            const copy = structuredClone(session);
            if (existing >= 0) sessions[existing] = copy;
            else sessions.push(copy);
          }),
          getSession: vi.fn((sessionId: string) =>
            sessions.find((candidate) => candidate.id === sessionId),
          ),
          listSessions: vi.fn(() => sessions),
          findSessionByLaunchIdempotencyKey: vi.fn(),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: {
          startSession: vi.fn(async (sessionId: string) => {
            const session = sessions.find((candidate) => candidate.id === sessionId);
            if (!session) throw new Error("missing session");
            return session;
          }),
          sendPrompt: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const launch = async (overrides?: Record<string, unknown>): Promise<Session> => {
        const res = makeResponse();
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Read history" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            ...(overrides === undefined ? {} : { overrides }),
          }) as never,
          res: res as never,
        });
        expect(res.statusCode).toBe(201);
        return (JSON.parse(res.body) as { session: Session }).session;
      };

      const launches = [
        await launch(),
        await launch({ model: "override-model" }),
        await launch({ thinkingLevel: "low" }),
      ];
      expect(launches).toMatchObject([
        { model: "agent-model", thinkingLevel: "high" },
        { model: "override-model", thinkingLevel: "high" },
        { model: "agent-model", thinkingLevel: "low" },
      ]);
      for (const launched of launches) {
        expect(launched.launch?.agentIcon).toBe("historical/icon");
      }

      for (const [overrides, errorFragment] of [
        [{ model: "   " }, "model"],
        [{ thinkingLevel: "turbo" }, "thinkingLevel"],
        [{ tools: "bash" }, "tools"],
        [{ excludeTools: [42] }, "excludeTools"],
        [{ noTools: "none" }, "noTools"],
      ] as const) {
        const sessionCount = sessions.length;
        const res = makeResponse();
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Read history" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            overrides,
          }) as never,
          res: res as never,
        });
        expect(res.statusCode).toBe(400);
        expect(JSON.parse(res.body).error).toContain(errorFragment);
        expect(sessions).toHaveLength(sessionCount);
      }
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it.each([
    [{ parentSessionId: 42 }, "parentSessionId must be a non-empty string"],
    [{ parentSessionId: "   " }, "parentSessionId must be a non-empty string"],
    [{ allowNestedDelegation: "true" }, "allowNestedDelegation must be a boolean"],
  ])("rejects malformed delegation fields with HTTP 400", async (body, error) => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-delegation-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest(body) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error });
    } finally {
      store.close();
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
          getDataDir: vi.fn(() => dataDir),
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

  it("rejects public Agent definitions that use reserved default identity names", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-reserved-name-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const defaultNameRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "Default Agent" }) as never,
        res: defaultNameRes as unknown as ServerResponse,
      });
      expect(defaultNameRes.statusCode).toBe(400);
      expect(JSON.parse(defaultNameRes.body).error).toContain("reserved");

      const aliasRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "default" }) as never,
        res: aliasRes as unknown as ServerResponse,
      });
      expect(aliasRes.statusCode).toBe(400);
      expect(JSON.parse(aliasRes.body).error).toContain("reserved");
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

  it("rejects unexpected Agent definition fields and empty updates", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-strict-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const unexpectedRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ description: "Updated", unexpected: true }) as never,
        res: unexpectedRes as unknown as ServerResponse,
      });
      expect(unexpectedRes.statusCode).toBe(400);
      expect(JSON.parse(unexpectedRes.body)).toEqual({
        error: "Agent definition has unexpected field: unexpected",
      });

      const nestedRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ sessionDefaults: { model: "model", unexpected: true } }) as never,
        res: nestedRes as unknown as ServerResponse,
      });
      expect(nestedRes.statusCode).toBe(400);
      expect(JSON.parse(nestedRes.body)).toEqual({
        error: "sessionDefaults has unexpected field: unexpected",
      });

      const emptyRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({}) as never,
        res: emptyRes as unknown as ServerResponse,
      });
      expect(emptyRes.statusCode).toBe(400);
      expect(JSON.parse(emptyRes.body)).toEqual({
        error: "Agent update must include at least one field",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
