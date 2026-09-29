import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

import {
  RESTART_CONTINUE_PROMPT,
  queueOrphanedSessionsForRestart,
  recordLiveSessionsForRestart,
  resumeSessionsAfterRestart,
  type RestartResumeDeps,
} from "../src/session-restart-resume.js";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function makeStorage(): { storage: Storage; workspace: Workspace } {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-restart-resume-"));
  dirs.push(dataDir);
  const storage = new Storage(dataDir);
  const workspace = storage.createWorkspace({ name: "project", hostMount: dataDir });
  return { storage, workspace };
}

function saveSession(
  storage: Storage,
  id: string,
  fields: Partial<Session> & Pick<Session, "status">,
): Session {
  const session: Session = {
    id,
    createdAt: 1,
    lastActivity: 1,
    messageCount: 1,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...fields,
  };
  storage.saveSession(session);
  return session;
}

/** Lifecycle fake: resuming returns the session as the runtime reports it. */
function makeDeps(
  storage: Storage,
  resumedStatus: (id: string) => Session["status"] = () => "ready",
): RestartResumeDeps & {
  sendPrompt: ReturnType<typeof vi.fn>;
  resumed: string[];
} {
  const resumed: string[] = [];
  const resume = async (session: Session) => {
    resumed.push(session.id);
    return { session: { ...session, status: resumedStatus(session.id) } } as never;
  };
  return {
    storage,
    resumed,
    lifecycle: {
      resumeWorkspaceSession: ({ session }) => resume(session),
      resumeControlSession: (session) => resume(session),
    },
    sendPrompt: vi.fn(async () => undefined),
  };
}

describe("session restart resume", () => {
  it("queues sessions left running by a crash and marks every running one stopped", () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id };
    saveSession(storage, "busy", { ...ws, status: "busy", currentTurnStartedAt: 5 });
    saveSession(storage, "idle", { ...ws, status: "ready" });
    saveSession(storage, "starting", { ...ws, status: "starting" });
    saveSession(storage, "stopping", { ...ws, status: "stopping" });
    saveSession(storage, "incognito", { ...ws, status: "busy", ephemeral: true });
    saveSession(storage, "mirror", { ...ws, status: "busy", runtime: "pi-tui" });
    saveSession(storage, "control", {
      status: "ready",
      control: { domain: "server", intent: "inspect" } as Session["control"],
    });
    saveSession(storage, "done", { ...ws, status: "stopped" });
    saveSession(storage, "failed", { ...ws, status: "error" });

    queueOrphanedSessionsForRestart(storage);

    expect(storage.listRestartResume()).toEqual(
      expect.arrayContaining([
        { sessionId: "busy", wasBusy: true },
        { sessionId: "idle", wasBusy: false },
        { sessionId: "starting", wasBusy: false },
        { sessionId: "control", wasBusy: false },
      ]),
    );
    expect(storage.listRestartResume()).toHaveLength(4);
    for (const id of ["busy", "idle", "starting", "stopping", "incognito", "mirror", "control"]) {
      expect(storage.getSession(id)?.status, id).toBe("stopped");
    }
    expect(storage.getSession("busy")?.currentTurnStartedAt).toBeUndefined();
    expect(storage.getSession("failed")?.status).toBe("error");
  });

  it("keeps the resume queued when marking crash orphans stopped fails partway", () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "a", { workspaceId: workspace.id, status: "busy" });
    saveSession(storage, "b", { workspaceId: workspace.id, status: "ready" });
    const failing = {
      listSessions: () => storage.listSessions(),
      queueRestartResume: storage.queueRestartResume.bind(storage),
      saveSession: () => {
        throw new Error("disk full");
      },
    };

    expect(() => queueOrphanedSessionsForRestart(failing)).toThrow("disk full");

    expect(storage.listRestartResume()).toEqual(
      expect.arrayContaining([
        { sessionId: "a", wasBusy: true },
        { sessionId: "b", wasBusy: false },
      ]),
    );
  });

  it("does not record a session that was being stopped at shutdown", () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id };
    recordLiveSessionsForRestart(storage, [
      saveSession(storage, "stopping", { ...ws, status: "stopping" }),
      saveSession(storage, "busy", { ...ws, status: "busy" }),
    ]);

    expect(storage.listRestartResume()).toEqual([{ sessionId: "busy", wasBusy: true }]);
  });

  it("keeps a session busy when a shutdown record and a crash both queue it", () => {
    const { storage, workspace } = makeStorage();
    const live = saveSession(storage, "s1", { workspaceId: workspace.id, status: "busy" });
    recordLiveSessionsForRestart(storage, [live]);
    // The stop flow died before persisting `stopped`; the next start sees it idle.
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "ready" });

    queueOrphanedSessionsForRestart(storage);

    expect(storage.listRestartResume()).toEqual([{ sessionId: "s1", wasBusy: true }]);
  });

  it("resumes every queued session and continues only the ones stopped mid-turn", async () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id };
    const live = [
      saveSession(storage, "mid-turn", { ...ws, status: "busy" }),
      saveSession(storage, "idle", { ...ws, status: "ready" }),
      saveSession(storage, "prompted-meanwhile", { ...ws, status: "busy" }),
      saveSession(storage, "control", {
        status: "busy",
        control: { domain: "server", intent: "inspect" } as Session["control"],
      }),
      saveSession(storage, "incognito", { ...ws, status: "busy", ephemeral: true }),
    ];
    recordLiveSessionsForRestart(storage, live);
    for (const session of live) saveSession(storage, session.id, { ...session, status: "stopped" });

    const deps = makeDeps(storage, (id) => (id === "prompted-meanwhile" ? "busy" : "ready"));
    const results = await resumeSessionsAfterRestart(deps);

    expect(Object.fromEntries(results.map((r) => [r.sessionId, r.outcome]))).toEqual({
      "mid-turn": "continued",
      idle: "resumed",
      "prompted-meanwhile": "resumed",
      control: "continued",
    });
    expect(deps.sendPrompt.mock.calls.sort()).toEqual([
      ["control", RESTART_CONTINUE_PROMPT],
      ["mid-turn", RESTART_CONTINUE_PROMPT],
    ]);
    expect(storage.listRestartResume()).toEqual([]);
  });

  it("clears entries it cannot resume and reports why", async () => {
    const { storage, workspace } = makeStorage();
    storage.queueRestartResume(
      [
        { sessionId: "deleted", wasBusy: true },
        { sessionId: "orphan-workspace", wasBusy: true },
        { sessionId: "broken", wasBusy: true },
      ],
      1,
    );
    saveSession(storage, "orphan-workspace", { workspaceId: "gone", status: "stopped" });
    saveSession(storage, "broken", { workspaceId: workspace.id, status: "stopped" });

    const deps = makeDeps(storage);
    deps.lifecycle.resumeWorkspaceSession = async () => {
      throw new Error("model auth expired");
    };
    const results = await resumeSessionsAfterRestart(deps);

    expect(results).toEqual(
      expect.arrayContaining([
        { sessionId: "deleted", outcome: "skipped", reason: "session deleted" },
        { sessionId: "orphan-workspace", outcome: "skipped", reason: "workspace deleted" },
        { sessionId: "broken", outcome: "failed", reason: "model auth expired" },
      ]),
    );
    expect(results).toHaveLength(3);
    expect(deps.sendPrompt).not.toHaveBeenCalled();
    expect(storage.listRestartResume()).toEqual([]);
  });

  it("leaves a session alone once any other start has claimed it", async () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id, status: "stopped" as const };
    saveSession(storage, "first", ws);
    saveSession(storage, "second", ws);
    storage.queueRestartResume(
      [
        { sessionId: "first", wasBusy: true },
        { sessionId: "second", wasBusy: true },
      ],
      1,
    );
    const { sdkBackend } = makeSdkBackendStub();
    const create = vi.spyOn(SdkBackend, "create").mockResolvedValue(sdkBackend);
    const manager = new SessionManager(storage);
    try {
      const deps = makeDeps(storage);
      const resumeWorkspaceSession = deps.lifecycle.resumeWorkspaceSession;
      deps.lifecycle.resumeWorkspaceSession = async (params) => {
        // While "first" resumes, a client opens "second" (and may stop it again).
        if (params.session.id === "first") await manager.startSession("second", workspace);
        return resumeWorkspaceSession(params);
      };

      const results = await resumeSessionsAfterRestart(deps);

      expect(deps.resumed).toEqual(["first"]);
      expect(deps.sendPrompt.mock.calls).toEqual([["first", RESTART_CONTINUE_PROMPT]]);
      expect(results.map((r) => r.sessionId)).toEqual(["first"]);
    } finally {
      await manager.stopAll().catch(() => {});
      create.mockRestore();
    }
  });

  it("stops before the next entry when cancelled and keeps the rest queued", async () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id, status: "stopped" as const };
    saveSession(storage, "first", ws);
    saveSession(storage, "second", ws);
    storage.queueRestartResume(
      [
        { sessionId: "first", wasBusy: false },
        { sessionId: "second", wasBusy: false },
      ],
      1,
    );
    let cancelled = false;
    const deps = makeDeps(storage);
    const resumeWorkspaceSession = deps.lifecycle.resumeWorkspaceSession;
    deps.lifecycle.resumeWorkspaceSession = async (params) => {
      cancelled = true; // server shutdown begins while "first" is starting
      return resumeWorkspaceSession(params);
    };

    await resumeSessionsAfterRestart({ ...deps, cancelled: () => cancelled });

    expect(deps.resumed).toEqual(["first"]);
    expect(storage.listRestartResume()).toEqual([{ sessionId: "second", wasBusy: false }]);
  });

  it("keeps later entries queued while an earlier one is resuming", async () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id, status: "stopped" as const };
    saveSession(storage, "first", ws);
    saveSession(storage, "second", ws);
    storage.queueRestartResume(
      [
        { sessionId: "first", wasBusy: false },
        { sessionId: "second", wasBusy: false },
      ],
      1,
    );

    const queuedDuringFirst: string[][] = [];
    const deps = makeDeps(storage);
    const resumeWorkspaceSession = deps.lifecycle.resumeWorkspaceSession;
    deps.lifecycle.resumeWorkspaceSession = async (params) => {
      if (params.session.id === "first") {
        queuedDuringFirst.push(storage.listRestartResume().map((entry) => entry.sessionId));
      }
      return resumeWorkspaceSession(params);
    };
    await resumeSessionsAfterRestart(deps);

    expect(queuedDuringFirst).toEqual([["first", "second"]]);
  });
});
