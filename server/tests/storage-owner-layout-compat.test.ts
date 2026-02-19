import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";

describe("storage strict owner layout", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-owner-layout-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("uses flat owner layout and ignores nested legacy records", () => {
    const owner = {
      id: "owner-1",
      name: "Bob",
      token: "sk_existing_owner_token",
      createdAt: Date.now() - 10_000,
    };

    writeFileSync(join(dir, "users.json"), JSON.stringify(owner, null, 2));

    const legacySessionsDir = join(dir, "sessions", owner.id);
    const legacyWorkspacesDir = join(dir, "workspaces", owner.id);
    mkdirSync(legacySessionsDir, { recursive: true });
    mkdirSync(legacyWorkspacesDir, { recursive: true });

    const session: Session = {
      id: "sess-1",
      userId: owner.id,
      status: "ready",
      createdAt: Date.now() - 5_000,
      lastActivity: Date.now() - 3_000,
      messageCount: 1,
      tokens: { input: 10, output: 20 },
      cost: 0,
      model: "anthropic/claude-sonnet-4-0",
      name: "Legacy Session",
    };

    writeFileSync(
      join(legacySessionsDir, `${session.id}.json`),
      JSON.stringify({ session, messages: [] }, null, 2),
    );

    const workspace: Workspace = {
      id: "ws-1",
      userId: owner.id,
      name: "Legacy Workspace",
      runtime: "container",
      skills: ["fetch"],
      createdAt: Date.now() - 8_000,
      updatedAt: Date.now() - 8_000,
    };

    writeFileSync(
      join(legacyWorkspacesDir, `${workspace.id}.json`),
      JSON.stringify(workspace, null, 2),
    );

    const storage = new Storage(dir);

    // Legacy nested records are not read.
    expect(storage.getSession(owner.id, session.id)).toBeUndefined();
    expect(storage.getWorkspace(owner.id, workspace.id)).toBeUndefined();

    // New writes go to flat owner layout.
    storage.saveSession({ ...session, userId: owner.id, status: "busy" });
    storage.saveWorkspace({ ...workspace, userId: owner.id, name: "Flat Workspace" });

    expect(existsSync(join(dir, "sessions", `${session.id}.json`))).toBe(true);
    expect(existsSync(join(dir, "workspaces", `${workspace.id}.json`))).toBe(true);
  });
});
