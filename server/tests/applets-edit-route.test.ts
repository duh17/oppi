import { describe, expect, it, vi } from "vitest";
import { createAppletRoutes } from "../src/routes/applets.js";
import type { Applet, AppletVersion, Session, Workspace } from "../src/types.js";

function makeResponseRecorder() {
  return {
    status: 0,
    data: null as unknown,
  };
}

describe("applet edit-session route", () => {
  it("creates a new edit session and stores a deferred bootstrap preamble", async () => {
    const workspace: Workspace = {
      id: "w1",
      name: "Workspace",
      skills: [],
      defaultModel: "openai/test",
      createdAt: 1,
      updatedAt: 1,
    };

    const applet: Applet = {
      id: "a1",
      workspaceId: "w1",
      title: "JSON Inspector",
      currentVersion: 2,
      createdAt: 1,
      updatedAt: 2,
    };

    const version: AppletVersion & { html: string } = {
      version: 2,
      appletId: "a1",
      size: 123,
      createdAt: 2,
      html: "<html></html>",
    };

    const createdSession: Session = {
      id: "edit-1",
      name: "Edit: JSON Inspector",
      workspaceId: "w1",
      workspaceName: "Workspace",
      status: "starting",
      createdAt: 10,
      lastActivity: 10,
      model: "openai/test",
      messageCount: 0,
      tokens: { input: 0, output: 0 },
      cost: 0,
    };

    const storage = {
      getWorkspace: vi.fn(() => workspace),
      getApplet: vi.fn(() => applet),
      getAppletVersion: vi.fn(() => version),
      getSession: vi.fn(() => undefined),
      createSession: vi.fn(() => ({ ...createdSession })),
      saveSession: vi.fn(),
      deleteSession: vi.fn(),
    };

    const sessions = {
      startSession: vi.fn(async () => createdSession),
      setPendingPromptPreamble: vi.fn(),
      stopSession: vi.fn(async () => {}),
      refreshSessionState: vi.fn(async () => null),
    };

    const json = makeResponseRecorder();
    const dispatcher = createAppletRoutes(
      {
        storage,
        sessions,
        ensureSessionContextWindow: (session: Session) => session,
      } as never,
      {
        parseBody: vi.fn(async () => ({})),
        json: vi.fn((_: unknown, data: unknown, status?: number) => {
          json.status = status ?? 200;
          json.data = data;
        }),
        error: vi.fn(),
      },
    );

    const handled = await dispatcher({
      method: "POST",
      path: "/workspaces/w1/applets/a1/edit-session",
      url: new URL("http://localhost/workspaces/w1/applets/a1/edit-session"),
      req: {} as never,
      res: {} as never,
    });

    expect(handled).toBe(true);
    expect(storage.createSession).toHaveBeenCalledWith("Edit: JSON Inspector", "openai/test");
    expect(sessions.startSession).toHaveBeenCalledWith("edit-1", workspace);
    expect(sessions.setPendingPromptPreamble).toHaveBeenCalledTimes(1);
    expect(sessions.setPendingPromptPreamble.mock.calls[0]?.[0]).toBe("edit-1");
    expect(sessions.setPendingPromptPreamble.mock.calls[0]?.[1]).toContain("get_applet(appletId)");
    expect(json.status).toBe(201);
    expect((json.data as { session: Session }).session.id).toBe("edit-1");
  });
});
