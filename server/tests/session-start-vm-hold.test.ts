import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { DurableBackend } from "../src/durable-backend.js";
import { SdkBackend } from "../src/sdk-backend.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";

/**
 * A sandbox workspace's VM stays up while any session holds it (`noteWorkspaceBusy`) and idles
 * once the last hold is released (`noteWorkspaceIdle`). A start that fails must hand its hold back
 * on every path, or the VM never idles.
 */
const dirs: string[] = [];
const managers: SessionManager[] = [];
const agentDirBefore = process.env.PI_CODING_AGENT_DIR;
afterEach(async () => {
  vi.restoreAllMocks();
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  if (agentDirBefore === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = agentDirBefore;
});

function makeFixture(options: { durable: boolean }) {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-vm-hold-"));
  dirs.push(dataDir);
  // Durable sessions read Skills and AGENTS files under the agent dir: never the developer's.
  process.env.PI_CODING_AGENT_DIR = join(dataDir, "agent");
  const storage = new Storage(dataDir);
  if (options.durable) storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
  const workspace = storage.createWorkspace({
    name: "box",
    hostMount: dataDir,
    runtime: "sandbox",
  });
  const session = storage.createSession("vm-hold", "anthropic/claude-sonnet-4-0");
  session.workspaceId = workspace.id;
  if (options.durable) session.serverDurable = { storeId: session.id };
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);

  // One ordered log of VM calls, so "the last call" is the VM's final state for the pair.
  const calls: string[] = [];
  vi.spyOn(SdkBackend, "noteWorkspaceBusy").mockImplementation((workspaceId, sessionId) => {
    calls.push(`busy ${workspaceId} ${sessionId}`);
  });
  vi.spyOn(SdkBackend, "noteWorkspaceIdle").mockImplementation((workspaceId, sessionId) => {
    calls.push(`idle ${workspaceId} ${sessionId}`);
  });
  return { storage, workspace, session, manager, calls };
}

describe("a failed start releases the sandbox VM hold", () => {
  it("when the SDK backend cannot be created", async () => {
    const { workspace, session, manager, calls } = makeFixture({ durable: false });
    vi.spyOn(SdkBackend, "create").mockRejectedValue(new Error("create failed"));

    await expect(manager.startSession(session.id, workspace)).rejects.toThrow("create failed");

    const pair = `${workspace.id} ${session.id}`;
    expect(calls[0]).toBe(`busy ${pair}`);
    expect(calls.at(-1)).toBe(`idle ${pair}`);
  });

  it("when a registered durable backend fails to start its events", async () => {
    const { workspace, session, manager, calls } = makeFixture({ durable: true });
    const fake = Object.assign(Object.create(DurableBackend.prototype) as DurableBackend, {
      startEvents: vi.fn().mockRejectedValue(new Error("startEvents failed")),
      dispose: vi.fn(async () => {}),
      cacheMissSeed: vi.fn(async () => []),
      nativeMessageQueue: true,
    });
    vi.spyOn(DurableBackend, "create").mockResolvedValue(fake);

    await expect(manager.startSession(session.id, workspace)).rejects.toThrow("startEvents failed");

    expect(fake.startEvents).toHaveBeenCalledOnce();
    const pair = `${workspace.id} ${session.id}`;
    expect(calls).toContain(`busy ${pair}`);
    expect(calls.at(-1)).toBe(`idle ${pair}`);
    expect(manager.isActive(session.id)).toBe(false);
  });
});
