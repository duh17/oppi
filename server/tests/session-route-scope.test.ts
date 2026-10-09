import { describe, expect, it } from "vitest";

import {
  admitSessionRoute,
  matchFocusedSessionStreamPath,
  type SessionRouteStore,
} from "../src/session-route-scope.js";
import type { Session, Workspace } from "../src/types.js";

function workspace(id: string): Workspace {
  return { id, name: id } as Workspace;
}

function session(overrides: Partial<Session> = {}): Session {
  return {
    id: "sess-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function store(options: {
  workspaces?: Record<string, Workspace>;
  sessions?: Record<string, Session>;
}): SessionRouteStore {
  return {
    getWorkspace: (id) => options.workspaces?.[id],
    getSession: (id) => options.sessions?.[id],
  };
}

describe("matchFocusedSessionStreamPath", () => {
  it("matches workspace and control paths without conflating their scopes", () => {
    expect(matchFocusedSessionStreamPath("/workspaces/ws-1/sessions/session-1/stream")).toEqual({
      scope: "workspace",
      workspaceId: "ws-1",
      sessionId: "session-1",
    });
    expect(matchFocusedSessionStreamPath("/control-sessions/control-1/stream")).toEqual({
      scope: "control",
      sessionId: "control-1",
    });
    expect(matchFocusedSessionStreamPath("/sessions/control-1/stream")).toBeNull();
  });

  it("URL-decodes stream ids and rejects malformed encoding", () => {
    expect(matchFocusedSessionStreamPath("/workspaces/ws%2F1/sessions/sess%201/stream")).toEqual({
      scope: "workspace",
      workspaceId: "ws/1",
      sessionId: "sess 1",
    });
    expect(matchFocusedSessionStreamPath("/control-sessions/%")).toBeNull();
  });
});

describe("admitSessionRoute", () => {
  const ws = workspace("ws-1");
  const owned = session({ id: "sess-1", workspaceId: "ws-1" });
  const foreign = session({ id: "sess-2", workspaceId: "ws-2" });
  const declared = session({
    id: "control-1",
    workspaceId: undefined,
    control: { domain: "agents", intent: "create" },
  });
  const conversation = session({
    id: "control-conversation",
    workspaceId: undefined,
    serverDurable: { role: "control", conversationId: 4 },
  });
  const undeclared = session({ id: "stray", workspaceId: undefined });

  it("admits a workspace session and reports missing workspace, missing session, and wrong workspace", () => {
    const lookup = store({
      workspaces: { "ws-1": ws },
      sessions: { "sess-1": owned, "sess-2": foreign },
    });

    expect(
      admitSessionRoute(lookup, { scope: "workspace", workspaceId: "ws-1", sessionId: "sess-1" }),
    ).toEqual({ kind: "ok", session: owned, workspace: ws });
    expect(
      admitSessionRoute(lookup, {
        scope: "workspace",
        workspaceId: "missing",
        sessionId: "sess-1",
      }),
    ).toEqual({ kind: "workspace-missing" });
    expect(
      admitSessionRoute(lookup, { scope: "workspace", workspaceId: "ws-1", sessionId: "missing" }),
    ).toEqual({ kind: "session-missing" });
    expect(
      admitSessionRoute(lookup, { scope: "workspace", workspaceId: "ws-1", sessionId: "sess-2" }),
    ).toEqual({ kind: "wrong-workspace" });
  });

  it("skips workspace existence for stream-style workspace admission", () => {
    const lookup = store({ sessions: { "sess-1": owned, "sess-2": foreign } });
    const route = { scope: "workspace" as const, workspaceId: "ws-1", sessionId: "sess-1" };

    expect(admitSessionRoute(lookup, route)).toEqual({ kind: "workspace-missing" });
    expect(admitSessionRoute(lookup, route, { workspaceMustExist: false })).toEqual({
      kind: "ok",
      session: owned,
    });
    expect(
      admitSessionRoute(
        lookup,
        { scope: "workspace", workspaceId: "ws-1", sessionId: "sess-2" },
        { workspaceMustExist: false },
      ),
    ).toEqual({ kind: "wrong-workspace" });
  });

  it("admits declared control sessions and the control conversation, not other sessions", () => {
    const lookup = store({
      sessions: {
        "control-1": declared,
        "control-conversation": conversation,
        "sess-1": owned,
        stray: undeclared,
      },
    });

    expect(admitSessionRoute(lookup, { scope: "control", sessionId: "control-1" })).toEqual({
      kind: "ok",
      session: declared,
    });
    expect(
      admitSessionRoute(lookup, { scope: "control", sessionId: "control-conversation" }),
    ).toEqual({ kind: "ok", session: conversation });
    expect(admitSessionRoute(lookup, { scope: "control", sessionId: "sess-1" })).toEqual({
      kind: "not-control",
    });
    expect(admitSessionRoute(lookup, { scope: "control", sessionId: "stray" })).toEqual({
      kind: "not-control",
    });
    expect(admitSessionRoute(lookup, { scope: "control", sessionId: "missing" })).toEqual({
      kind: "session-missing",
    });
  });

  it("admits any existing session on the generic family, including declared control", () => {
    const lookup = store({ sessions: { "control-1": declared, "sess-1": owned } });

    expect(admitSessionRoute(lookup, { scope: "generic", sessionId: "sess-1" })).toEqual({
      kind: "ok",
      session: owned,
    });
    expect(admitSessionRoute(lookup, { scope: "generic", sessionId: "control-1" })).toEqual({
      kind: "ok",
      session: declared,
    });
    expect(admitSessionRoute(lookup, { scope: "generic", sessionId: "missing" })).toEqual({
      kind: "session-missing",
    });
  });
});
