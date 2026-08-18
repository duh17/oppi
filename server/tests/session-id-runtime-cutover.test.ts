import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { openDatabase } from "../src/sqlite-compat.js";

import * as PiSdk from "@earendil-works/pi-coding-agent";
import type { AgentSession } from "@earendil-works/pi-coding-agent";
import { afterEach, describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { forkPiSessionFrom, SdkBackend } from "../src/sdk-backend.js";
import { SessionCommandCoordinator } from "../src/session-commands.js";
import {
  SessionLifecycleService,
  type SessionLifecycleServiceDeps,
} from "../src/session-lifecycle-service.js";
import { getPiSessionsRoot } from "../src/local-sessions.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";
import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import type { Session, Workspace } from "../src/types.js";
import type { Storage } from "../src/storage.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
  }

  close(): void {
    this.readyState = WebSocket.CLOSED;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

function makeSession(overrides: Partial<Session> = {}): Session {
  const now = Date.now();
  return {
    id: "sess-1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

function makeWorkspace(overrides: Partial<Workspace> = {}): Workspace {
  return {
    id: "ws-1",
    name: "Workspace",
    ...overrides,
  } as Workspace;
}

function callCreatePiSessionManager(session: Session, cwd: string): PiSdk.SessionManager {
  return (
    SdkBackend as unknown as {
      createPiSessionManager: (session: Session, cwd: string) => PiSdk.SessionManager;
    }
  ).createPiSessionManager(session, cwd);
}

describe("Pi-native session identity cutover", () => {
  describe("UUID minted before SessionManager", () => {
    const dirs: string[] = [];

    afterEach(() => {
      for (const dir of dirs.splice(0)) {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    it("persists a UUID as Session.id on the first createSession write", () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-session-id-cutover-"));
      dirs.push(dir);
      const store = new SessionSqliteStore(dir);

      const session = store.createSession("New session", "openai/gpt-5.4");

      expect(session.id).toMatch(UUID_RE);
      expect(session.id).not.toHaveLength(8);
      expect(session).not.toHaveProperty("piSessionId");
      expect(store.getSession(session.id)?.id).toBe(session.id);
      expect(store.getSession(session.id)).not.toHaveProperty("piSessionId");
      store.close();

      const db = openDatabase(join(dir, "session-state.db"));
      try {
        const columns = (
          db.prepare("PRAGMA table_info(session_state_sessions)").all() as Array<{ name: string }>
        ).map((row) => row.name);
        expect(columns).not.toContain("pi_session_id");
        const row = db
          .prepare("SELECT session_json FROM session_state_sessions WHERE id = ?")
          .get(session.id) as { session_json: string };
        expect(JSON.parse(row.session_json)).not.toHaveProperty("piSessionId");
      } finally {
        db.close();
      }
    });

    it("passes the persisted Session.id into SessionManager.create", () => {
      const session = makeSession({
        id: "019e1aaa-0000-7000-8000-000000000001",
      });
      const created = {
        kind: "created",
        getSessionId: () => session.id,
        getSessionFile: () => undefined,
        getHeader: () => ({ id: session.id }),
      } as unknown as PiSdk.SessionManager;
      const createSpy = vi.spyOn(PiSdk.SessionManager, "create").mockReturnValue(created);
      const openSpy = vi.spyOn(PiSdk.SessionManager, "open");
      const inMemorySpy = vi.spyOn(PiSdk.SessionManager, "inMemory");

      try {
        const manager = callCreatePiSessionManager(session, "/tmp/workspace");
        expect(manager).toBe(created);
        expect(createSpy).toHaveBeenCalledWith("/tmp/workspace", undefined, { id: session.id });
        expect(openSpy).not.toHaveBeenCalled();
        expect(inMemorySpy).not.toHaveBeenCalled();
      } finally {
        createSpy.mockRestore();
        openSpy.mockRestore();
        inMemorySpy.mockRestore();
      }
    });

    it("passes the persisted Session.id into SessionManager.inMemory for incognito sessions", () => {
      const session = makeSession({
        id: "019e1aaa-0000-7000-8000-000000000002",
        ephemeral: true,
      });
      const inMemory = { kind: "in-memory" } as unknown as PiSdk.SessionManager;
      const inMemorySpy = vi.spyOn(PiSdk.SessionManager, "inMemory").mockReturnValue(inMemory);
      const createSpy = vi.spyOn(PiSdk.SessionManager, "create");

      try {
        expect(callCreatePiSessionManager(session, "/tmp/workspace")).toBe(inMemory);
        expect(inMemorySpy).toHaveBeenCalledWith("/tmp/workspace", { id: session.id });
        expect(createSpy).not.toHaveBeenCalled();
      } finally {
        inMemorySpy.mockRestore();
        createSpy.mockRestore();
      }
    });
  });

  describe("import and mirror use the Pi ID as Session.id", () => {
    it("imports a JSONL so Session.id equals the header id", async () => {
      const piSessionsRoot = getPiSessionsRoot();
      mkdirSync(piSessionsRoot, { recursive: true });
      const piSessionDir = mkdtempSync(join(piSessionsRoot, "oppi-import-id-"));
      const workspaceDir = mkdtempSync(join(tmpdir(), "oppi-import-id-ws-"));
      const jsonlPath = join(piSessionDir, "session.jsonl");
      const headerId = "019e1bbb-1111-7111-8111-111111111111";
      writeFileSync(
        jsonlPath,
        `${JSON.stringify({
          type: "session",
          version: 3,
          id: headerId,
          timestamp: "2026-08-17T00:00:00.000Z",
          cwd: workspaceDir,
        })}\n`,
      );

      const persisted = new Map<string, Session>();
      const createSession = vi.fn((name?: string, model?: string, options?: { id?: string }) => {
        const session = makeSession({
          id: options?.id ?? "should-not-mint",
          name,
          model,
        });
        persisted.set(session.id, session);
        return session;
      });
      const saveSession = vi.fn((session: Session) => {
        persisted.set(session.id, structuredClone(session));
      });
      const service = new SessionLifecycleService({
        storage: {
          createSession,
          saveSession,
          getDataDir: () => workspaceDir,
          getSession: (id: string) => persisted.get(id),
          listSessions: () => [...persisted.values()],
          getWorkspace: () => undefined,
          deleteSession: () => true,
          getAgentDefinitionStore: () => ({ getAgent: () => undefined }),
          findSessionByLaunchIdempotencyKey: () => undefined,
          claimSessionLaunchRecovery: () => undefined,
        },
        sessions: {
          startSession: vi.fn(),
          sendPrompt: vi.fn(),
          runCommand: vi.fn(),
          stopSession: vi.fn(),
        },
        sessionRuntimes: {
          isSessionConnected: () => false,
          getSessionSnapshot: () => undefined,
          getActiveSession: () => undefined,
          refreshSessionState: vi.fn(),
          stopSession: vi.fn(),
          stopSessionIfActive: vi.fn(),
        },
        ensureSessionContextWindow: (session) => session,
      } as unknown as SessionLifecycleServiceDeps);

      try {
        const result = await service.importLocalSession({
          workspace: makeWorkspace({ hostMount: workspaceDir }),
          piSessionFile: jsonlPath,
        });

        expect(result.created).toBe(true);
        expect(result.session.id).toBe(headerId);
        expect(result.session).not.toHaveProperty("piSessionId");
        expect(result.session.piSessionFile).toBe(jsonlPath);
        expect(createSession).toHaveBeenCalledWith(undefined, undefined, { id: headerId });
      } finally {
        rmSync(piSessionDir, { recursive: true, force: true });
        rmSync(workspaceDir, { recursive: true, force: true });
      }
    });

    it("mirrors a bridge so Session.id equals the catalog Pi ID", () => {
      const sessions = new Map<string, Session>();
      let mintedFallback = 0;
      const workspace = makeWorkspace({ id: "w1", hostMount: "/tmp/mirror-host" });
      const storage = {
        listSessions: () => [...sessions.values()],
        getSession: (id: string) => sessions.get(id),
        listWorkspaces: () => [workspace],
        getWorkspace: (id: string) => (id === "w1" ? workspace : undefined),
        createSession: (name?: string, model?: string, options?: { id?: string }) => {
          const session = makeSession({
            id: options?.id ?? `fallback-${++mintedFallback}`,
            name,
            model,
          });
          sessions.set(session.id, session);
          return session;
        },
        saveSession: (session: Session) => {
          sessions.set(session.id, session);
        },
        getDataDir: () => "/tmp/mirror-data",
        getConfig: () => ({ dataDir: "/tmp/mirror-data" }),
      } as unknown as Storage;

      const runtime = new PiTuiMirrorRuntime(storage);
      const ws = new FakeBridgeWebSocket();
      runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
      ws.receive({
        type: "hello",
        protocolVersion: 2,
        bridgeId: "bridge-cutover",
        workspaceId: "w1",
        cwd: "/tmp/mirror-host",
        capabilities: ["input_preflight:v1"],
        state: {
          piSessionId: "019e1ccc-2222-7222-8222-222222222222",
          sessionFile: "/tmp/mirror-host/session.jsonl",
          sessionName: "Terminal session",
        },
      });

      const ack = ws.sent.find((message) => message.type === "hello_ack");
      const created = [...sessions.values()][0];
      expect(ack?.sessionId).toBe("019e1ccc-2222-7222-8222-222222222222");
      expect(created?.id).toBe("019e1ccc-2222-7222-8222-222222222222");
      expect(created).not.toHaveProperty("piSessionId");
      expect(created?.piSessionFile).toBe("/tmp/mirror-host/session.jsonl");
      expect(mintedFallback).toBe(0);
    });
  });

  describe("in-wrapper identity replacement", () => {
    function makeCoordinator() {
      const navigateTree = vi.fn(async () => ({ cancelled: false }));
      const newSession = vi.fn(async () => ({ cancelled: false }));
      const fork = vi.fn(async () => ({ cancelled: false }));
      const coordinator = new SessionCommandCoordinator({
        getActiveSession: () =>
          ({
            session: makeSession({ status: "ready" }),
            sdkBackend: {
              session: { navigateTree } as unknown as AgentSession,
              newSession,
              fork,
              isStreaming: false,
              isCompacting: false,
            } as unknown as SdkBackend,
          }) as never,
        persistSessionNow: vi.fn(),
        broadcast: vi.fn(),
        applyPiStateSnapshot: vi.fn(() => false),
        getContextWindowResolver: vi.fn(() => null),
      });
      return { coordinator, navigateTree, newSession, fork };
    }

    it.each(["new_session", "switch_session", "fork", "clone"] as const)(
      "rejects %s inside an Oppi-focused session",
      async (type) => {
        const { coordinator, newSession, fork } = makeCoordinator();

        expect(coordinator.isAllowedCommand(type)).toBe(false);
        await expect(
          coordinator.sendCommandAsync("sess-1", {
            type,
            ...(type === "fork" ? { entryId: "entry-1" } : {}),
          }),
        ).rejects.toThrow(/Oppi lifecycle|not allowed|distinct canonical/i);
        expect(newSession).not.toHaveBeenCalled();
        expect(fork).not.toHaveBeenCalled();
      },
    );

    it("still runs navigate_tree in the same focused session", async () => {
      const { coordinator, navigateTree } = makeCoordinator();

      expect(coordinator.isAllowedCommand("navigate_tree")).toBe(true);
      await coordinator.sendCommandAsync("sess-1", {
        type: "navigate_tree",
        targetId: "entry-1",
      });
      expect(navigateTree).toHaveBeenCalledWith("entry-1", expect.any(Object));
    });

    it("rejects SdkBackend.newSession and fork before they replace the live runtime", async () => {
      const runtimeNewSession = vi.fn();
      const runtimeFork = vi.fn();
      const backend = Object.create(SdkBackend.prototype) as SdkBackend;
      Object.assign(backend as unknown as Record<string, unknown>, {
        runtime: {
          newSession: runtimeNewSession,
          fork: runtimeFork,
        },
      });

      await expect(backend.newSession()).rejects.toThrow(
        /Oppi lifecycle|not allowed|distinct canonical/i,
      );
      await expect(backend.fork("entry-1")).rejects.toThrow(
        /Oppi lifecycle|not allowed|distinct canonical/i,
      );
      expect(runtimeNewSession).not.toHaveBeenCalled();
      expect(runtimeFork).not.toHaveBeenCalled();
    });
  });

  describe("product fork writes the minted Session.id", () => {
    const dirs: string[] = [];

    afterEach(() => {
      for (const dir of dirs.splice(0)) {
        rmSync(dir, { recursive: true, force: true });
      }
    });

    it("makes forkFrom header.id equal the minted Session.id", () => {
      const sourceCwd = mkdtempSync(join(tmpdir(), "oppi-fork-source-"));
      const targetCwd = mkdtempSync(join(tmpdir(), "oppi-fork-target-"));
      dirs.push(sourceCwd, targetCwd);
      const sourceFile = join(sourceCwd, "session.jsonl");
      writeFileSync(
        sourceFile,
        `${JSON.stringify({
          type: "session",
          version: 3,
          id: "019e1eee-4444-7444-8444-444444444444",
          timestamp: "2026-08-17T00:00:00.000Z",
          cwd: sourceCwd,
        })}\n`,
      );
      const mintedId = "019e1ddd-3333-7333-8333-333333333333";

      const forked = forkPiSessionFrom(sourceFile, targetCwd, mintedId);
      if (forked.sessionFile) dirs.push(dirname(forked.sessionFile));
      expect(forked.sessionId).toBe(mintedId);
      expect(forked.sessionFile).toBeDefined();

      const opened = PiSdk.SessionManager.open(forked.sessionFile!);
      expect(opened.getSessionId()).toBe(mintedId);
      expect(opened.getHeader()?.id).toBe(mintedId);
    });
  });
});
