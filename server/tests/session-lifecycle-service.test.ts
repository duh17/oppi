import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { RuntimeDisconnectedError } from "../src/agent-runtime-transport.js";
import {
  SessionLifecycleError,
  SessionLifecycleService,
  type SessionLifecycleServiceDeps,
} from "../src/session-lifecycle-service.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
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
    workspaceId: "ws-1",
    status: "ready",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...overrides,
  };
}

function makeService(
  options: {
    mirrorConnected?: boolean;
    live?: boolean;
    snapshot?: Session;
    active?: Session;
    started?: Session;
    storedSession?: Session;
    stopError?: Error;
    forkSession?: Session;
    runCommandError?: Error;
    sendPromptError?: Error;
    workspace?: Workspace;
    dataDir?: string;
  } = {},
): {
  service: SessionLifecycleService;
  createSession: ReturnType<typeof vi.fn>;
  deleteSession: ReturnType<typeof vi.fn>;
  deleteSearchIndexSession: ReturnType<typeof vi.fn>;
  getDataDir: ReturnType<typeof vi.fn>;
  getSession: ReturnType<typeof vi.fn>;
  getWorkspace: ReturnType<typeof vi.fn>;
  listSessions: ReturnType<typeof vi.fn>;
  saveSession: ReturnType<typeof vi.fn>;
  runCommand: ReturnType<typeof vi.fn>;
  sendPrompt: ReturnType<typeof vi.fn>;
  startSession: ReturnType<typeof vi.fn>;
  stopSession: ReturnType<typeof vi.fn>;
  stopSessionIfActive: ReturnType<typeof vi.fn>;
  isSessionConnected: ReturnType<typeof vi.fn>;
  isSessionLive: ReturnType<typeof vi.fn>;
  getSessionSnapshot: ReturnType<typeof vi.fn>;
  getActiveSession: ReturnType<typeof vi.fn>;
  refreshSessionState: ReturnType<typeof vi.fn>;
} {
  const createSession = vi.fn(
    (name?: string, model?: string) =>
      options.forkSession ?? makeSession({ id: "fork-1", name, model }),
  );
  const deleteSession = vi.fn(() => true);
  const deleteSearchIndexSession = vi.fn();
  const getDataDir = vi.fn(() => options.dataDir ?? join(tmpdir(), "oppi-lifecycle-service-test"));
  const getSession = vi.fn(() => options.storedSession);
  const getWorkspace = vi.fn(() => options.workspace);
  const listSessions = vi.fn(() => []);
  const saveSession = vi.fn();
  const runCommand = vi.fn(async () => {
    if (options.runCommandError) throw options.runCommandError;
  });
  const sendPrompt = vi.fn(async () => {
    if (options.sendPromptError) throw options.sendPromptError;
  });
  const startSession = vi.fn(async () => options.started ?? makeSession({ status: "ready" }));
  const stopSession = vi.fn(async () => {
    if (options.stopError) throw options.stopError;
  });
  const stopSessionIfActive = vi.fn(async () => null);
  const isSessionConnected = vi.fn(() => options.mirrorConnected === true);
  const isSessionLive = vi.fn(() => options.live === true);
  const getSessionSnapshot = vi.fn(() => options.snapshot);
  const getActiveSession = vi.fn(() => options.active);
  const refreshSessionState = vi.fn(async () => null);

  const deps: SessionLifecycleServiceDeps = {
    storage: {
      createSession,
      deleteSession,
      getDataDir,
      getSession,
      getWorkspace,
      listSessions,
      saveSession,
    },
    sessions: { runCommand, sendPrompt, startSession, stopSession },
    sessionRuntimes: {
      isSessionConnected,
      isSessionLive,
      getSessionSnapshot,
      getActiveSession,
      refreshSessionState,
      stopSession,
      stopSessionIfActive,
    },
    ensureSessionContextWindow: (session) => ({
      ...session,
      contextWindow: session.contextWindow ?? 200_000,
    }),
    deleteSearchIndexSession,
  };

  return {
    service: new SessionLifecycleService(deps),
    createSession,
    deleteSession,
    deleteSearchIndexSession,
    getDataDir,
    getSession,
    getWorkspace,
    listSessions,
    saveSession,
    runCommand,
    sendPrompt,
    startSession,
    stopSession,
    stopSessionIfActive,
    isSessionConnected,
    isSessionLive,
    getSessionSnapshot,
    getActiveSession,
    refreshSessionState,
  };
}

describe("SessionLifecycleService", () => {
  describe("createWorkspaceSession", () => {
    it("creates promptless managed sessions with workspace defaults and thinking state", async () => {
      const createdSession = makeSession({ id: "created-1" });
      const { service, createSession, saveSession, startSession, sendPrompt } = makeService({
        forkSession: createdSession,
      });

      const result = await service.createWorkspaceSession({
        workspace: makeWorkspace({ name: "Project", defaultModel: "openai/gpt-5.4" }),
        name: "New session",
        thinking: "high",
        ephemeral: true,
      });

      expect(createSession).toHaveBeenCalledWith("New session", "openai/gpt-5.4");
      expect(saveSession).toHaveBeenCalledTimes(2);
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        id: "created-1",
        workspaceId: "ws-1",
        workspaceName: "Project",
        thinkingLevel: "high",
        ephemeral: true,
        launch: { status: "accepted", promptDispatch: "not_sent" },
      });
      expect(startSession).not.toHaveBeenCalled();
      expect(sendPrompt).not.toHaveBeenCalled();
      expect(result.prompted).toBeUndefined();
      expect(result.session).toMatchObject({ id: "created-1", contextWindow: 200_000 });
      expect(result.createdSession).toMatchObject({ id: "created-1", contextWindow: 200_000 });
      expect(result.summarySession).toBeUndefined();
    });

    it("persists caller lineage for managed CLI child sessions", async () => {
      const parent = makeSession({ id: "parent-1" });
      const createdSession = makeSession({ id: "created-1" });
      const { service, saveSession } = makeService({
        forkSession: createdSession,
        storedSession: parent,
      });

      await service.createWorkspaceSession({
        workspace: makeWorkspace(),
        parentSessionId: parent.id,
      });

      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        id: "created-1",
        launch: { parentSessionId: "parent-1" },
      });
    });

    it("starts prompted sessions, records the first message, and reports summary updates", async () => {
      const createdSession = makeSession({ id: "created-1" });
      const { service, saveSession, startSession, sendPrompt } = makeService({
        forkSession: createdSession,
      });

      const result = await service.createWorkspaceSession({
        workspace: makeWorkspace(),
        prompt: "  Tell me about TypeScript  ",
        attachments: [
          {
            type: "attachment",
            id: "att-1",
            source: "workspace",
            name: "README.md",
            mimeType: "text/markdown",
            sizeBytes: 123,
            workspacePath: "README.md",
          },
        ],
      });

      expect(startSession).toHaveBeenCalledWith(
        "created-1",
        expect.objectContaining({ id: "ws-1" }),
      );
      expect(sendPrompt).toHaveBeenCalledWith("created-1", "Tell me about TypeScript", {
        attachments: [expect.objectContaining({ id: "att-1" })],
      });
      expect(saveSession).toHaveBeenCalledTimes(2);
      expect(saveSession.mock.calls[1]![0]).toMatchObject({
        id: "created-1",
        firstMessage: "Tell me about TypeScript",
      });
      expect(result.prompted).toBe(true);
      expect(result.session).toMatchObject({
        id: "created-1",
        firstMessage: "Tell me about TypeScript",
      });
      expect(result.summarySession).toMatchObject({
        id: "created-1",
        firstMessage: "Tell me about TypeScript",
      });
    });

    it("keeps created sessions when initial prompt dispatch fails", async () => {
      const createdSession = makeSession({ id: "created-1" });
      const { service, saveSession, sendPrompt } = makeService({
        forkSession: createdSession,
        sendPromptError: new Error("pi not ready"),
      });

      const result = await service.createWorkspaceSession({
        workspace: makeWorkspace(),
        prompt: "hello",
      });

      expect(sendPrompt).toHaveBeenCalledWith("created-1", "hello", {});
      expect(saveSession).toHaveBeenCalledTimes(2);
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        id: "created-1",
        launch: { status: "failed", promptDispatch: "not_sent", promptError: "pi not ready" },
      });
      expect(result.prompted).toBe(false);
      expect(result.summarySession).toBeUndefined();
      expect(result.session).toMatchObject({ id: "created-1" });
      expect(result.session).not.toHaveProperty("firstMessage");
    });
  });

  describe("createControlSession", () => {
    it("creates a workspace-less Default Agent session and dispatches its starter prompt", async () => {
      const createdSession = makeSession({ id: "control-1", workspaceId: undefined });
      const { service, createSession, saveSession, startSession, sendPrompt } = makeService({
        forkSession: createdSession,
      });

      const result = await service.createControlSession({
        control: {
          domain: "agents",
          intent: "revise",
          targetId: "release-reviewer",
          targetName: "Release Reviewer",
        },
        name: "Revise Release Reviewer",
        prompt: "Help me revise this Agent.",
      });

      expect(createSession).toHaveBeenCalledWith("Revise Release Reviewer", undefined);
      expect(saveSession.mock.calls[0]?.[0]).toMatchObject({
        id: "control-1",
        workspaceId: undefined,
        runtime: "oppi",
        control: {
          domain: "agents",
          intent: "revise",
          targetId: "release-reviewer",
          targetName: "Release Reviewer",
        },
        launch: {
          source: "human",
          agentId: "oppi-default-agent",
          target: { server: true, displayCwd: "Oppi Control" },
          tools: { allowed: ["oppi"], noTools: "builtin" },
        },
      });
      expect(startSession).toHaveBeenCalledWith("control-1", undefined);
      expect(sendPrompt).toHaveBeenCalledWith("control-1", "Help me revise this Agent.", {});
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        firstMessage: "Help me revise this Agent.",
        launch: { status: "accepted", promptDispatch: "delivered" },
      });
      expect(result.session).toMatchObject({
        id: "control-1",
        workspaceId: undefined,
        contextWindow: 200_000,
      });
      expect(result.prompted).toBe(true);
    });

    it("resumes declared control sessions without a workspace", async () => {
      const controlSession = makeSession({
        id: "control-1",
        workspaceId: undefined,
        status: "stopped",
        runtime: "oppi",
        control: { domain: "workspaces", intent: "create" },
      });
      const started = makeSession({
        ...controlSession,
        status: "ready",
      });
      const { service, startSession } = makeService({ started });

      const result = await service.resumeControlSession(controlSession);

      expect(startSession).toHaveBeenCalledWith("control-1", undefined);
      expect(result).toMatchObject({ owner: "oppi", startedSession: true });
      expect(result.session).toMatchObject({
        id: "control-1",
        workspaceId: undefined,
        control: { domain: "workspaces", intent: "create" },
        status: "ready",
      });
    });
  });

  describe("resumeWorkspaceSession", () => {
    it("keeps connected terminal mirror sessions terminal-owned", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        mirror: { status: "disconnected" },
        piSessionFile: "/tmp/mirror.jsonl",
      });
      const snapshot = makeSession({
        id: "sess-1",
        runtime: "pi-tui",
        mirror: { status: "connected" },
      });
      const { service, startSession, saveSession, getSessionSnapshot } = makeService({
        mirrorConnected: true,
        snapshot,
      });

      const result = await service.resumeWorkspaceSession({
        session: mirrorSession,
        workspace: makeWorkspace(),
      });

      expect(result).toMatchObject({ owner: "pi-tui", startedSession: false });
      expect(result.session).toMatchObject({
        id: "sess-1",
        runtime: "pi-tui",
        mirror: { status: "connected" },
        contextWindow: 200_000,
      });
      expect(getSessionSnapshot).toHaveBeenCalledWith("sess-1");
      expect(startSession).not.toHaveBeenCalled();
      expect(saveSession).not.toHaveBeenCalled();
    });

    it("promotes stopped disconnected mirror sessions before resuming through the SDK", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        status: "stopped",
        mirror: { status: "disconnected" },
        piSessionFile: "/tmp/stopped-mirror.jsonl",
      });
      const started = makeSession({ runtime: "oppi", status: "ready" });
      const { service, startSession, saveSession } = makeService({ started });

      const result = await service.resumeWorkspaceSession({
        session: mirrorSession,
        workspace: makeWorkspace(),
      });

      expect(saveSession).toHaveBeenCalledWith(
        expect.objectContaining({
          id: "sess-1",
          runtime: "oppi",
          mirror: undefined,
          piSessionFile: "/tmp/stopped-mirror.jsonl",
          piSessionFiles: ["/tmp/stopped-mirror.jsonl"],
        }),
      );
      expect(startSession).toHaveBeenCalledWith("sess-1", expect.objectContaining({ id: "ws-1" }));
      expect(result).toMatchObject({ owner: "oppi", startedSession: true });
      expect(result.session).toMatchObject({ runtime: "oppi", status: "ready" });
    });

    it("keeps removed-worktree sessions archived instead of resuming them in main", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "stopped",
        worktreeId: "wt_removed",
      });
      const { service, startSession } = makeService({
        dataDir: join(tmpdir(), "oppi-lifecycle-removed-worktree"),
      });

      await expect(
        service.resumeWorkspaceSession({
          session,
          workspace: makeWorkspace({ hostMount: join(tmpdir(), "oppi-lifecycle-main") }),
        }),
      ).rejects.toMatchObject({
        name: "SessionLifecycleError",
        statusCode: 409,
        message: "Session worktree is no longer available",
      } satisfies Partial<SessionLifecycleError>);
      expect(startSession).not.toHaveBeenCalled();
    });

    it("returns already-live managed sessions without restarting", async () => {
      const session = makeSession({ runtime: "oppi", status: "ready" });
      const active = makeSession({ id: "sess-1", runtime: "oppi", status: "busy" });
      const { service, startSession, getActiveSession } = makeService({ live: true, active });

      const result = await service.resumeWorkspaceSession({ session, workspace: makeWorkspace() });

      expect(getActiveSession).toHaveBeenCalledWith("sess-1");
      expect(startSession).not.toHaveBeenCalled();
      expect(result).toMatchObject({ owner: "oppi", startedSession: false });
      expect(result.session).toMatchObject({ status: "busy", contextWindow: 200_000 });
    });
  });

  describe("openFocusedSession", () => {
    it("keeps reloading mirror sessions bound to the mirror runtime", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        status: "ready",
        mirror: {
          status: "connected",
          terminal: { disconnectReason: "reload" },
        },
        piSessionFile: "/tmp/reloading.jsonl",
      });
      const { service, startSession, saveSession } = makeService({ mirrorConnected: false });

      const result = await service.openFocusedSession({ session: mirrorSession });

      expect(result).toMatchObject({ owner: "pi-tui", startedSession: false });
      expect(result.session).toMatchObject({ runtime: "pi-tui", contextWindow: 200_000 });
      expect(startSession).not.toHaveBeenCalled();
      expect(saveSession).not.toHaveBeenCalled();
    });

    it("keeps a busy disconnected mirror terminal-owned instead of taking over mid-turn", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        status: "busy",
        currentTurnStartedAt: 10,
        mirror: { status: "disconnected" },
        piSessionFile: "/tmp/busy-mirror.jsonl",
      });
      const { service, startSession, saveSession } = makeService({ mirrorConnected: false });

      const result = await service.openFocusedSession({
        session: mirrorSession,
        workspace: makeWorkspace(),
      });

      expect(result).toMatchObject({ owner: "pi-tui", startedSession: false });
      expect(result.session).toMatchObject({
        runtime: "pi-tui",
        status: "busy",
        currentTurnStartedAt: 10,
        mirror: { status: "disconnected" },
      });
      expect(startSession).not.toHaveBeenCalled();
      expect(saveSession).not.toHaveBeenCalled();
    });

    it("promotes ready disconnected mirror sessions when a focused stream opens", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        status: "ready",
        mirror: { status: "disconnected" },
        piSessionFile: "/tmp/ready-mirror.jsonl",
      });
      const started = makeSession({ runtime: "oppi", status: "ready" });
      const { service, startSession, saveSession } = makeService({ started });

      const result = await service.openFocusedSession({
        session: mirrorSession,
        workspace: makeWorkspace(),
      });

      expect(saveSession).toHaveBeenCalledWith(expect.objectContaining({ runtime: "oppi" }));
      expect(startSession).toHaveBeenCalledWith("sess-1", expect.objectContaining({ id: "ws-1" }));
      expect(result).toMatchObject({ owner: "oppi", startedSession: true });
    });

    it("does not open removed-worktree sessions in the main checkout", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "stopped",
        worktreeId: "wt_removed",
      });
      const { service, startSession } = makeService({
        dataDir: join(tmpdir(), "oppi-lifecycle-removed-worktree"),
      });

      await expect(
        service.openFocusedSession({
          session,
          workspace: makeWorkspace({ hostMount: join(tmpdir(), "oppi-lifecycle-main") }),
        }),
      ).rejects.toMatchObject({
        name: "SessionLifecycleError",
        statusCode: 409,
        message: "Session worktree is no longer available",
      } satisfies Partial<SessionLifecycleError>);
      expect(startSession).not.toHaveBeenCalled();
    });

    it("keeps the focused stream started-session metric false for active managed sessions", async () => {
      const session = makeSession({ runtime: "oppi" });
      const started = makeSession({ runtime: "oppi", status: "busy" });
      const { service, startSession } = makeService({ live: true, started });

      const result = await service.openFocusedSession({ session, workspace: makeWorkspace() });

      expect(startSession).toHaveBeenCalledWith("sess-1", expect.objectContaining({ id: "ws-1" }));
      expect(result).toMatchObject({ owner: "oppi", startedSession: false });
      expect(result.session).toMatchObject({ status: "busy", contextWindow: 200_000 });
    });
  });

  describe("importLocalSession", () => {
    it("imports local Pi JSONL sessions as stopped terminal-owned sessions", async () => {
      const piSessionsRoot = getPiSessionsRoot();
      mkdirSync(piSessionsRoot, { recursive: true });
      const piSessionDir = mkdtempSync(join(piSessionsRoot, "oppi-lifecycle-import-"));
      const workspaceDir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-workspace-"));
      const jsonlPath = join(piSessionDir, "session.jsonl");
      writeFileSync(
        jsonlPath,
        [
          JSON.stringify({
            type: "session",
            id: "pi-session-1",
            cwd: workspaceDir,
            timestamp: "2026-05-03T00:00:00.000Z",
          }),
          JSON.stringify({ type: "session_info", name: "Imported Name" }),
          JSON.stringify({ type: "message", message: { role: "user", content: "Hello import" } }),
          "",
        ].join("\n"),
      );
      const importedSession = makeSession({ id: "imported-1" });
      const { service, createSession, saveSession } = makeService({
        forkSession: importedSession,
      });

      try {
        const result = await service.importLocalSession({
          workspace: makeWorkspace({ name: "Project", hostMount: workspaceDir }),
          piSessionFile: jsonlPath,
        });

        expect(createSession).toHaveBeenCalledWith("Imported Name", undefined);
        expect(saveSession).toHaveBeenCalledWith(
          expect.objectContaining({
            id: "imported-1",
            workspaceId: "ws-1",
            workspaceName: "Project",
            firstMessage: "Hello import",
            piSessionFile: jsonlPath,
            piSessionFiles: [jsonlPath],
            piSessionId: "pi-session-1",
            runtime: "pi-tui",
            status: "stopped",
            mirror: { status: "disconnected" },
          }),
        );
        expect(result.created).toBe(true);
        expect(result.session).toMatchObject({ id: "imported-1", contextWindow: 200_000 });
      } finally {
        rmSync(piSessionDir, { recursive: true, force: true });
        rmSync(workspaceDir, { recursive: true, force: true });
      }
    });
  });

  describe("forkSession", () => {
    it("creates a timeline fork with source trace ancestry and inherited settings", async () => {
      const sourceSession = makeSession({
        id: "source-1",
        workspaceId: "ws-1",
        name: "Original Session",
        model: "anthropic/claude-sonnet-4",
        piSessionFile: "/tmp/current.jsonl",
        piSessionFiles: ["/tmp/older.jsonl", "/tmp/current.jsonl"],
        thinkingLevel: "high",
        contextWindow: 200_000,
      });
      const forkSession = makeSession({ id: "fork-1" });
      const { service, createSession, saveSession, startSession, runCommand, refreshSessionState } =
        makeService({ forkSession });

      const result = await service.forkSession({
        workspace: makeWorkspace({ name: "Project" }),
        sourceSession,
        entryId: "entry-user-1",
      });

      expect(refreshSessionState).toHaveBeenCalledWith("source-1");
      expect(createSession).toHaveBeenCalledWith(
        "Fork: Original Session",
        "anthropic/claude-sonnet-4",
      );
      expect(saveSession).toHaveBeenCalledWith(
        expect.objectContaining({
          id: "fork-1",
          workspaceId: "ws-1",
          workspaceName: "Project",
          piSessionFile: "/tmp/current.jsonl",
          piSessionFiles: ["/tmp/older.jsonl", "/tmp/current.jsonl"],
          thinkingLevel: "high",
          contextWindow: 200_000,
        }),
      );
      expect(startSession).toHaveBeenCalledWith("fork-1", expect.objectContaining({ id: "ws-1" }));
      expect(runCommand).toHaveBeenCalledWith("fork-1", { type: "fork", entryId: "entry-user-1" });
      expect(refreshSessionState).toHaveBeenCalledWith("fork-1");
      expect(result.session).toMatchObject({ id: "fork-1", contextWindow: 200_000 });
    });

    it("uses requested fork names and workspace default model when the source has no model", async () => {
      const sourceSession = makeSession({ id: "source-1", piSessionFile: "/tmp/current.jsonl" });
      const { service, createSession } = makeService();

      await service.forkSession({
        workspace: makeWorkspace({ defaultModel: "openai/gpt-5.4" }),
        sourceSession,
        entryId: "entry-user-1",
        name: "  Custom fork name  ",
      });

      expect(createSession).toHaveBeenCalledWith("Custom fork name", "openai/gpt-5.4");
    });

    it("returns a typed conflict error when the source has no trace file", async () => {
      const sourceSession = makeSession({ id: "source-1", piSessionFile: undefined });
      const { service, createSession } = makeService();

      await expect(
        service.forkSession({
          workspace: makeWorkspace(),
          sourceSession,
          entryId: "entry-user-1",
        }),
      ).rejects.toMatchObject({
        name: "SessionLifecycleError",
        statusCode: 409,
        message: "Source session has no trace file to fork from",
      } satisfies Partial<SessionLifecycleError>);
      expect(createSession).not.toHaveBeenCalled();
    });

    it("cleans up the created fork if the Pi fork command fails", async () => {
      const sourceSession = makeSession({ id: "source-1", piSessionFile: "/tmp/current.jsonl" });
      const { service, deleteSession, stopSession } = makeService({
        runCommandError: new Error("fork command failed"),
      });

      await expect(
        service.forkSession({
          workspace: makeWorkspace(),
          sourceSession,
          entryId: "entry-user-1",
        }),
      ).rejects.toThrow("fork command failed");

      expect(stopSession).toHaveBeenCalledWith("fork-1");
      expect(deleteSession).toHaveBeenCalledWith("fork-1");
    });
  });

  describe("stopSession", () => {
    it("stops connected terminal mirror sessions through the runtime", async () => {
      const session = makeSession({ runtime: "pi-tui", status: "busy" });
      const storedSession = makeSession({ runtime: "pi-tui", status: "stopped" });
      const { service, stopSession, saveSession } = makeService({
        mirrorConnected: true,
        storedSession,
      });

      const result = await service.stopSession(session);

      expect(stopSession).toHaveBeenCalledWith("sess-1");
      expect(saveSession).not.toHaveBeenCalled();
      expect(result).toMatchObject({ storedStopOnly: false });
      expect(result.session).toMatchObject({ status: "stopped", contextWindow: 200_000 });
    });

    it("marks disconnected terminal mirror sessions stopped in storage", async () => {
      const session = makeSession({
        runtime: "pi-tui",
        status: "busy",
        currentTurnStartedAt: 10,
        mirror: {
          status: "disconnected",
          terminal: { lastSeenAt: 9 },
        },
      });
      const { service, stopSession, saveSession, getSession } = makeService();
      getSession.mockImplementation(() => saveSession.mock.calls.at(-1)?.[0] as Session);

      const result = await service.stopSession(session);

      expect(stopSession).not.toHaveBeenCalled();
      expect(saveSession).toHaveBeenCalledOnce();
      expect(result.storedStopOnly).toBe(true);
      expect(result.session).toMatchObject({
        runtime: "pi-tui",
        status: "stopped",
        currentTurnStartedAt: undefined,
        mirror: {
          status: "disconnected",
          terminal: { disconnectReason: "oppi_stop_disconnected_terminal" },
        },
      });
    });

    it("marks disconnected terminal mirrors stopped when the runtime reports a typed disconnect", async () => {
      const session = makeSession({ runtime: "pi-tui", status: "busy" });
      const { service, saveSession, getSession } = makeService({
        mirrorConnected: true,
        stopError: new RuntimeDisconnectedError("pi-tui", "pi-tui disconnected"),
      });
      getSession.mockImplementation(() => saveSession.mock.calls.at(-1)?.[0] as Session);

      const result = await service.stopSession(session);

      expect(saveSession).toHaveBeenCalledWith(
        expect.objectContaining({
          runtime: "pi-tui",
          status: "stopped",
          mirror: expect.objectContaining({ status: "disconnected" }),
        }),
      );
      expect(result.storedStopOnly).toBe(true);
    });

    it("does not recover from untyped disconnect-looking stop errors", async () => {
      const session = makeSession({ runtime: "pi-tui", status: "busy" });
      const { service, saveSession } = makeService({
        mirrorConnected: true,
        stopError: new Error("pi-tui disconnected"),
      });

      await expect(service.stopSession(session)).rejects.toThrow("pi-tui disconnected");
      expect(saveSession).not.toHaveBeenCalled();
    });

    it("throws non-disconnect runtime stop errors", async () => {
      const session = makeSession({ runtime: "pi-tui", status: "busy" });
      const { service, saveSession } = makeService({
        mirrorConnected: true,
        stopError: new Error("permission denied"),
      });

      await expect(service.stopSession(session)).rejects.toThrow("permission denied");
      expect(saveSession).not.toHaveBeenCalled();
    });
  });

  describe("deleteSession", () => {
    it("does not recreate the internal control cwd when deleting a control session", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-control-delete-"));
      const session = makeSession({
        id: "control-delete-1",
        workspaceId: undefined,
        control: { domain: "agents", intent: "create" },
      });
      const { service } = makeService({ dataDir });

      try {
        await service.deleteSession(session);
        expect(existsSync(join(dataDir, "control-sessions"))).toBe(false);
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    });

    it("stops active runtimes and deletes session metadata/search rows", async () => {
      const session = makeSession({ id: "delete-1", workspaceId: "ws-1" });
      const { service, stopSessionIfActive, deleteSession, deleteSearchIndexSession } =
        makeService();

      const result = await service.deleteSession(session);

      expect(stopSessionIfActive).toHaveBeenCalledWith("delete-1");
      expect(deleteSession).toHaveBeenCalledWith("delete-1");
      expect(deleteSearchIndexSession).toHaveBeenCalledWith("delete-1");
      expect(result).toEqual({
        session,
        deleted: {
          sqliteMetadata: true,
          localPiJsonlFiles: 0,
          workspaceAttachmentCopies: false,
          generatedMediaAttachments: false,
        },
      });
    });

    it("does not delete main-checkout attachments for removed-worktree sessions", async () => {
      const workspaceDir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-removed-worktree-delete-"));
      const mainAttachment = join(workspaceDir, ".pi", "attachments", "delete-1", "keep.txt");
      mkdirSync(join(workspaceDir, ".pi", "attachments", "delete-1"), { recursive: true });
      writeFileSync(mainAttachment, "keep main attachment");
      const workspace = makeWorkspace({ hostMount: workspaceDir });
      const session = makeSession({
        id: "delete-1",
        workspaceId: workspace.id,
        worktreeId: "wt_removed",
      });
      const { service } = makeService({ workspace });

      try {
        const result = await service.deleteSession(session);

        expect(result.deleted.workspaceAttachmentCopies).toBe(false);
        expect(existsSync(mainAttachment)).toBe(true);
      } finally {
        rmSync(workspaceDir, { recursive: true, force: true });
      }
    });

    it("reports when session metadata was already absent", async () => {
      const session = makeSession({ id: "delete-1", workspaceId: "ws-1" });
      const { service, deleteSession } = makeService();
      deleteSession.mockReturnValue(false);

      const result = await service.deleteSession(session);

      expect(result.deleted.sqliteMetadata).toBe(false);
    });
  });
});
