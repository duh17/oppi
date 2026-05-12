import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";

describe("storage flat layout", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-flat-layout-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("stores sessions in sqlite and workspaces in flat top-level directories", () => {
    const storage = new Storage(dir);

    const session: Session = {
      id: "sess-1",
      status: "busy",
      createdAt: Date.now() - 5_000,
      lastActivity: Date.now() - 3_000,
      messageCount: 1,
      tokens: { input: 10, output: 20, cacheRead: 0, cacheWrite: 0 },
      cost: 0,
      model: "anthropic/claude-sonnet-4-0",
      name: "Test Session",
    };

    const workspace: Workspace = {
      id: "ws-1",
      name: "Test Workspace",
      skills: ["fetch"],
      systemPromptMode: "append",
      createdAt: Date.now() - 8_000,
      updatedAt: Date.now() - 8_000,
    };

    storage.saveSession(session);
    storage.saveWorkspace(workspace);

    expect(existsSync(join(dir, "session-state.db"))).toBe(true);
    expect(existsSync(join(dir, "sessions", `${session.id}.json`))).toBe(false);
    expect(existsSync(join(dir, "workspaces", `${workspace.id}.json`))).toBe(true);

    const loaded = storage.getSession(session.id);
    expect(loaded?.status).toBe("busy");

    const loadedWs = storage.getWorkspace(workspace.id);
    expect(loadedWs?.name).toBe("Test Workspace");
  });
});
