import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { openDatabase } from "../src/sqlite-compat.js";
import { Storage } from "../src/storage.js";
import { SessionSqliteStore } from "../src/storage/session-sqlite-store.js";

describe("storage session metadata format", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-server-session-metadata-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("cleans up server-owned review comment state on startup", () => {
    const db = openDatabase(join(dir, "session-state.db"));
    db.exec(`
      CREATE TABLE review_comments (id TEXT PRIMARY KEY, comment_json TEXT NOT NULL);
      CREATE TABLE review_comments_next (id TEXT PRIMARY KEY, comment_json TEXT NOT NULL);
      CREATE INDEX review_comments_workspace_created_idx ON review_comments (id);
    `);
    db.close();
    mkdirSync(join(dir, "review-comments"), { recursive: true });
    writeFileSync(
      join(dir, "review-comments", "workspace-1.json"),
      JSON.stringify({ comments: [] }),
    );

    new Storage(dir);

    const reloadedDb = openDatabase(join(dir, "session-state.db"));
    try {
      const rows = reloadedDb
        .prepare("SELECT name FROM sqlite_master WHERE name IN (?, ?)")
        .all("review_comments", "review_comments_next");
      expect(rows).toEqual([]);
    } finally {
      reloadedDb.close();
    }
    expect(existsSync(join(dir, "review-comments"))).toBe(false);
  });

  it("writes runtime session metadata to sqlite only", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("metadata", "anthropic/claude-sonnet-4-0");

    const sessionPath = join(dir, "sessions", `${session.id}.json`);

    expect(existsSync(join(dir, "session-state.db"))).toBe(true);
    expect(existsSync(sessionPath)).toBe(false);
    expect(new Storage(dir).getSession(session.id)?.status).toBe("ready");
  });

  it("preserves declared control metadata in cache and across SQLite reopen", () => {
    const writer = new SessionSqliteStore(dir);
    const control = {
      domain: "agents" as const,
      intent: "revise" as const,
      targetId: "agent-1",
      targetName: "Reviewer",
    };

    try {
      const session = writer.createSession("Revise Reviewer", "openai/gpt-5");
      session.control = control;
      writer.saveSession(session);

      control.targetName = "mutated after save";
      expect(writer.getSession(session.id)?.control).toEqual({
        domain: "agents",
        intent: "revise",
        targetId: "agent-1",
        targetName: "Reviewer",
      });
    } finally {
      writer.close();
    }

    const reader = new SessionSqliteStore(dir);
    try {
      expect(reader.listSessions()).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            control: {
              domain: "agents",
              intent: "revise",
              targetId: "agent-1",
              targetName: "Reviewer",
            },
          }),
        ]),
      );
      expect(reader.listSessions()[0]?.workspaceId).toBeUndefined();
    } finally {
      reader.close();
    }
  });

  it("persists delegation lineage across SQLite close and reopen", () => {
    const writer = new SessionSqliteStore(dir);
    try {
      const session = writer.createSession("delegated", "openai/gpt-5");
      session.launch = {
        source: "cli",
        parentSessionId: "parent-1",
        allowsNestedDelegation: true,
        status: "accepted",
        requestedAt: 1,
      };
      writer.saveSession(session);
    } finally {
      writer.close();
    }

    const reader = new SessionSqliteStore(dir);
    try {
      expect(reader.listSessions()).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            launch: expect.objectContaining({
              parentSessionId: "parent-1",
              allowsNestedDelegation: true,
            }),
          }),
        ]),
      );
    } finally {
      reader.close();
    }
  });

  it("persists pi-tui runtime metadata", () => {
    const storage = new Storage(dir);
    const session = storage.createSession("terminal live", "openai/gpt-5");
    session.runtime = "pi-tui";
    session.mirror = {
      status: "connected",
      capabilities: ["prompt", "abort", "input_preflight:v1"],
      protocolVersion: 2,
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

  it("ignores session JSON metadata outside SQLite", () => {
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
    expect(loaded).toBeUndefined();
  });
});
