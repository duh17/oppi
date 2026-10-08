import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import { SessionLifecycleService } from "../src/session-lifecycle-service.js";
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
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
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
  sendFollowUp: ReturnType<typeof vi.fn>;
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
    sendFollowUp: vi.fn(async () => undefined),
  };
}

describe("session restart resume", () => {
  it("rebinds a durable session without synthesizing a continuation user turn", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "durable", {
      workspaceId: workspace.id,
      status: "stopped",
      serverDurable: { conversationId: 1 },
    });
    storage.queueRestartResume([{ sessionId: "durable", wasBusy: true }], 1);
    const deps = makeDeps(storage);
    expect(await resumeSessionsAfterRestart(deps)).toEqual([
      { sessionId: "durable", outcome: "resumed" },
    ]);
    expect(deps.resumed).toEqual(["durable"]);
    expect(deps.sendPrompt).not.toHaveBeenCalled();
    expect(deps.sendFollowUp).not.toHaveBeenCalled();
  });
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

  describe("program status across a restart", () => {
    it("keeps done and error on stopped sessions and drops runs the crash cut short", () => {
      const { storage, workspace } = makeStorage();
      const ws = { workspaceId: workspace.id };
      saveSession(storage, "finished", {
        ...ws,
        status: "ready",
        programStatus: { state: "done", message: "Fix login", since: 111 },
      });
      saveSession(storage, "failed-run", {
        ...ws,
        status: "stopped",
        programStatus: { state: "error", since: 222 },
      });
      saveSession(storage, "mid-run", {
        ...ws,
        status: "busy",
        programStatus: { state: "working", message: "Fix login", since: 333 },
      });
      saveSession(storage, "mid-start", {
        ...ws,
        status: "starting",
        programStatus: { state: "error", since: 888 },
      });
      saveSession(storage, "mid-dialog", {
        ...ws,
        status: "busy",
        programStatus: { state: "blocked", kind: "question", since: 444 },
      });
      // Rows an older server wrote: no program status. Storage.saveSession would derive one, so
      // write them straight to the table.
      const legacyWriter = new SessionSqliteStore(storage.getDataDir());
      const legacy = (id: string, status: Session["status"], lastActivity: number) =>
        legacyWriter.saveSession({
          id,
          ...ws,
          status,
          createdAt: 1,
          lastActivity,
          messageCount: 1,
          tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          cost: 0,
        });
      legacy("legacy", "stopped", 555);
      legacy("legacy-error", "error", 666);

      queueOrphanedSessionsForRestart(storage, 9_000);

      const status = (id: string) => storage.getSession(id)?.programStatus;
      expect(status("finished")).toEqual({ state: "done", since: 111 });
      expect(status("failed-run")).toEqual({ state: "error", since: 222 });
      expect(status("mid-run")).toEqual({ state: "idle", since: 9_000 });
      expect(status("mid-dialog")).toEqual({ state: "idle", since: 9_000 });
      expect(status("mid-start")).toEqual({ state: "error", since: 888 });
      expect(status("legacy")).toEqual({ state: "idle", since: 555 });
      expect(status("legacy-error")).toEqual({ state: "error", since: 666 });
    });

    it("is read back by a fresh process, on both list projections", () => {
      const { storage, workspace } = makeStorage();
      saveSession(storage, "s1", {
        workspaceId: workspace.id,
        status: "stopped",
        lastActivity: 5_000,
        programStatus: { state: "error", since: 4_000 },
      });
      const dataDir = storage.getDataDir();

      const reopened = new Storage(dataDir);
      expect(reopened.getSession("s1")?.programStatus).toEqual({ state: "error", since: 4_000 });
      const stopped = reopened.listStoppedWorkspaceTimeRangeSessionSnapshots(
        workspace.id,
        0,
        10_000,
      );
      expect(stopped.find((session) => session.id === "s1")?.programStatus).toEqual({
        state: "error",
        since: 4_000,
      });
    });
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
      saveSession(storage, "busy-on-its-own", { ...ws, status: "busy" }),
      saveSession(storage, "control", {
        status: "busy",
        control: { domain: "server", intent: "inspect" } as Session["control"],
      }),
      saveSession(storage, "incognito", { ...ws, status: "busy", ephemeral: true }),
    ];
    recordLiveSessionsForRestart(storage, live);
    for (const session of live) saveSession(storage, session.id, { ...session, status: "stopped" });

    // An extension started a turn at startup before the resume reached it.
    const deps = makeDeps(storage, (id) => (id === "busy-on-its-own" ? "busy" : "ready"));
    const results = await resumeSessionsAfterRestart(deps);

    expect(Object.fromEntries(results.map((r) => [r.sessionId, r.outcome]))).toEqual({
      "mid-turn": "continued",
      idle: "resumed",
      "busy-on-its-own": "continued",
      control: "continued",
    });
    expect(deps.sendPrompt.mock.calls.sort()).toEqual([
      ["control", RESTART_CONTINUE_PROMPT],
      ["mid-turn", RESTART_CONTINUE_PROMPT],
    ]);
    expect(deps.sendFollowUp.mock.calls).toEqual([["busy-on-its-own", RESTART_CONTINUE_PROMPT]]);
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

  it("still continues a session the app reopened before its resume", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const { sdkBackend } = makeSdkBackendStub();
    const create = vi.spyOn(SdkBackend, "create").mockResolvedValue(sdkBackend);
    const manager = new SessionManager(storage);
    try {
      // The app reconnects and reopens the focused session first.
      await manager.startSession("s1", workspace);
      const deps = makeDeps(storage);

      const [result] = await resumeSessionsAfterRestart(deps);

      expect(result?.outcome).toBe("continued");
      expect(deps.sendPrompt.mock.calls).toEqual([["s1", RESTART_CONTINUE_PROMPT]]);
    } finally {
      await manager.stopAll().catch(() => {});
      create.mockRestore();
    }
  });

  it("falls back to a follow-up when the continuation prompt is refused", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const deps = makeDeps(storage);
    deps.sendPrompt.mockRejectedValue(new Error("agent is busy"));

    const [result] = await resumeSessionsAfterRestart(deps);

    expect(result).toMatchObject({ outcome: "continued", reason: "queued as follow-up" });
    expect(deps.sendFollowUp.mock.calls).toEqual([["s1", RESTART_CONTINUE_PROMPT]]);
  });

  it("keeps every entry and skips the continuation when shutdown interrupts a resume", async () => {
    const { storage, workspace } = makeStorage();
    const ws = { workspaceId: workspace.id, status: "stopped" as const };
    saveSession(storage, "first", ws);
    saveSession(storage, "second", ws);
    storage.queueRestartResume(
      [
        { sessionId: "first", wasBusy: true },
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
    expect(deps.sendPrompt).not.toHaveBeenCalled();
    expect(storage.listRestartResume()).toEqual([
      { sessionId: "first", wasBusy: true },
      { sessionId: "second", wasBusy: false },
    ]);
  });

  it("does not resume a queued session the user stopped before its turn", async () => {
    const { storage, workspace } = makeStorage();
    const session = saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const lifecycle = new SessionLifecycleService({
      storage,
      sessions: {} as never,
      sessionRuntimes: { isSessionConnected: () => false } as never,
      ensureSessionContextWindow: (s) => s,
    });

    await lifecycle.stopSession(session);
    const deps = makeDeps(storage);
    await resumeSessionsAfterRestart(deps);

    expect(deps.resumed).toEqual([]);
    expect(deps.sendPrompt).not.toHaveBeenCalled();
  });

  it("keeps the entry queued until its continuation is sent", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const { sdkBackend } = makeSdkBackendStub();
    const create = vi.spyOn(SdkBackend, "create").mockResolvedValue(sdkBackend);
    const manager = new SessionManager(storage);
    try {
      const deps = makeDeps(storage);
      const queuedAtContinuation: unknown[] = [];
      // The resume's own start goes through the real SessionManager.
      deps.lifecycle.resumeWorkspaceSession = async ({ session }) =>
        ({ session: await manager.startSession(session.id, workspace) }) as never;
      deps.sendPrompt.mockImplementation(async () => {
        // A crash here must still find the entry, busy flag included.
        queuedAtContinuation.push(...storage.listRestartResume());
      });

      await resumeSessionsAfterRestart(deps);

      expect(queuedAtContinuation).toEqual([{ sessionId: "s1", wasBusy: true }]);
      expect(storage.listRestartResume()).toEqual([]);
    } finally {
      await manager.stopAll().catch(() => {});
      create.mockRestore();
    }
  });

  it("sends no continuation when the user stops the session while it resumes", async () => {
    const { storage, workspace } = makeStorage();
    const session = saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const lifecycle = new SessionLifecycleService({
      storage,
      sessions: {} as never,
      sessionRuntimes: { isSessionConnected: () => false } as never,
      ensureSessionContextWindow: (s) => s,
    });
    const deps = makeDeps(storage);
    const resumeWorkspaceSession = deps.lifecycle.resumeWorkspaceSession;
    deps.lifecycle.resumeWorkspaceSession = async (params) => {
      const result = await resumeWorkspaceSession(params);
      await lifecycle.stopSession(session);
      return result;
    };

    const [result] = await resumeSessionsAfterRestart(deps);

    expect(result?.reason).toBe("taken over during resume");
    expect(deps.sendPrompt).not.toHaveBeenCalled();
  });

  it("sends no continuation when the user messages the session during its resume", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    storage.queueRestartResume([{ sessionId: "s1", wasBusy: true }], 1);
    const { sdkBackend } = makeSdkBackendStub();
    const create = vi.spyOn(SdkBackend, "create").mockResolvedValue(sdkBackend);
    const manager = new SessionManager(storage);
    try {
      const deps = makeDeps(storage);
      deps.lifecycle.resumeWorkspaceSession = async ({ session }) => {
        const live = await manager.startSession(session.id, workspace);
        // The user sends their own message while the resume is running.
        await manager.sendPrompt(session.id, "do this instead").catch(() => undefined);
        return { session: { ...live, status: "ready" } } as never;
      };

      const [result] = await resumeSessionsAfterRestart(deps);

      expect(result?.reason).toBe("taken over during resume");
      expect(deps.sendPrompt).not.toHaveBeenCalled();
      expect(deps.sendFollowUp).not.toHaveBeenCalled();
    } finally {
      await manager.stopAll().catch(() => {});
      create.mockRestore();
    }
  });

  it("drops a session start that finishes after the manager closed", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "s1", { workspaceId: workspace.id, status: "stopped" });
    const { sdkBackend, dispose } = makeSdkBackendStub();
    let finishCreate!: () => void;
    const create = vi
      .spyOn(SdkBackend, "create")
      .mockImplementation(
        () => new Promise((resolve) => (finishCreate = () => resolve(sdkBackend))),
      );
    const manager = new SessionManager(storage);
    try {
      const start = manager.startSession("s1", workspace);
      await vi.waitFor(() => expect(create).toHaveBeenCalled());
      await manager.close();
      // A replacement server sharing this storage owns the row now.
      saveSession(storage, "s1", { workspaceId: workspace.id, status: "busy" });
      finishCreate();

      await expect(start).rejects.toThrow(/stopping/);
      expect(manager.isActive("s1")).toBe(false);
      expect(dispose).toHaveBeenCalled();
      expect(storage.getSession("s1")?.status).toBe("busy");
      await expect(manager.startSession("s1", workspace)).rejects.toThrow(/stopping/);
    } finally {
      create.mockRestore();
    }
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
