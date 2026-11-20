import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { SdkBackend } from "../src/sdk-backend.js";
import type { Workspace } from "../src/types.js";

const cleanups: Array<() => void> = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
});

/** A classic session whose Pi agent dir holds `settings` as the owner's global Pi settings. */
async function classicSession(settings: Record<string, unknown>): Promise<SdkBackend> {
  const cwd = mkdtempSync(join(tmpdir(), "oppi-pi-defaults-cwd-"));
  const agentDir = mkdtempSync(join(tmpdir(), "oppi-pi-defaults-agent-"));
  mkdirSync(join(agentDir, "extensions"), { recursive: true });
  writeFileSync(join(agentDir, "auth.json"), "{}");
  writeFileSync(join(agentDir, "settings.json"), JSON.stringify(settings));
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDir;
  cleanups.push(() => {
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
    rmSync(cwd, { recursive: true, force: true });
    rmSync(agentDir, { recursive: true, force: true });
  });
  const now = Date.now();
  const backend = await SdkBackend.create({
    session: {
      id: "pi-defaults-1",
      workspaceId: "w1",
      status: "starting",
      createdAt: now,
      lastActivity: now,
      messageCount: 0,
      tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
    },
    workspace: { id: "w1", name: "Defaults", runtime: "host", hostMount: cwd } as Workspace,
    onEvent: vi.fn(),
    onEnd: vi.fn(),
  });
  cleanups.push(() => void backend.dispose());
  return backend;
}

describe("Pi defaults an update must not change", () => {
  it("warms a classic session's cache only while it runs unless the owner chose a mode", async () => {
    const backend = await classicSession({});
    expect(backend.session.settingsManager.getCacheWarmingMode()).toBe("streaming");
  });

  it("keeps the cache-warming mode the owner set in Pi's settings", async () => {
    const backend = await classicSession({ cacheWarming: "idle" });
    expect(backend.session.settingsManager.getCacheWarmingMode()).toBe("idle");
  });
});
