import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";
import type { Session, Workspace } from "../src/types.js";

describe("storage owner-layout migration", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "pi-remote-owner-layout-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("migrates legacy owner-scoped records to flat layout without re-pairing", () => {
    const owner = {
      id: "owner-1",
      name: "Chen",
      token: "sk_existing_owner_token",
      createdAt: Date.now() - 10_000,
    };

    const legacySessionsDir = join(dir, "sessions", owner.id);
    const legacyWorkspacesDir = join(dir, "workspaces", owner.id);
    mkdirSync(legacySessionsDir, { recursive: true });
    mkdirSync(legacyWorkspacesDir, { recursive: true });

    writeFileSync(join(dir, "users.json"), JSON.stringify([owner], null, 2));

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
      JSON.stringify(
        {
          session,
          messages: [
            {
              id: "m1",
              sessionId: session.id,
              role: "user",
              content: "hello",
              timestamp: Date.now() - 4_000,
            },
          ],
        },
        null,
        2,
      ),
    );

    const workspace: Workspace = {
      id: "ws-1",
      userId: owner.id,
      name: "Legacy Workspace",
      runtime: "container",
      skills: ["fetch"],
      policyPreset: "container",
      createdAt: Date.now() - 8_000,
      updatedAt: Date.now() - 8_000,
    };

    writeFileSync(
      join(legacyWorkspacesDir, `${workspace.id}.json`),
      JSON.stringify(workspace, null, 2),
    );

    const storage = new Storage(dir);

    // Existing pairing token stays stable (no re-pair required).
    const loadedOwner = storage.getOwnerUser();
    expect(loadedOwner?.token).toBe(owner.token);

    // Legacy records were migrated and remain readable.
    const loadedSession = storage.getSession(owner.id, session.id);
    expect(loadedSession?.id).toBe(session.id);
    expect(storage.getSessionMessages(owner.id, session.id)).toHaveLength(1);

    const loadedWorkspace = storage.getWorkspace(owner.id, workspace.id);
    expect(loadedWorkspace?.id).toBe(workspace.id);

    // New writes go to flat owner layout.
    storage.saveSession({ ...loadedSession!, status: "busy" });
    storage.saveWorkspace({ ...loadedWorkspace!, name: "Upgraded Workspace" });

    expect(existsSync(join(dir, "sessions", `${session.id}.json`))).toBe(true);
    expect(existsSync(join(dir, "workspaces", `${workspace.id}.json`))).toBe(true);

    // Legacy files are removed after migration.
    expect(existsSync(join(legacySessionsDir, `${session.id}.json`))).toBe(false);
    expect(existsSync(join(legacyWorkspacesDir, `${workspace.id}.json`))).toBe(false);
  });
});
