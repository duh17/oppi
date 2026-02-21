import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

  it("stores sessions and workspaces in flat top-level directories", () => {
    const owner = {
      id: "owner-1",
      name: "Bob",
      token: "sk_existing_owner_token",
      createdAt: Date.now() - 10_000,
    };

    writeFileSync(join(dir, "users.json"), JSON.stringify(owner, null, 2));

    const storage = new Storage(dir);

    const session: Session = {
      id: "sess-1",
      userId: owner.id,
      status: "busy",
      createdAt: Date.now() - 5_000,
      lastActivity: Date.now() - 3_000,
      messageCount: 1,
      tokens: { input: 10, output: 20 },
      cost: 0,
      model: "anthropic/claude-sonnet-4-0",
      name: "Test Session",
    };

    const workspace: Workspace = {
      id: "ws-1",
      userId: owner.id,
      name: "Test Workspace",
      skills: ["fetch"],
      createdAt: Date.now() - 8_000,
      updatedAt: Date.now() - 8_000,
    };

    storage.saveSession(session);
    storage.saveWorkspace(workspace);

    expect(existsSync(join(dir, "sessions", `${session.id}.json`))).toBe(true);
    expect(existsSync(join(dir, "workspaces", `${workspace.id}.json`))).toBe(true);

    const loaded = storage.getSession(session.id);
    expect(loaded?.status).toBe("busy");

    const loadedWs = storage.getWorkspace(workspace.id);
    expect(loadedWs?.name).toBe("Test Workspace");
  });
});
