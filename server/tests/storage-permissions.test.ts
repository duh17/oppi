import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Storage } from "../src/storage.js";

describe("storage file permissions", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-storage-perms-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("writes config file as owner-only", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();

    const configMode = statSync(join(dir, "config.json")).mode & 0o777;
    expect(configMode).toBe(0o600);
  });

  it("writes session and workspace records as owner-only", () => {
    const storage = new Storage(dir);
    storage.ensurePaired();

    const session = storage.createSession("security-check", "anthropic/claude-sonnet-4-0");
    const sessionPath = join(dir, "sessions", `${session.id}.json`);

    const workspace = storage.createWorkspace({ name: "default", skills: [] });
    const workspacePath = join(dir, "workspaces", `${workspace.id}.json`);

    expect(statSync(join(dir, "sessions")).mode & 0o777).toBe(0o700);
    expect(statSync(join(dir, "workspaces")).mode & 0o777).toBe(0o700);
    expect(statSync(sessionPath).mode & 0o777).toBe(0o600);
    expect(statSync(workspacePath).mode & 0o777).toBe(0o600);
  });
});
