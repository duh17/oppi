import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { NotifyInput } from "../extensions/durable/notify/contract.js";
import { SdkBackend } from "../src/sdk-backend.js";
import type { SessionNotifyPort } from "../src/session-push-notifier.js";
import type { Session, Workspace } from "../src/types.js";

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
});

/** A classic session in an empty agent dir, so no user extension or tool joins in. */
async function classicSession(notify: SessionNotifyPort): Promise<SdkBackend> {
  const cwd = mkdtempSync(join(tmpdir(), "oppi-notify-cwd-"));
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-notify-agent-"));
  mkdirSync(join(agentDir, "extensions"), { recursive: true });
  writeFileSync(join(agentDir, "auth.json"), "{}");
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  cleanups.push(() => {
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
  });
  const now = Date.now();
  const session: Session = {
    id: "classic-1",
    workspaceId: "w1",
    status: "starting",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
  const backend = await SdkBackend.create({
    session,
    workspace: { id: "w1", name: "Notify", runtime: "host", hostMount: cwd } as Workspace,
    onEvent: vi.fn(),
    onEnd: vi.fn(),
    notify,
  });
  cleanups.push(() => void backend.dispose());
  return backend;
}

function activeTools(backend: SdkBackend): string[] {
  return backend.session.agent.state.tools.map((tool) => tool.name);
}

describe("classic notify tool", () => {
  it("is offered while the server offers it, and a reload follows push turning off", async () => {
    let offered = true;
    const sent: Array<[string, NotifyInput]> = [];
    const backend = await classicSession({
      offersNotify: () => offered,
      notify: async (sessionId, input) => {
        sent.push([sessionId, input]);
        return { status: "sent", devices: 2 };
      },
    });

    expect(activeTools(backend)).toContain("notify");
    const tool = backend.session.agent.state.tools.find((entry) => entry.name === "notify");
    const result = await tool!.execute("call-1", { title: "Report ready", body: "Read it." });
    expect(result.content).toEqual([{ type: "text", text: "Notification sent to 2 devices." }]);
    expect(sent).toEqual([["classic-1", { title: "Report ready", body: "Read it." }]]);

    offered = false;
    await backend.reloadResources();
    expect(activeTools(backend)).not.toContain("notify");
  });
});
