import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { AuditLog, type AuditEntry } from "../src/audit.js";
import { mkdirSync, rmSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

describe("AuditLog", () => {
  let dir: string;
  let logPath: string;

  beforeEach(() => {
    dir = join(tmpdir(), `audit-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    mkdirSync(dir, { recursive: true });
    logPath = join(dir, "audit.jsonl");
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function makeEntry(overrides: Partial<Omit<AuditEntry, "id" | "timestamp">> = {}) {
    return {
      sessionId: "s1",
      workspaceId: "w1",
      tool: "bash",
      displaySummary: "ls -la",
      decision: "allow" as const,
      resolvedBy: "policy" as const,
      layer: "preset",
      ...overrides,
    };
  }

  // ─── record ───

  it("writes entries as JSONL", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry());
    log.record(makeEntry({ tool: "edit" }));

    const lines = readFileSync(logPath, "utf-8").trim().split("\n");
    expect(lines).toHaveLength(2);

    const first = JSON.parse(lines[0]);
    expect(first.tool).toBe("bash");
    expect(first.id).toBeDefined();
    expect(first.timestamp).toBeTypeOf("number");

    const second = JSON.parse(lines[1]);
    expect(second.tool).toBe("edit");
  });

  it("assigns unique IDs to each entry", () => {
    const log = new AuditLog(logPath);
    const a = log.record(makeEntry());
    const b = log.record(makeEntry());
    expect(a.id).not.toBe(b.id);
  });

  it("creates directory if missing", () => {
    const nested = join(dir, "deep", "nested", "audit.jsonl");
    const log = new AuditLog(nested);
    log.record(makeEntry());
    expect(existsSync(nested)).toBe(true);
  });

  // ─── query ───

  it("returns entries in reverse chronological order", () => {
    const log = new AuditLog(logPath);
    // Write entries with ascending timestamps
    log.record(makeEntry({ tool: "first" }));
    log.record(makeEntry({ tool: "second" }));
    log.record(makeEntry({ tool: "third" }));

    const results = log.query();
    expect(results).toHaveLength(3);
    expect(results[0].tool).toBe("third");
    expect(results[2].tool).toBe("first");
  });

  it("filters by sessionId", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry({ sessionId: "s1" }));
    log.record(makeEntry({ sessionId: "s2" }));
    log.record(makeEntry({ sessionId: "s1" }));

    const results = log.query({ sessionId: "s1" });
    expect(results).toHaveLength(2);
    expect(results.every((e) => e.sessionId === "s1")).toBe(true);
  });

  it("filters by workspaceId", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry({ workspaceId: "w1" }));
    log.record(makeEntry({ workspaceId: "w2" }));

    const results = log.query({ workspaceId: "w2" });
    expect(results).toHaveLength(1);
    expect(results[0].workspaceId).toBe("w2");
  });

  it("filters by before timestamp", () => {
    const log = new AuditLog(logPath);

    // Write raw entries with controlled timestamps to avoid same-ms flakiness
    const line1 = JSON.stringify({ id: "a", timestamp: 1000, tool: "old", sessionId: "s1", workspaceId: "w1", decision: "allow", resolvedBy: "policy", layer: "preset", displaySummary: "ls" });
    const line2 = JSON.stringify({ id: "b", timestamp: 2000, tool: "new", sessionId: "s1", workspaceId: "w1", decision: "allow", resolvedBy: "policy", layer: "preset", displaySummary: "ls" });
    writeFileSync(logPath, line1 + "\n" + line2 + "\n");

    const results = log.query({ before: 1500 });
    expect(results).toHaveLength(1);
    expect(results[0].tool).toBe("old");
  });

  it("respects limit", () => {
    const log = new AuditLog(logPath);
    for (let i = 0; i < 10; i++) {
      log.record(makeEntry({ tool: `tool-${i}` }));
    }

    const results = log.query({ limit: 3 });
    expect(results).toHaveLength(3);
  });

  it("clamps limit to max", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry());

    // Should not crash with absurd limit
    const results = log.query({ limit: 999999 });
    expect(results).toHaveLength(1);
  });

  it("returns empty array for missing file", () => {
    const log = new AuditLog(join(dir, "nonexistent.jsonl"));
    expect(log.query()).toEqual([]);
  });

  it("skips malformed JSON lines", () => {
    writeFileSync(logPath, '{"valid":true,"id":"x","timestamp":1}\n{bad json\n');
    const log = new AuditLog(logPath);
    const results = log.query();
    expect(results).toHaveLength(1);
  });

  // ─── rotation ───

  it("rotates when file exceeds 10MB", () => {
    // Write a large file
    const bigLine = JSON.stringify(makeEntry({ displaySummary: "x".repeat(1000) }));
    const lines = Array(11000).fill(bigLine).join("\n") + "\n";
    writeFileSync(logPath, lines);

    const log = new AuditLog(logPath);
    log.maybeRotate();

    expect(existsSync(logPath + ".1")).toBe(true);
    expect(existsSync(logPath)).toBe(false); // Original was renamed
  });

  it("does not rotate when file is small", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry());
    log.maybeRotate();
    expect(existsSync(logPath + ".1")).toBe(false);
  });

  // ─── combined filters ───

  it("applies sessionId + workspaceId + before together", () => {
    const log = new AuditLog(logPath);
    log.record(makeEntry({ sessionId: "s1", workspaceId: "w1" }));
    const target = log.record(makeEntry({ sessionId: "s1", workspaceId: "w1" }));
    log.record(makeEntry({ sessionId: "s1", workspaceId: "w2" }));
    log.record(makeEntry({ sessionId: "s2", workspaceId: "w1" }));

    const results = log.query({
      sessionId: "s1",
      workspaceId: "w1",
      before: target.timestamp + 1,
    });
    expect(results).toHaveLength(2);
  });
});
