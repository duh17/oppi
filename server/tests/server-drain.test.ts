import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import { ServerDrain, type DrainSession } from "../src/server-drain.js";
import { deliverHeldInputs } from "../src/session-restart-resume.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";
import { makeSdkBackendStub } from "./sdk-backend.helpers.js";

const dirs: string[] = [];
const managers: SessionManager[] = [];
afterEach(async () => {
  vi.useRealTimers();
  vi.restoreAllMocks();
  for (const manager of managers.splice(0)) await manager.stopAll().catch(() => {});
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function makeStorage(): { storage: Storage; workspace: Workspace } {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-server-drain-"));
  dirs.push(dataDir);
  const storage = new Storage(dataDir);
  const workspace = storage.createWorkspace({ name: "project", hostMount: dataDir });
  return { storage, workspace };
}

function saveSession(storage: Storage, id: string, fields: Partial<Session> = {}): Session {
  const session: Session = {
    id,
    status: "stopped",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ...fields,
  };
  storage.saveSession(session);
  return session;
}

/** A SessionManager whose sessions run on stub backends; `prompts` records what reached one. */
function makeManager(storage: Storage) {
  const prompts: Array<{ sessionId: string; text: string; streamingBehavior?: string }> = [];
  vi.spyOn(SdkBackend, "create").mockImplementation((async (opts: { session: Session }) => {
    const { sdkBackend, prompt } = makeSdkBackendStub();
    prompt.mockImplementation(async (text: string, options?: Record<string, unknown>) => {
      prompts.push({
        sessionId: opts.session.id,
        text,
        ...(typeof options?.streamingBehavior === "string"
          ? { streamingBehavior: options.streamingBehavior }
          : {}),
      });
      (options?.onPreflightAccepted as (() => void) | undefined)?.();
    });
    return sdkBackend;
  }) as never);
  const manager = new SessionManager(storage);
  managers.push(manager);
  const drain = { isDraining: false };
  manager.restartHold.drain = drain;
  return { manager, prompts, drain };
}

function setBusy(manager: SessionManager, sessionId: string, busy: boolean): void {
  const live = manager.getActiveSession(sessionId);
  if (!live) throw new Error(`not live: ${sessionId}`);
  live.status = busy ? "busy" : "ready";
}

describe("server drain admission", () => {
  it("holds a prompt and a follow-up while draining and delivers them in order afterwards", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "idle", { workspaceId: workspace.id });
    saveSession(storage, "busy", { workspaceId: workspace.id });
    const { manager, prompts, drain } = makeManager(storage);
    await manager.startSession("idle", workspace);
    await manager.startSession("busy", workspace);
    setBusy(manager, "busy", true);
    drain.isDraining = true;

    expect(await manager.sendPrompt("idle", "first", { clientTurnId: "t1" })).toEqual({
      held: "server_restart",
    });
    // A resend of the same turn (a lost ack) is held once.
    expect(await manager.sendPrompt("idle", "first", { clientTurnId: "t1" })).toEqual({
      held: "server_restart",
    });
    expect(await manager.sendPrompt("idle", "second")).toEqual({ held: "server_restart" });
    expect(await manager.sendFollowUp("busy", "after the turn")).toEqual({
      held: "server_restart",
    });
    expect(prompts).toEqual([]);
    expect(storage.listHeldInputs().map((input) => [input.sessionId, input.message])).toEqual([
      ["idle", "first"],
      ["idle", "second"],
      ["busy", "after the turn"],
    ]);

    // Nothing goes out while the drain is still pending.
    expect(await manager.restartHold.deliver("idle")).toBe(0);

    drain.isDraining = false;
    expect(await manager.restartHold.deliver("idle")).toBe(2);
    expect(await manager.restartHold.deliver("busy")).toBe(1);
    expect(prompts.map((prompt) => [prompt.sessionId, prompt.text])).toEqual([
      ["idle", "first"],
      ["idle", "second"],
      ["busy", "after the turn"],
    ]);
    expect(storage.listHeldInputs()).toEqual([]);
  });

  it("lets input that belongs to a running turn through", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "parent", { workspaceId: workspace.id });
    saveSession(storage, "child", {
      workspaceId: workspace.id,
      launch: { parentSessionId: "parent" } as Session["launch"],
    });
    saveSession(storage, "peer", { workspaceId: workspace.id });
    const { manager, prompts, drain } = makeManager(storage);
    for (const id of ["parent", "child", "peer"]) await manager.startSession(id, workspace);
    setBusy(manager, "parent", true);
    drain.isDraining = true;

    // A steer into the running turn.
    expect(
      await manager.sendPrompt("parent", "use the other file", { streamingBehavior: "steer" }),
    ).toBeUndefined();
    // The running parent's message to its child.
    expect(await manager.sendPrompt("child", "check the tests")).toBeUndefined();
    // A message the running session sends to another session (`oppi session send`).
    expect(
      await manager.sendPrompt("peer", "This is a message from session parent: rebuild"),
    ).toBeUndefined();
    expect(prompts.map((prompt) => prompt.sessionId)).toEqual(["parent", "child", "peer"]);

    // Once the parent's turn is over, its child's input waits like anyone's.
    setBusy(manager, "parent", false);
    setBusy(manager, "child", false);
    expect(await manager.sendPrompt("child", "one more thing")).toEqual({
      held: "server_restart",
    });
    // A steer into an idle session would start a turn: it is held too.
    expect(await manager.sendPrompt("peer", "go", { streamingBehavior: "steer" })).toEqual({
      held: "server_restart",
    });
  });

  it("refuses input to an incognito session, which does not come back after the restart", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "incognito", { workspaceId: workspace.id, ephemeral: true });
    const { manager, prompts, drain } = makeManager(storage);
    await manager.startSession("incognito", workspace);
    drain.isDraining = true;

    await expect(manager.sendPrompt("incognito", "hello")).rejects.toThrow(/server is restarting/i);
    expect(prompts).toEqual([]);
    expect(storage.listHeldInputs()).toEqual([]);
  });

  it("starts a stopped session to deliver what was held for it, and drops it for a deleted one", async () => {
    const { storage, workspace } = makeStorage();
    saveSession(storage, "stopped", { workspaceId: workspace.id });
    saveSession(storage, "gone", { workspaceId: workspace.id });
    storage.holdInput({ sessionId: "stopped", message: "held before", heldAt: 1 });
    storage.holdInput({ sessionId: "gone", message: "lost", heldAt: 2 });
    storage.deleteSession("gone");
    storage.holdInput({ sessionId: "gone", message: "orphan", heldAt: 3 });
    const { manager, prompts } = makeManager(storage);

    await deliverHeldInputs({
      storage,
      lifecycle: {
        resumeWorkspaceSession: async ({ session }) =>
          ({ session: await manager.startSession(session.id, workspace) }) as never,
        resumeControlSession: async () => {
          throw new Error("not a control session");
        },
        resumeControlConversation: async () => {
          throw new Error("not a control conversation");
        },
      },
      isActive: (sessionId) => manager.isActive(sessionId),
      deliver: (sessionId) => manager.restartHold.deliver(sessionId),
    });

    expect(manager.isActive("stopped")).toBe(true);
    expect(prompts.map((prompt) => [prompt.sessionId, prompt.text])).toEqual([
      ["stopped", "held before"],
    ]);
    expect(storage.listHeldInputs()).toEqual([]);
  });
});

describe("server drain", () => {
  function makeDrain(busy: () => DrainSession[]) {
    const restart = vi.fn();
    const onCancelled = vi.fn();
    const announced: Array<string | undefined> = [];
    const drain = new ServerDrain({
      busySessions: busy,
      heldInputCount: () => 0,
      announce: (text) => announced.push(text),
      restart,
      restartMode: () => "reexec",
      onCancelled,
      pollMs: 1_000,
    });
    return { drain, restart, onCancelled, announced };
  }

  it("restarts the way the process can, and refuses when it cannot restart itself", () => {
    const restart = vi.fn();
    const deps = { busySessions: () => [], heldInputCount: () => 0, announce: () => {} };
    const manual = new ServerDrain({
      ...deps,
      restart,
      restartMode: () => "manual",
      onCancelled() {},
    });
    expect(manual.unavailableReason()).toMatch(/cannot restart itself/);
    const noRestarter = new ServerDrain({ ...deps, restartMode: () => "reexec", onCancelled() {} });
    expect(noRestarter.unavailableReason()).toMatch(/cannot restart itself/);

    vi.useFakeTimers();
    const launchd = new ServerDrain({
      ...deps,
      restart,
      restartMode: () => "launchd",
      onCancelled() {},
    });
    expect(launchd.unavailableReason()).toBeUndefined();
    launchd.request({ source: "test" });
    vi.advanceTimersByTime(1_000);
    expect(restart).toHaveBeenCalledWith("launchd");
  });

  it("restarts once the busy turn ends, not before", async () => {
    vi.useFakeTimers();
    const { storage, workspace } = makeStorage();
    saveSession(storage, "worker", { workspaceId: workspace.id });
    const { manager } = makeManager(storage);
    await manager.startSession("worker", workspace);
    setBusy(manager, "worker", true);
    const { drain, restart, announced } = makeDrain(() => manager.restartHold.drainSessions());

    expect(drain.request({ source: "test" })).toMatchObject({
      state: "draining",
      busy: [{ sessionId: "worker", engine: "classic", waitingOnUser: false }],
    });
    vi.advanceTimersByTime(60_000);
    expect(restart).not.toHaveBeenCalled();
    expect(announced.at(-1)).toMatch(/restart pending/i);

    setBusy(manager, "worker", false);
    vi.advanceTimersByTime(2_000);
    expect(restart).toHaveBeenCalledTimes(1);
    expect(drain.status().state).toBe("restarting");
    // The status line is cleared before the process goes.
    expect(announced.at(-1)).toBeUndefined();
    vi.advanceTimersByTime(60 * 60_000);
    expect(restart).toHaveBeenCalledTimes(1);
  });

  it("does not wait for a session that waits on the user", () => {
    vi.useFakeTimers();
    const { drain, restart } = makeDrain(() => [
      { sessionId: "asking", engine: "durable", waitingOnUser: true },
    ]);
    expect(drain.request({ source: "test" }).waitingOnUser).toEqual([
      { sessionId: "asking", engine: "durable", waitingOnUser: true },
    ]);
    vi.advanceTimersByTime(1_000);
    expect(restart).toHaveBeenCalledTimes(1);
  });

  it("restarts at the deadline while a turn is still running", () => {
    vi.useFakeTimers();
    const { drain, restart } = makeDrain(() => [
      { sessionId: "endless", engine: "classic", waitingOnUser: false },
    ]);
    drain.request({ maxWaitMs: 30_000, source: "test" });
    vi.advanceTimersByTime(29_999);
    expect(restart).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1);
    expect(restart).toHaveBeenCalledTimes(1);
  });

  it("cancels: no restart, the status line is cleared, and held input is released", () => {
    vi.useFakeTimers();
    const { drain, restart, onCancelled, announced } = makeDrain(() => [
      { sessionId: "worker", engine: "classic", waitingOnUser: false },
    ]);
    drain.request({ maxWaitMs: 30_000, source: "test" });
    expect(drain.isDraining).toBe(true);

    expect(drain.cancel("test")?.state).toBe("idle");
    expect(drain.isDraining).toBe(false);
    expect(onCancelled).toHaveBeenCalledTimes(1);
    expect(announced.at(-1)).toBeUndefined();
    vi.advanceTimersByTime(60_000);
    expect(restart).not.toHaveBeenCalled();
    // Nothing left to cancel.
    expect(drain.cancel("test")).toBeUndefined();
  });

  it("keeps the first request's deadline when asked again", () => {
    vi.useFakeTimers();
    const { drain } = makeDrain(() => [
      { sessionId: "worker", engine: "classic", waitingOnUser: false },
    ]);
    const first = drain.request({ maxWaitMs: 30_000, source: "test" });
    vi.advanceTimersByTime(5_000);
    expect(drain.request({ maxWaitMs: 600_000, source: "test" }).deadlineAt).toBe(first.deadlineAt);
  });
});
