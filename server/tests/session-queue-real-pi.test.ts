import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SdkBackend } from "../src/sdk-backend.js";
import {
  SessionMessageQueueCoordinator,
  type SessionMessageQueueState,
} from "../src/session-queue.js";
import type { Session, Workspace } from "../src/types.js";

// These tests run the coordinator against a real Pi AgentSession. Pi's
// steer()/followUp() await input handlers before they queue and emit
// queue_update, so a replacement replay finishes on later microtasks. A fake
// that mutates synchronously cannot show how Oppi tracks replay authority.

const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  while (cleanups.length > 0) await cleanups.pop()?.();
});

async function makeRealPiHarness(): Promise<{
  active: SessionMessageQueueState;
  backend: SdkBackend;
  broadcast: ReturnType<typeof vi.fn>;
  coordinator: SessionMessageQueueCoordinator;
}> {
  const cwd = mkdtempSync(join(tmpdir(), "oppi-queue-real-pi-cwd-"));
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-queue-real-pi-agent-"));
  mkdirSync(join(agentDir, "extensions"), { recursive: true });
  writeFileSync(join(agentDir, "auth.json"), "{}", "utf-8");
  writeFileSync(
    join(agentDir, "extensions", "queue-provider.ts"),
    `
export default function (pi) {
  pi.registerProvider("testprov", {
    name: "Test Provider",
    api: "openai-completions",
    baseUrl: "https://api.test.local/v1",
    apiKey: "test-key",
    models: [
      {
        id: "queue-model",
        name: "Queue Model",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 100000,
        maxTokens: 8000,
      },
    ],
  });
  // Pi refuses to queue an extension command while the agent is busy, which
  // gives a replay that deterministically rejects.
  pi.registerCommand("boom", { description: "Test command", handler: async () => {} });
}
`,
    "utf-8",
  );
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;

  const session: Session = {
    id: "queue-real-pi",
    workspaceId: "w1",
    status: "starting",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    ephemeral: true,
    model: "testprov/queue-model",
  };
  const backend = await SdkBackend.create({
    session,
    workspace: {
      id: "w1",
      name: "Queue real Pi",
      runtime: "host",
      hostMount: cwd,
    } as Workspace,
    onEvent: vi.fn(),
    onEnd: vi.fn(),
  });
  cleanups.push(async () => {
    await backend.dispose();
    rmSync(cwd, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  // Pi only accepts a busy turn through a live model call. Mark the run active
  // directly so the queue path under test still uses Pi's real queue methods.
  (backend.session as unknown as { _isAgentRunActive: boolean })._isAgentRunActive = true;

  const active: SessionMessageQueueState = {
    session,
    sdkBackend: backend,
    messageQueue: { version: 0, steering: [], followUp: [] },
  };
  const broadcast = vi.fn();
  const coordinator = new SessionMessageQueueCoordinator({
    getActiveSession: () => active,
    broadcast,
  });
  return { active, backend, broadcast, coordinator };
}

describe("native queue withdrawal with a real Pi session", () => {
  it("removes one item by id and preserves both remaining queues", async () => {
    const { backend, coordinator } = await makeRealPiHarness();
    await backend.session.steer("duplicate");
    await backend.session.steer("duplicate");
    await backend.session.followUp("follow");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "duplicate", undefined, "a");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "duplicate", undefined, "b");
    coordinator.enqueueQueuedMessage("queue-real-pi", "follow_up", "follow", undefined, "c");
    const queue = await coordinator.removeQueuedMessage("queue-real-pi", "a");
    expect(queue.steering.map((item) => item.id)).toEqual(["b"]);
    expect(queue.followUp.map((item) => item.id)).toEqual(["c"]);
    expect(backend.session.getSteeringMessages()).toEqual(["duplicate"]);
    expect(backend.session.getFollowUpMessages()).toEqual(["follow"]);
    expect(await coordinator.removeQueuedMessage("queue-real-pi", "already-delivered")).toEqual(
      queue,
    );
  });

  it("takes all queued items with attachments and clears native Pi", async () => {
    const { backend, coordinator } = await makeRealPiHarness();
    const attachment = {
      type: "attachment" as const,
      id: "file",
      source: "workspace" as const,
      name: "notes.txt",
      mimeType: "text/plain",
      sizeBytes: 4,
      workspacePath: "notes.txt",
    };
    await backend.session.steer("steer");
    await backend.session.followUp("follow");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "steer", [attachment], "a");
    coordinator.enqueueQueuedMessage("queue-real-pi", "follow_up", "follow", undefined, "b");
    const withdrawn = await coordinator.takeQueue("queue-real-pi");
    expect(withdrawn.steering).toMatchObject([{ id: "a", attachments: [attachment] }]);
    expect(withdrawn.followUp.map((item) => item.id)).toEqual(["b"]);
    expect(backend.session.getSteeringMessages()).toEqual([]);
    expect(backend.session.getFollowUpMessages()).toEqual([]);
    expect(coordinator.getQueue("queue-real-pi")).toMatchObject({ steering: [], followUp: [] });
    expect(await coordinator.takeQueue("queue-real-pi")).toMatchObject({
      steering: [],
      followUp: [],
    });
  });

  it("does not resurrect a remainder consumed by Pi during remove replay", async () => {
    const { backend, coordinator } = await makeRealPiHarness();
    await backend.session.steer("remove");
    await backend.session.followUp("delivered during replay");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "remove", undefined, "a");
    coordinator.enqueueQueuedMessage(
      "queue-real-pi",
      "follow_up",
      "delivered during replay",
      undefined,
      "b",
    );
    const original = backend.session.followUp.bind(backend.session);
    vi.spyOn(backend.session, "followUp").mockImplementation(async (...args) => {
      await original(...args);
      backend.session.clearQueue();
    });
    expect(await coordinator.removeQueuedMessage("queue-real-pi", "a")).toMatchObject({
      steering: [],
      followUp: [],
    });
  });
});
