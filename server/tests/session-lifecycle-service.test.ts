import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { requiredModelLaunchFailureMessage } from "../src/agent-launch-service.js";
import { RuntimeDisconnectedError } from "../src/agent-runtime-transport.js";
import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { DEFAULT_AGENT_ID } from "../src/default-agent.js";
import {
  SessionLifecycleError,
  SessionLifecycleService,
  type SessionLifecycleServiceDeps,
} from "../src/session-lifecycle-service.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
import { buildSessionSummary } from "../src/session-summary.js";
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
    startSessionError?: Error;
    workspace?: Workspace;
    dataDir?: string;
    agentDefinitionStore?: AgentDefinitionStore;
    onStartSession?: () => void;
    deleteResourceUsageSession?: () => Promise<unknown> | unknown;
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
  const startSession = vi.fn(async () => {
    options.onStartSession?.();
    if (options.startSessionError) throw options.startSessionError;
    return options.started ?? makeSession({ status: "ready" });
  });
  const stopSession = vi.fn(async () => {
    if (options.stopError) throw options.stopError;
  });
  const stopSessionIfActive = vi.fn(async () => null);
  const isSessionConnected = vi.fn(() => options.mirrorConnected === true || options.live === true);
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
      getAgentDefinitionStore: () =>
        options.agentDefinitionStore ??
        ({
          getAgent: () => ({
            id: DEFAULT_AGENT_ID,
            name: "Oppi",
            status: "active",
            version: 1,
            definition: { name: "Oppi" },
            createdAt: 1,
            updatedAt: 1,
          }),
        } as AgentDefinitionStore),
    },
    sessions: { runCommand, sendPrompt, startSession, stopSession },
    sessionRuntimes: {
      isSessionConnected,
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
    deleteResourceUsageSession: options.deleteResourceUsageSession,
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
      expect(result.session.launch?.modelPolicy).toBeUndefined();
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
      expect(sendPrompt).toHaveBeenCalledWith(
        "created-1",
        "Tell me about TypeScript",
        expect.objectContaining({
          attachments: [expect.objectContaining({ id: "att-1" })],
          clientTurnId: "agent-launch:created-1",
          requestId: "agent-launch:created-1",
        }),
      );
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

    it("marks an explicit model as required and never dispatches its prompt after startup rejects it", async () => {
      const createdSession = makeSession({
        id: "created-1",
        model: "openai-codex/gpt-5.6-sol",
      });
      const modelError = new Error(
        'Required model "openai-codex/gpt-5.6-sol" is not available; refusing model fallback',
      );
      const { service, saveSession, startSession, sendPrompt } = makeService({
        forkSession: createdSession,
        startSessionError: modelError,
      });

      const result = await service.createWorkspaceSession({
        workspace: makeWorkspace(),
        model: "openai-codex/gpt-5.6-sol",
        prompt: "private implementation prompt",
      });

      expect(startSession).toHaveBeenCalledOnce();
      expect(sendPrompt).not.toHaveBeenCalled();
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        id: "created-1",
        model: "openai-codex/gpt-5.6-sol",
        status: "error",
        launch: {
          model: "openai-codex/gpt-5.6-sol",
          modelPolicy: "required",
          status: "failed",
          promptDispatch: "not_sent",
          promptError: modelError.message,
        },
      });
      expect(result).toMatchObject({
        prompted: false,
        session: {
          status: "error",
          launch: { modelPolicy: "required", promptError: modelError.message },
        },
      });
    });

    it("keeps non-model startup failures recoverable when an explicit model was requested", async () => {
      const createdSession = makeSession({
        id: "created-1",
        model: "openai-codex/gpt-5.6-sol",
      });
      const { service, saveSession, sendPrompt } = makeService({
        forkSession: createdSession,
        startSessionError: new Error("transport temporarily unavailable"),
      });

      const result = await service.createWorkspaceSession({
        workspace: makeWorkspace(),
        model: "openai-codex/gpt-5.6-sol",
        prompt: "retry this prompt later",
      });

      expect(sendPrompt).not.toHaveBeenCalled();
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        status: "ready",
        launch: {
          modelPolicy: "required",
          status: "failed",
          promptDispatch: "not_sent",
          promptError: "transport temporarily unavailable",
        },
      });
      expect(requiredModelLaunchFailureMessage(result.session)).toBeUndefined();
      expect(result.prompted).toBe(false);
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

      expect(sendPrompt).toHaveBeenCalledWith("created-1", "hello", {
        clientTurnId: "agent-launch:created-1",
        requestId: "agent-launch:created-1",
      });
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
    it("creates a workspace-less Oppi agent session and dispatches its starter prompt", async () => {
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
          agentVersion: 1,
          target: { server: true, displayCwd: "Oppi Control" },
          tools: { allowed: ["oppi", "ask", "read"], noTools: "builtin" },
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

    it("marks an explicit control-session model required and does not dispatch after startup rejects it", async () => {
      const createdSession = makeSession({
        id: "control-1",
        workspaceId: undefined,
        model: "openai-codex/gpt-5.6-sol",
      });
      const modelError = new Error(
        'Required model "openai-codex/gpt-5.6-sol" is not available; refusing model fallback',
      );
      const { service, saveSession, sendPrompt } = makeService({
        forkSession: createdSession,
        startSessionError: modelError,
      });

      const result = await service.createControlSession({
        control: { domain: "agents", intent: "create" },
        model: "openai-codex/gpt-5.6-sol",
        prompt: "private control prompt",
      });

      expect(sendPrompt).not.toHaveBeenCalled();
      expect(saveSession.mock.calls.at(-1)?.[0]).toMatchObject({
        status: "error",
        launch: {
          model: "openai-codex/gpt-5.6-sol",
          modelPolicy: "required",
          status: "failed",
          promptDispatch: "not_sent",
          promptError: modelError.message,
        },
      });
      expect(result).toMatchObject({
        prompted: false,
        session: { status: "error", launch: { modelPolicy: "required" } },
      });
    });

    it("snapshots customized Oppi agent presentation through lifecycle and summary", async () => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-control-agent-presentation-"));
      const agentDefinitionStore = new AgentDefinitionStore(dataDir);
      try {
        const customized = agentDefinitionStore.updateAgent(DEFAULT_AGENT_ID, {
          icon: { kind: "emoji", value: "🏠" },
        });
        expect(customized?.version).toBe(2);

        const { service } = makeService({
          dataDir,
          agentDefinitionStore,
          forkSession: makeSession({ id: "control-agent-icon", workspaceId: undefined }),
        });
        const result = await service.createControlSession({
          control: { domain: "agents", intent: "create" },
        });
        const summary = buildSessionSummary(result.session);

        expect(result.session.launch).toMatchObject({
          agentId: DEFAULT_AGENT_ID,
          agentVersion: 2,
          agentIcon: { kind: "emoji", value: "🏠" },
        });
        expect(summary).toMatchObject({
          agentId: DEFAULT_AGENT_ID,
          agentIcon: { kind: "emoji", value: "🏠" },
        });
      } finally {
        agentDefinitionStore.close();
        rmSync(dataDir, { recursive: true, force: true });
      }
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

    it("promotes stopped disconnected mirrors before managed construction reads latest settings", async () => {
      const mirrorSession = makeSession({
        runtime: "pi-tui",
        status: "stopped",
        mirror: { status: "disconnected" },
        piSessionFile: "/tmp/stopped-mirror.jsonl",
      });
      const started = makeSession({ runtime: "oppi", status: "ready" });
      let currentSettings = { enabled: false, approvalPolicy: "confirmDestructiveOnly" as const };
      const settingsReadAtManagedConstruction = vi.fn(() => currentSettings);
      const { service, startSession, saveSession } = makeService({
        started,
        onStartSession: settingsReadAtManagedConstruction,
      });
      currentSettings = { enabled: true, approvalPolicy: "confirmDestructiveOnly" };

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
      expect(settingsReadAtManagedConstruction).toHaveReturnedWith({
        enabled: true,
        approvalPolicy: "confirmDestructiveOnly",
      });
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

    it("retries a failed required-model session when the model becomes available", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "error",
        launch: {
          modelPolicy: "required",
          status: "failed",
          requestedAt: 1,
          promptDispatch: "not_sent",
          promptError: 'Required model "ds4/deepseek-v4-flash" is not available',
        },
      });
      const started = makeSession({ ...session, status: "ready" });
      const { service, startSession } = makeService({ started });

      const result = await service.resumeWorkspaceSession({
        session,
        workspace: makeWorkspace(),
      });

      expect(startSession).toHaveBeenCalledOnce();
      expect(result).toMatchObject({ owner: "oppi", startedSession: true });
      expect(result.session).toMatchObject({ status: "ready" });
    });

    it("returns a live explicit-model session after an unrelated initial prompt failure", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "error",
        model: "openai-codex/gpt-5.6-sol",
        launch: {
          model: "openai-codex/gpt-5.6-sol",
          modelPolicy: "required",
          status: "failed",
          requestedAt: 1,
          promptDispatch: "not_sent",
          promptError: "transport temporarily unavailable",
        },
      });
      const active = makeSession({ ...session, status: "ready" });
      const { service, startSession } = makeService({ live: true, active });

      const result = await service.resumeWorkspaceSession({
        session,
        workspace: makeWorkspace(),
      });

      expect(startSession).not.toHaveBeenCalled();
      expect(result).toMatchObject({ owner: "oppi", startedSession: false });
      expect(result.session).toMatchObject({ status: "ready" });
    });

    it("persists and reports required-model failure when starting a promptless session", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "ready",
        model: "openai-codex/gpt-5.6-sol",
        launch: {
          model: "openai-codex/gpt-5.6-sol",
          modelPolicy: "required",
          status: "accepted",
          requestedAt: 1,
          promptDispatch: "not_sent",
        },
      });
      const modelError = new Error(
        'Required model "openai-codex/gpt-5.6-sol" is not available; refusing model fallback',
      );
      const { service, saveSession, startSession } = makeService({
        startSessionError: modelError,
      });

      await expect(
        service.resumeWorkspaceSession({ session, workspace: makeWorkspace() }),
      ).rejects.toMatchObject({
        name: "SessionLifecycleError",
        statusCode: 409,
        message: modelError.message,
      } satisfies Partial<SessionLifecycleError>);
      expect(startSession).toHaveBeenCalledOnce();
      expect(saveSession).toHaveBeenCalledWith(
        expect.objectContaining({
          status: "error",
          launch: expect.objectContaining({
            status: "accepted",
            modelPolicy: "required",
            promptDispatch: "not_sent",
          }),
        }),
      );
      expect(session.launch?.promptError).toBeUndefined();

      startSession.mockResolvedValueOnce(makeSession({ ...session, status: "ready" }));
      await expect(
        service.resumeWorkspaceSession({ session, workspace: makeWorkspace() }),
      ).resolves.toMatchObject({ startedSession: true, session: { status: "ready" } });
      expect(startSession).toHaveBeenCalledTimes(2);
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

    it("opens a failed required-model session when the model becomes available", async () => {
      const session = makeSession({
        runtime: "oppi",
        status: "error",
        launch: {
          modelPolicy: "required",
          status: "failed",
          requestedAt: 1,
          promptDispatch: "not_sent",
          promptError: 'Required model "ds4/deepseek-v4-flash" is not available',
        },
      });
      const started = makeSession({ ...session, status: "ready" });
      const { service, startSession } = makeService({ started });

      const result = await service.openFocusedSession({
        session,
        workspace: makeWorkspace(),
      });

      expect(startSession).toHaveBeenCalledOnce();
      expect(result).toMatchObject({ startedSession: true, session: { status: "ready" } });
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
          model: "openai-codex/gpt-5.6-sol",
        });

        expect(createSession).toHaveBeenCalledWith("Imported Name", "openai-codex/gpt-5.6-sol");
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
            launch: expect.objectContaining({
              source: "human",
              model: "openai-codex/gpt-5.6-sol",
              modelPolicy: "required",
              status: "accepted",
              promptDispatch: "not_sent",
              target: { workspaceId: "ws-1", runtime: "host" },
            }),
          }),
        );
        expect(result.created).toBe(true);
        expect(result.session).toMatchObject({ id: "imported-1", contextWindow: 200_000 });
      } finally {
        rmSync(piSessionDir, { recursive: true, force: true });
        rmSync(workspaceDir, { recursive: true, force: true });
      }
    });

    it("rejects legacy control-session Pi JSONLs", async () => {
      const piSessionsRoot = getPiSessionsRoot();
      mkdirSync(piSessionsRoot, { recursive: true });
      const piSessionDir = mkdtempSync(join(piSessionsRoot, "oppi-lifecycle-control-import-"));
      const workspaceDir = mkdtempSync(join(tmpdir(), "oppi-lifecycle-workspace-"));
      const controlCwd = join(workspaceDir, "server", "Oppi Control");
      const jsonlPath = join(piSessionDir, "session.jsonl");
      writeFileSync(
        jsonlPath,
        [
          JSON.stringify({
            type: "session",
            id: "pi-control-1",
            cwd: controlCwd,
            timestamp: "2026-05-03T00:00:00.000Z",
          }),
          "",
        ].join("\n"),
      );
      const { service, createSession } = makeService();

      try {
        await expect(
          service.importLocalSession({
            workspace: makeWorkspace({ name: "Project", hostMount: workspaceDir }),
            piSessionFile: jsonlPath,
          }),
        ).rejects.toMatchObject({
          message: expect.stringContaining("Control session transcripts cannot be imported"),
          statusCode: 400,
        });
        expect(createSession).not.toHaveBeenCalled();
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

    it("cleans up the created fork and its usage if the Pi fork command fails", async () => {
      const sourceSession = makeSession({ id: "source-1", piSessionFile: "/tmp/current.jsonl" });
      const deleteResourceUsageSession = vi.fn(async () => ({ status: "purged" }));
      const { service, deleteSession, stopSession } = makeService({
        runCommandError: new Error("fork command failed"),
        deleteResourceUsageSession,
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
      expect(deleteResourceUsageSession).toHaveBeenCalledWith("fork-1");
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

    it("keeps deletion available while durable usage purge retry is pending", async () => {
      const session = makeSession({ id: "delete-1", workspaceId: "ws-1" });
      const deleteResourceUsageSession = vi.fn(async () => ({ status: "pending" }));
      const { service, stopSessionIfActive, deleteSession, deleteSearchIndexSession } = makeService(
        { deleteResourceUsageSession },
      );

      const result = await service.deleteSession(session);

      expect(stopSessionIfActive).toHaveBeenCalledWith("delete-1");
      expect(deleteSession).toHaveBeenCalledWith("delete-1");
      expect(deleteSearchIndexSession).toHaveBeenCalledWith("delete-1");
      expect(deleteResourceUsageSession).toHaveBeenCalledWith("delete-1");
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
