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

describe("SessionMessageQueueCoordinator with a real Pi session", () => {
  it("commits a steering-to-follow-up move without reporting a version mismatch", async () => {
    const { backend, broadcast, coordinator } = await makeRealPiHarness();

    // Seed the busy queue the way the sessions layer does: Pi queues first,
    // then Oppi records the same item in its authoritative queue.
    await backend.session.steer("seed steer");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "seed steer", undefined, "item-a");
    const seeded = coordinator.getQueue("queue-real-pi");
    expect(seeded.steering.map((item) => item.id)).toEqual(["item-a"]);
    const item = seeded.steering[0];
    if (!item) throw new Error("expected seeded item");

    const moved = await coordinator.setQueue("queue-real-pi", {
      baseVersion: seeded.version,
      steering: [],
      followUp: [{ id: item.id, message: item.message, createdAt: item.createdAt }],
    });

    expect(moved.version).toBe(seeded.version + 1);
    expect(moved.steering).toEqual([]);
    expect(moved.followUp.map((entry) => entry.id)).toEqual(["item-a"]);
    expect(backend.session.getSteeringMessages()).toEqual([]);
    expect(backend.session.getFollowUpMessages()).toEqual(["seed steer"]);
    expect(coordinator.getQueue("queue-real-pi")).toEqual(moved);
    const states = broadcast.mock.calls
      .map(([, message]) => message)
      .filter((message) => message.type === "queue_state");
    expect(states.at(-1)).toMatchObject({ queue: { version: moved.version } });
  });

  it("still rejects and reconciles when Pi starts a queued message during the replacement", async () => {
    const { backend, coordinator } = await makeRealPiHarness();
    const piSession = backend.session;
    await piSession.steer("A");
    await piSession.steer("B");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "A", undefined, "item-a");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "B", undefined, "item-b");
    const seeded = coordinator.getQueue("queue-real-pi");

    // Pi starts "A" as soon as the replacement has replayed both messages.
    let started = false;
    const unsubscribe = piSession.subscribe((event) => {
      if (event.type !== "queue_update" || event.steering.length !== 2 || started) return;
      started = true;
      void (
        piSession as unknown as {
          _handleAgentEvent: (event: unknown) => Promise<void>;
        }
      )._handleAgentEvent({
        type: "message_start",
        message: { role: "user", content: "A", timestamp: 1 },
      });
    });
    cleanups.push(unsubscribe);

    await expect(
      coordinator.setQueue("queue-real-pi", {
        baseVersion: seeded.version,
        steering: [
          { id: "item-b", message: "B" },
          { id: "item-a", message: "A" },
        ],
        followUp: [],
      }),
    ).rejects.toThrow(
      `Queue version mismatch: expected ${seeded.version + 1}, got ${seeded.version}`,
    );

    expect(piSession.getSteeringMessages()).toEqual(["B"]);
    expect(coordinator.getQueue("queue-real-pi")).toMatchObject({
      version: seeded.version + 1,
      steering: [{ id: "item-b", message: "B" }],
      followUp: [],
    });
  });

  it("reconciles instead of rolling back when a replay is refused after Pi started a sibling", async () => {
    const { backend, coordinator } = await makeRealPiHarness();
    const piSession = backend.session;
    await piSession.steer("A");
    coordinator.enqueueQueuedMessage("queue-real-pi", "steer", "A", undefined, "item-a");
    const seeded = coordinator.getQueue("queue-real-pi");

    // The replacement queues "/boom" in steering (Pi refuses it) and "A" in
    // follow-up. Pi starts "A" the moment it lands, before the batch settles.
    let started = false;
    const unsubscribe = piSession.subscribe((event) => {
      if (event.type !== "queue_update" || event.followUp.length !== 1 || started) return;
      started = true;
      void (
        piSession as unknown as {
          _handleAgentEvent: (event: unknown) => Promise<void>;
        }
      )._handleAgentEvent({
        type: "message_start",
        message: { role: "user", content: "A", timestamp: 1 },
      });
    });
    cleanups.push(unsubscribe);

    const error = await coordinator
      .setQueue("queue-real-pi", {
        baseVersion: seeded.version,
        steering: [{ id: "item-boom", message: "/boom" }],
        followUp: [{ id: "item-a", message: "A" }],
      })
      .catch((caught: unknown) => caught);

    expect(started).toBe(true);
    // Rollback would have put the consumed "A" back and sent it twice.
    expect(piSession.getSteeringMessages()).toEqual([]);
    expect(piSession.getFollowUpMessages()).toEqual([]);
    expect(String(error)).toMatch(/Queue version mismatch/);
    expect(coordinator.getQueue("queue-real-pi").version).toBeGreaterThan(seeded.version);
    expect(coordinator.getQueue("queue-real-pi").steering.map((item) => item.message)).not.toEqual([
      "A",
    ]);
  });
});
