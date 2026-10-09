import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { chmodSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

import { describe, expect, it, vi } from "vitest";
import { WebSocket } from "ws";

import { PiTuiMirrorRuntime } from "../src/pi-tui-mirror-runtime.js";
import { SessionRuntimes } from "../src/runtime-router.js";
import { createWorkspaceWorktree, listWorkspaceWorktrees } from "../src/worktrees.js";
import { BoundSessionStreamMux, type StreamContext } from "../src/stream.js";
import type { SessionManager } from "../src/sessions.js";
import type { Storage } from "../src/storage.js";
import type { ServerMessage, Session, Workspace } from "../src/types.js";

class FakeBridgeWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: Array<Record<string, unknown>> = [];
  closeCode?: number;
  closeReason?: string;
  private sendWaiters: Array<() => void> = [];

  send(data: string): void {
    this.sent.push(JSON.parse(data) as Record<string, unknown>);
    const waiters = this.sendWaiters.splice(0);
    for (const resolve of waiters) resolve();
  }

  waitForSend(timeoutMs = 1_000): Promise<void> {
    return new Promise((resolve, reject) => {
      const resolveAndCleanup = () => {
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        const index = this.sendWaiters.indexOf(resolveAndCleanup);
        if (index >= 0) this.sendWaiters.splice(index, 1);
        reject(new Error("Timed out waiting for bridge WebSocket send"));
      }, timeoutMs);
      this.sendWaiters.push(resolveAndCleanup);
    });
  }

  close(code?: number, reason?: string): void {
    this.readyState = WebSocket.CLOSED;
    this.closeCode = code;
    this.closeReason = reason;
  }

  receive(message: Record<string, unknown>): void {
    this.emit("message", Buffer.from(JSON.stringify(message)), false);
  }
}

class FakeSessionWebSocket extends EventEmitter {
  readyState = WebSocket.OPEN;
  sent: ServerMessage[] = [];
  closeCode?: number;

  send(data: string): void {
    this.sent.push(JSON.parse(data) as ServerMessage);
  }

  ping(): void {}

  terminate(): void {
    this.readyState = WebSocket.CLOSED;
  }

  close(code = 1000, reason = ""): void {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.closeCode = code;
    this.emit("close", code, Buffer.from(reason));
  }

  sentOfType(type: string, sessionId?: string): ServerMessage[] {
    return this.sent.filter(
      (message) =>
        message.type === type && (sessionId === undefined || message.sessionId === sessionId),
    );
  }
}

function makeSession(id: string, workspaceId = "w1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId,
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function makeHarness(root: string) {
  const workspaces = new Map<string, Workspace>([
    [
      "w1",
      {
        id: "w1",
        name: "Workspace",
        hostMount: root,
      },
    ],
  ]);
  const sessions = new Map<string, Session>();
  let nextSessionId = 1;

  const storage = {
    getOwnerName: () => "test-user",
    getWorkspace: (id: string) => workspaces.get(id) ?? null,
    listWorkspaces: () => Array.from(workspaces.values()),
    createWorkspace: (request: {
      name: string;
      description?: string;
      icon?: string;
      skills: string[];
      systemPrompt?: string;
      systemPromptMode?: "append";
      hostMount?: string;
      tools?: string[];
      extensions?: string[];
      gitStatusEnabled?: boolean;
      runtime?: "host" | "sandbox";
    }) => {
      const now = Date.now();
      const workspace: Workspace = {
        id: `w${workspaces.size + 1}`,
        name: request.name,
        description: request.description,
        icon: request.icon,
        skills: request.skills,
        systemPrompt: request.systemPrompt,
        systemPromptMode: request.systemPromptMode ?? "append",
        hostMount: request.hostMount,
        tools: request.tools,
        extensions: request.extensions,
        gitStatusEnabled: request.gitStatusEnabled,
        runtime: request.runtime,
        createdAt: now,
        updatedAt: now,
      };
      workspaces.set(workspace.id, workspace);
      return workspace;
    },
    listSessions: () => Array.from(sessions.values()),
    getSession: (id: string) => sessions.get(id) ?? null,
    createSession: (name?: string, model?: string, options?: { id?: string }) => {
      const session = makeSession(options?.id ?? `sess-${nextSessionId++}`);
      if (name) session.name = name;
      if (model) session.model = model;
      sessions.set(session.id, session);
      return session;
    },
    saveSession: (session: Session) => {
      sessions.set(session.id, structuredClone(session));
    },
    getConfig: () => ({ dataDir: join(root, ".oppi-test-data") }),
    getDataDir: () => join(root, ".oppi-test-data"),
  } as unknown as Storage;

  const mirror = new PiTuiMirrorRuntime(storage, { mobileRenderers: new MobileRendererRegistry() });
  const managed = {
    sendPrompt: vi.fn(async () => {}),
    sendSteer: vi.fn(async () => {}),
    sendFollowUp: vi.fn(async () => {}),
    getMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    removeQueuedMessage: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    takeMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
    sendAbort: vi.fn(async () => {}),
    stopSession: vi.fn(async () => {}),
    getActiveSession: vi.fn(() => undefined),
    respondToUIRequest: vi.fn(() => false),
    forwardClientCommand: vi.fn(async () => {}),
    getActiveSessionIds: vi.fn(() => new Set<string>()),
    getCurrentSeq: vi.fn(() => 0),
    getCatchUp: vi.fn(() => null),
    subscribe: vi.fn(() => () => {}),
    subscribeStartupUI: vi.fn(() => () => {}),
    getPendingUIRequestMessages: vi.fn(() => []),
    isActive: vi.fn(() => false),
    isSessionConnected: vi.fn(() => false),
    getToolFullOutputPath: vi.fn(() => null),
    getEventRing: vi.fn(() => null),
    startSession: vi.fn(
      async (sessionId: string) => sessions.get(sessionId) ?? makeSession(sessionId),
    ),
    refreshSessionState: vi.fn(async () => null),
  } as unknown as SessionManager & { startSession: ReturnType<typeof vi.fn> };
  const runtimes = new SessionRuntimes(storage, managed, mirror);
  const streamMux = new BoundSessionStreamMux({
    storage,
    sessions: managed,
    sessionRuntimes: runtimes,
    ensureSessionContextWindow: (session) => session,
    resolveWorkspaceForSession: () => undefined,
    handleClientMessage: vi.fn(async () => {}),
    trackConnection: vi.fn(),
    untrackConnection: vi.fn(),
  } as unknown as StreamContext);

  return { storage, sessions, mirror, managed, runtimes, streamMux };
}

async function connectBridge(
  runtime: PiTuiMirrorRuntime,
  options: {
    bridgeId: string;
    cwd: string;
    piSessionId: string;
    sessionFile: string;
    sessionName: string;
    workspaceId?: string | null;
  },
): Promise<{ ws: FakeBridgeWebSocket; sessionId: string }> {
  const ws = new FakeBridgeWebSocket();
  runtime.handleBridgeWebSocket(ws as unknown as WebSocket);
  ws.receive({
    type: "hello",
    protocolVersion: 2,
    bridgeId: options.bridgeId,
    ...(options.workspaceId === null ? {} : { workspaceId: options.workspaceId ?? "w1" }),
    cwd: options.cwd,
    capabilities: ["input_preflight:v1"],
    state: {
      piSessionId: options.piSessionId,
      sessionFile: options.sessionFile,
      sessionName: options.sessionName,
    },
  });

  await vi.waitFor(
    () => {
      expect(
        ws.sent.some((message) => message.type === "hello_ack" || message.type === "error"),
      ).toBe(true);
    },
    { timeout: 2_000 },
  );

  const ack = ws.sent.find((message) => message.type === "hello_ack");
  expect(ack).toBeTruthy();
  return { ws, sessionId: String(ack?.sessionId) };
}

function latestCommand(ws: FakeBridgeWebSocket): Record<string, unknown> {
  const command = ws.sent.findLast((message) => message.type === "command");
  expect(command).toBeTruthy();
  return command!;
}

async function waitForLatestCommand(ws: FakeBridgeWebSocket): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const command = ws.sent.findLast((message) => message.type === "command");
    if (command) return command;
    await ws.waitForSend();
  }
  return latestCommand(ws);
}

function commandMessage(command: Record<string, unknown>): string | undefined {
  const payload = command.command;
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return undefined;
  const message = (payload as { message?: unknown }).message;
  return typeof message === "string" ? message : undefined;
}

async function drain(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}

function installDelayedWorktreeLookup(bin: string, cwd: string, stateDir: string): void {
  const realGit = execFileSync("/bin/sh", ["-c", "command -v git"], { encoding: "utf8" }).trim();
  const state = JSON.stringify(stateDir);
  writeFileSync(
    join(bin, "git"),
    `#!/bin/sh
expected=${JSON.stringify(cwd)}
expected_p=$(cd "$expected" && pwd -P)
pwd_p=$(pwd -P)
if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ] && [ "$pwd_p" = "$expected_p" ]; then
  nfile=${state}/count
  n=$(cat "$nfile" 2>/dev/null || echo 0)
  n=$((n + 1))
  printf '%s\n' "$n" > "$nfile"
  touch ${state}/started-$n
  while [ ! -f ${state}/release-$n ]; do
    sleep 0.02
  done
fi
exec ${JSON.stringify(realGit)} "$@"
`,
  );
  chmodSync(join(bin, "git"), 0o755);
}

function sendOverlappingHello(
  mirror: PiTuiMirrorRuntime,
  bridgeId: string,
  cwd: string,
): FakeBridgeWebSocket {
  const ws = new FakeBridgeWebSocket();
  mirror.handleBridgeWebSocket(ws as unknown as WebSocket);
  ws.receive({
    type: "hello",
    protocolVersion: 2,
    bridgeId,
    workspaceId: "w1",
    cwd,
    capabilities: ["input_preflight:v1"],
    state: {
      piSessionId: "pi-overlap",
      sessionFile: join(cwd, "overlap.jsonl"),
      sessionName: "Overlap terminal session",
    },
  });
  return ws;
}

async function releaseLookup(stateDir: string, generation: number): Promise<void> {
  writeFileSync(join(stateDir, `release-${generation}`), "1");
}

function acked(ws: FakeBridgeWebSocket): boolean {
  return ws.sent.some((message) => message.type === "hello_ack");
}

function git(cwd: string, args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

async function createManagedWorktreeFixture(
  root: string,
): Promise<{ worktreeId: string; worktreePath: string }> {
  git(root, ["init", "--initial-branch=main"]);
  git(root, ["config", "user.email", "oppi-test@example.invalid"]);
  git(root, ["config", "user.name", "Oppi Test"]);
  writeFileSync(join(root, "README.md"), "main checkout\n");
  git(root, ["add", "README.md"]);
  git(root, ["commit", "-m", "initial"]);
  git(root, ["branch", "feature/mirror-worktree"]);

  const worktreePath = join(root, ".pi", "worktrees", "mirror-feature");
  mkdirSync(join(root, ".pi", "worktrees"), { recursive: true });
  git(root, ["worktree", "add", worktreePath, "feature/mirror-worktree"]);

  const workspace: Workspace = { id: "w1", name: "Workspace", hostMount: root };
  const worktree = (await listWorkspaceWorktrees(workspace)).find((candidate) => !candidate.isMain);
  if (!worktree) throw new Error("Expected managed worktree fixture");
  return { worktreeId: worktree.id, worktreePath };
}

describe("PiTuiMirrorRuntime resilience", () => {
  it("tags mirrored sessions with the workspace worktree inferred from terminal cwd", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-worktree-"));
    try {
      const fixture = await createManagedWorktreeFixture(root);
      const cwd = join(fixture.worktreePath, "nested");
      mkdirSync(cwd, { recursive: true });
      const { mirror, sessions } = makeHarness(root);

      const connected = await connectBridge(mirror, {
        bridgeId: "bridge-worktree",
        cwd,
        piSessionId: "pi-worktree",
        sessionFile: join(cwd, "session.jsonl"),
        sessionName: "Worktree terminal session",
      });

      expect(sessions.get(connected.sessionId)?.worktreeId).toBe(fixture.worktreeId);
      expect(mirror.getActiveSession(connected.sessionId)?.worktreeId).toBe(fixture.worktreeId);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("infers the workspace from data-dir worktree terminal cwd", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-infer-data-worktree-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);

      const dataDir = join(root, ".oppi-test-data");
      const workspace: Workspace = { id: "w1", name: "Workspace", hostMount: root };
      const worktree = await createWorkspaceWorktree(
        workspace,
        { branch: "feature/infer-data-worktree" },
        { dataDir },
      );
      const { mirror, sessions } = makeHarness(root);

      const connected = await connectBridge(mirror, {
        bridgeId: "bridge-infer-data-worktree",
        cwd: worktree.path,
        piSessionId: "pi-infer-data-worktree",
        sessionFile: join(worktree.path, "session.jsonl"),
        sessionName: "Inferred data worktree terminal session",
        workspaceId: null,
      });

      expect(sessions.get(connected.sessionId)).toMatchObject({
        workspaceId: "w1",
        worktreeId: worktree.id,
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("materializes mirrored workspace attachments relative to data-dir worktrees", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-data-worktree-"));
    try {
      git(root, ["init", "--initial-branch=main"]);
      git(root, ["config", "user.email", "oppi-test@example.invalid"]);
      git(root, ["config", "user.name", "Oppi Test"]);
      writeFileSync(join(root, "README.md"), "main checkout\n");
      git(root, ["add", "README.md"]);
      git(root, ["commit", "-m", "initial"]);

      const dataDir = join(root, ".oppi-test-data");
      const workspace: Workspace = { id: "w1", name: "Workspace", hostMount: root };
      const worktree = await createWorkspaceWorktree(
        workspace,
        { branch: "feature/mirror-attachment" },
        { dataDir },
      );
      writeFileSync(join(worktree.path, "only-in-worktree.txt"), "worktree attachment\n");
      const { mirror, runtimes, sessions } = makeHarness(root);

      const connected = await connectBridge(mirror, {
        bridgeId: "bridge-data-worktree",
        cwd: worktree.path,
        piSessionId: "pi-data-worktree",
        sessionFile: join(worktree.path, "session.jsonl"),
        sessionName: "Data worktree terminal session",
      });

      expect(sessions.get(connected.sessionId)?.worktreeId).toBe(worktree.id);
      const pendingPrompt = runtimes.sendPrompt(connected.sessionId, "review attachment", {
        clientTurnId: "turn-attachment",
        requestId: "req-attachment",
        timestamp: Date.now(),
        attachments: [
          {
            type: "attachment",
            id: "att-1",
            source: "workspace",
            name: "only-in-worktree.txt",
            mimeType: "text/plain",
            sizeBytes: 20,
            workspacePath: "only-in-worktree.txt",
          },
        ],
      });

      const command = await waitForLatestCommand(connected.ws);
      expect(commandMessage(command)).toContain("Attached files:");
      expect(commandMessage(command)).toContain(".pi/attachments");
      connected.ws.receive({
        type: "command_result",
        id: String(command.id),
        success: true,
        state: { isIdle: true },
      });
      await expect(pendingPrompt).resolves.toBeUndefined();
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("prevents SDK split-brain and command misrouting across stale attach and bridge reuse", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-resilience-"));
    try {
      const { mirror, managed, runtimes, streamMux, sessions } = makeHarness(root);
      const first = await connectBridge(mirror, {
        bridgeId: "bridge-reused",
        cwd: root,
        piSessionId: "pi-first",
        sessionFile: join(root, "first.jsonl"),
        sessionName: "First terminal session",
      });

      const pendingPrompt = runtimes.sendPrompt(first.sessionId, "queued before reload", {
        clientTurnId: "turn-before-reload",
        requestId: "req-before-reload",
        timestamp: Date.now(),
      });
      const delayedCommand = await waitForLatestCommand(first.ws);
      expect(commandMessage(delayedCommand)).toBe("queued before reload");

      first.ws.receive({
        type: "goodbye",
        reason: "reload",
        state: { isIdle: true },
      });
      await expect(pendingPrompt).rejects.toThrow("pi-tui disconnected");
      expect(mirror.isSessionConnected(first.sessionId)).toBe(false);
      expect(sessions.get(first.sessionId)?.runtime).toBe("pi-tui");
      expect(sessions.get(first.sessionId)?.mirror?.status).toBe("connected");

      const focusedStream = new FakeSessionWebSocket();
      await streamMux.handleWebSocket("w1", first.sessionId, focusedStream as unknown as WebSocket);
      await drain();

      expect(managed.startSession).not.toHaveBeenCalled();
      expect(focusedStream.sentOfType("connected", first.sessionId)[0]).toMatchObject({
        session: expect.objectContaining({ id: first.sessionId, runtime: "pi-tui" }),
      });
      focusedStream.close(1000);

      const second = await connectBridge(mirror, {
        bridgeId: "bridge-reused",
        cwd: root,
        piSessionId: "pi-second",
        sessionFile: join(root, "second.jsonl"),
        sessionName: "Second terminal session",
      });
      expect(second.sessionId).not.toBe(first.sessionId);
      expect(mirror.isSessionConnected(second.sessionId)).toBe(true);

      await expect(
        runtimes.sendPrompt(first.sessionId, "must not reach second terminal", {
          clientTurnId: "turn-stale",
          requestId: "req-stale",
          timestamp: Date.now(),
        }),
      ).rejects.toThrow("pi-tui is not connected");
      expect(
        second.ws.sent.some(
          (message) =>
            message.type === "command" &&
            commandMessage(message) === "must not reach second terminal",
        ),
      ).toBe(false);
      expect(managed.startSession).not.toHaveBeenCalled();

      const secondMessages: ServerMessage[] = [];
      mirror.subscribe(second.sessionId, (message) => secondMessages.push(message));
      second.ws.receive({
        type: "queue_state",
        queue: {
          version: 1,
          steering: [{ id: "s-second", message: "second queue item", createdAt: 1 }],
          followUp: [],
        },
      });

      first.ws.receive({
        type: "command_result",
        id: delayedCommand.id,
        success: true,
        data: {
          queue: {
            version: 99,
            steering: [{ id: "stale", message: "stale queue item", createdAt: 1 }],
            followUp: [],
          },
        },
        state: {
          sessionName: "Delayed result must not rename the second session",
        },
      });

      expect(secondMessages).toContainEqual({
        type: "queue_state",
        queue: {
          version: 1,
          steering: [{ id: "s-second", message: "second queue item", createdAt: 1 }],
          followUp: [],
        },
      });
      expect(
        secondMessages.some(
          (message) =>
            message.type === "queue_state" &&
            (message.queue as { version?: number }).version === 99,
        ),
      ).toBe(false);
      expect(mirror.getActiveSession(second.sessionId)?.name).toBe("Second terminal session");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps the same session active across bridge replace without stream subscribers", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-replace-"));
    try {
      const { mirror, sessions } = makeHarness(root);
      const first = await connectBridge(mirror, {
        bridgeId: "bridge-same-session",
        cwd: root,
        piSessionId: "pi-same",
        sessionFile: join(root, "same.jsonl"),
        sessionName: "Same terminal session",
      });

      const secondWs = new FakeBridgeWebSocket();
      mirror.handleBridgeWebSocket(secondWs as unknown as WebSocket);
      secondWs.receive({
        type: "hello",
        protocolVersion: 2,
        bridgeId: "bridge-same-session-2",
        workspaceId: "w1",
        cwd: root,
        capabilities: ["input_preflight:v1"],
        state: {
          piSessionId: "pi-same",
          sessionFile: join(root, "same.jsonl"),
          sessionName: "Same terminal session",
        },
      });

      await vi.waitFor(
        () => {
          expect(secondWs.sent.some((message) => message.type === "hello_ack")).toBe(true);
        },
        { timeout: 2_000 },
      );
      const ack = secondWs.sent.find((message) => message.type === "hello_ack");
      expect(ack?.sessionId).toBe(first.sessionId);
      expect(mirror.isSessionConnected(first.sessionId)).toBe(true);
      expect(mirror.getActiveSessionIds()).toEqual(new Set([first.sessionId]));
      expect(sessions.get(first.sessionId)?.mirror?.status).toBe("connected");

      const received: ServerMessage[] = [];
      mirror.subscribe(first.sessionId, (message) => received.push(message));
      secondWs.receive({
        type: "queue_state",
        queue: {
          version: 3,
          steering: [{ id: "s1", message: "after replace", createdAt: 1 }],
          followUp: [],
        },
      });
      expect(received).toContainEqual({
        type: "queue_state",
        queue: {
          version: 3,
          steering: [{ id: "s1", message: "after replace", createdAt: 1 }],
          followUp: [],
        },
      });
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("evicts hydrated mirror active state on terminal stop and idle unsubscribe", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-runtime-evict-"));
    try {
      const { mirror, sessions, runtimes } = makeHarness(root);
      const connected = await connectBridge(mirror, {
        bridgeId: "bridge-evict",
        cwd: root,
        piSessionId: "pi-evict",
        sessionFile: join(root, "evict.jsonl"),
        sessionName: "Evict terminal session",
      });

      expect(mirror.getActiveSessionIds()).toEqual(new Set([connected.sessionId]));
      expect(mirror.getEventRing(connected.sessionId)).toEqual({
        length: 0,
        capacity: 500,
      });

      // Keep one subscriber across terminal stop so catch-up/tool maps stay available.
      const heldMessages: ServerMessage[] = [];
      const unsubscribeHeld = mirror.subscribe(connected.sessionId, (message) => {
        heldMessages.push(message);
      });

      connected.ws.receive({
        type: "goodbye",
        reason: "stopped",
        state: { isIdle: true },
      });
      connected.ws.readyState = WebSocket.CLOSED;
      connected.ws.emit("close");

      expect(mirror.isSessionConnected(connected.sessionId)).toBe(false);
      expect(sessions.get(connected.sessionId)?.status).toBe("stopped");
      expect(mirror.getActiveSessionIds()).toEqual(new Set());
      expect(mirror.getEventRing(connected.sessionId)).toEqual({
        length: expect.any(Number),
        capacity: 500,
      });
      expect(heldMessages.some((message) => message.type === "state")).toBe(true);

      // Disconnected write paths must not re-pin after release.
      unsubscribeHeld();
      expect(mirror.getEventRing(connected.sessionId)).toBeNull();
      await expect(
        runtimes.sendPrompt(connected.sessionId, "should not pin", {
          timestamp: Date.now(),
          requestId: "req-no-pin",
        }),
      ).rejects.toThrow("pi-tui is not connected");
      expect(mirror.getEventRing(connected.sessionId)).toBeNull();
      expect(mirror.getToolFullOutputPath(connected.sessionId, "tool-1")).toBeNull();

      // Read-only lookups must not re-pin a stopped mirror session.
      expect(mirror.getPendingUIRequestMessages(connected.sessionId)).toEqual([]);
      expect(mirror.getActiveSessionIds()).toEqual(new Set());

      const unsubscribe = mirror.subscribe(connected.sessionId, () => {});
      expect(mirror.getEventRing(connected.sessionId)).toEqual({
        length: 0,
        capacity: 500,
      });
      unsubscribe();
      expect(mirror.getEventRing(connected.sessionId)).toBeNull();
      expect(mirror.getActiveSessionIds()).toEqual(new Set());
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps the newest mirror hello when an older worktree lookup finishes last", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-race-"));
    const stateDir = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-race-state-"));
    const bin = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-race-bin-"));
    const previousPath = process.env.PATH;
    try {
      installDelayedWorktreeLookup(bin, root, stateDir);
      process.env.PATH = `${bin}${delimiter}${previousPath ?? ""}`;
      const { mirror, runtimes } = makeHarness(root);
      const older = sendOverlappingHello(mirror, "bridge-older", root);
      await vi.waitFor(() => expect(existsSync(join(stateDir, "started-1"))).toBe(true));
      const newer = sendOverlappingHello(mirror, "bridge-newer", root);
      await vi.waitFor(() => expect(existsSync(join(stateDir, "started-2"))).toBe(true));

      await releaseLookup(stateDir, 2);
      await vi.waitFor(() => expect(acked(newer)).toBe(true));
      const sessionId = String(
        newer.sent.find((message) => message.type === "hello_ack")?.sessionId,
      );

      await releaseLookup(stateDir, 1);
      await vi.waitFor(() => expect(older.closeCode).toBe(4000));

      expect(older.closeReason).toBe(
        "Mirror bridge hello superseded by a newer terminal connection",
      );
      expect(acked(older)).toBe(false);
      expect(newer.closeCode).toBeUndefined();
      expect(mirror.isSessionConnected(sessionId)).toBe(true);

      const pending = runtimes.sendPrompt(sessionId, "who is the bridge", {
        timestamp: Date.now(),
        requestId: "req-newest-hello",
      });
      const command = await waitForLatestCommand(newer);
      expect(commandMessage(command)).toBe("who is the bridge");
      expect(older.sent.some((message) => message.type === "command")).toBe(false);
      newer.receive({
        type: "command_result",
        id: String(command.id),
        success: true,
        state: { isIdle: true },
      });
      await pending;
    } finally {
      process.env.PATH = previousPath;
      await rm(root, { recursive: true, force: true });
      await rm(stateDir, { recursive: true, force: true });
      await rm(bin, { recursive: true, force: true });
    }
  });

  it("closes an older mirror hello that finishes before the newer bridge exists", async () => {
    const root = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-empty-"));
    const stateDir = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-empty-state-"));
    const bin = await mkdtemp(join(tmpdir(), "oppi-mirror-hello-empty-bin-"));
    const previousPath = process.env.PATH;
    try {
      installDelayedWorktreeLookup(bin, root, stateDir);
      process.env.PATH = `${bin}${delimiter}${previousPath ?? ""}`;
      const { mirror, runtimes } = makeHarness(root);
      const older = sendOverlappingHello(mirror, "bridge-older-empty", root);
      await vi.waitFor(() => expect(existsSync(join(stateDir, "started-1"))).toBe(true));
      const newer = sendOverlappingHello(mirror, "bridge-newer-empty", root);
      await vi.waitFor(() => expect(existsSync(join(stateDir, "started-2"))).toBe(true));

      await releaseLookup(stateDir, 1);
      await vi.waitFor(() => expect(older.closeCode).toBe(4000));
      expect(acked(older)).toBe(false);
      expect(newer.closeCode).toBeUndefined();
      expect(acked(newer)).toBe(false);
      expect(mirror.getActiveSessionIds()).toEqual(new Set());

      await releaseLookup(stateDir, 2);
      await vi.waitFor(() => expect(acked(newer)).toBe(true));
      const sessionId = String(
        newer.sent.find((message) => message.type === "hello_ack")?.sessionId,
      );
      expect(older.closeReason).toBe(
        "Mirror bridge hello superseded by a newer terminal connection",
      );
      expect(newer.closeCode).toBeUndefined();
      expect(mirror.isSessionConnected(sessionId)).toBe(true);

      const pending = runtimes.sendPrompt(sessionId, "newer still owns the bridge", {
        timestamp: Date.now(),
        requestId: "req-empty-bridge",
      });
      const command = await waitForLatestCommand(newer);
      expect(commandMessage(command)).toBe("newer still owns the bridge");
      expect(older.sent.some((message) => message.type === "command")).toBe(false);
      newer.receive({
        type: "command_result",
        id: String(command.id),
        success: true,
        state: { isIdle: true },
      });
      await pending;
    } finally {
      process.env.PATH = previousPath;
      await rm(root, { recursive: true, force: true });
      await rm(stateDir, { recursive: true, force: true });
      await rm(bin, { recursive: true, force: true });
    }
  });
});
