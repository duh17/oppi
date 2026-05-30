import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { openDatabase } from "../src/sqlite-compat.js";
import { Storage } from "../src/storage.js";

describe("storage session metadata format", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-session-metadata-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("writes runtime session metadata to sqlite only", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("metadata", "anthropic/claude-sonnet-4-0");

    const sessionPath = join(dir, "sessions", `${session.id}.json`);

    expect(existsSync(join(dir, "session-state.db"))).toBe(true);
    expect(existsSync(sessionPath)).toBe(false);
    expect(new Storage(dir).getSession(session.id)?.status).toBe("ready");
  });

  it("persists pi-tui runtime metadata", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("terminal live", "openai/gpt-5");
    session.runtime = "pi-tui";
    session.mirror = {
      status: "connected",
      capabilities: ["prompt", "abort"],
      protocolVersion: 1,
      terminal: {
        bridgeId: "bridge-1",
        hostname: "mac-studio",
        pid: 123,
        cwd: "/tmp/project",
        connectedAt: 1234,
        lastSeenAt: 5678,
      },
    };
    storage.saveSession(session);

    const loaded = new Storage(dir).getSession(session.id);
    expect(loaded?.runtime).toBe("pi-tui");
    expect(loaded?.mirror?.status).toBe("connected");
    expect(loaded?.mirror?.terminal?.cwd).toBe("/tmp/project");
  });

  it("normalizes legacy runtime values when loading stored sessions", () => {
    const storage = new Storage(dir);
    const mirrorSession = storage.createSession("terminal live", "openai/gpt-5");
    mirrorSession.runtime = "pi-tui";
    storage.saveSession(mirrorSession);

    const oppiSession = storage.createSession("oppi live", "openai/gpt-5");
    oppiSession.runtime = "oppi";
    storage.saveSession(oppiSession);

    const db = openDatabase(join(dir, "session-state.db"));
    db.prepare("UPDATE session_state_sessions SET runtime = ?, session_json = ? WHERE id = ?").run(
      "pi-tui-mirror",
      JSON.stringify({ ...mirrorSession, runtime: "pi-tui-mirror" }),
      mirrorSession.id,
    );
    db.prepare("UPDATE session_state_sessions SET runtime = ?, session_json = ? WHERE id = ?").run(
      "managed",
      JSON.stringify({ ...oppiSession, runtime: "managed" }),
      oppiSession.id,
    );
    db.close();

    const reloaded = new Storage(dir);
    expect(reloaded.getSession(mirrorSession.id)?.runtime).toBe("pi-tui");
    expect(reloaded.getSession(oppiSession.id)?.runtime).toBe("oppi");
  });

  it("imports legacy session metadata from disk", () => {
    const now = Date.now();

    const sessionRecord = {
      id: "s1",
      status: "ready",
      createdAt: now,
      lastActivity: now,
      model: "openai/gpt-test",
      messageCount: 1,
      tokens: { input: 1, output: 2 },
      cost: 0,
    };

    mkdirSync(join(dir, "sessions"), { recursive: true });
    const sessionPath = join(dir, "sessions", "s1.json");
    writeFileSync(sessionPath, JSON.stringify({ session: sessionRecord }, null, 2));

    const loaded = new Storage(dir).getSession("s1");
    expect(loaded?.id).toBe("s1");
    expect(loaded?.tokens.cacheRead).toBe(0);
  });
});
