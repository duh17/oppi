import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync, utimesSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RuleStore, type RuleInput } from "../src/rules.js";

function tmpRulesPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-rules-"));
  return join(dir, "rules.json");
}

function makeRule(overrides: Partial<RuleInput> = {}): RuleInput {
  return {
    tool: "bash",
    decision: "allow",
    scope: "global",
    source: "manual",
    label: "test rule",
    ...overrides,
  };
}

describe("RuleStore", () => {
  let rulesPath: string;

  beforeEach(() => {
    rulesPath = tmpRulesPath();
  });

  afterEach(() => {
    const dir = join(rulesPath, "..");
    if (existsSync(dir)) rmSync(dir, { recursive: true });
  });

  it("adds and persists global rule", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ executable: "git" }));

    expect(rule.id).toBeTruthy();
    expect(store.getAll()).toHaveLength(1);
    expect(store.getAll()[0].decision).toBe("allow");

    expect(existsSync(rulesPath)).toBe(true);
    const onDisk = JSON.parse(readFileSync(rulesPath, "utf-8"));
    expect(onDisk).toHaveLength(1);
    expect(onDisk[0].tool).toBe("bash");
    expect(onDisk[0].decision).toBe("allow");
  });

  it("adds rule with all fields", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add({
      decision: "deny",
      tool: "bash",
      executable: "rm",
      pattern: "rm -rf *",
      scope: "global",
      label: "deny rm -rf",
      source: "manual",
    });

    expect(rule.decision).toBe("deny");
    expect(rule.executable).toBe("rm");
    expect(rule.pattern).toBe("rm -rf *");
    expect(rule.label).toBe("deny rm -rf");
  });

  it("keeps session rules in memory only", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ scope: "session", sessionId: "s1" }));

    expect(store.getAll()).toHaveLength(1);
    expect(existsSync(rulesPath)).toBe(false);
  });

  it("updates rule fields", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ label: "before", pattern: "git *" }));

    const updated = store.update(rule.id, {
      decision: "deny",
      label: "after",
      executable: "git",
      pattern: "git push*",
    });

    expect(updated).toBeTruthy();
    expect(updated?.decision).toBe("deny");
    expect(updated?.label).toBe("after");
    expect(updated?.executable).toBe("git");
    expect(updated?.pattern).toBe("git push*");
  });

  it("clears executable with null", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ executable: "make", pattern: "make deploy*", label: "test" }));
    expect(rule.executable).toBe("make");

    const updated = store.update(rule.id, { executable: null });
    expect(updated).toBeTruthy();
    expect(updated?.executable).toBeUndefined();
    expect(updated?.pattern).toBe("make deploy*");
  });

  it("clears label with null", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ label: "will be cleared" }));

    const updated = store.update(rule.id, { label: null });
    expect(updated).toBeTruthy();
    expect(updated?.label).toBeUndefined();
  });

  it("clears pattern with null", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ executable: "git", pattern: "git push*" }));

    const updated = store.update(rule.id, { pattern: null });
    expect(updated).toBeTruthy();
    expect(updated?.pattern).toBeUndefined();
    expect(updated?.executable).toBe("git");
  });

  it("clears expiresAt with null", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule({ expiresAt: Date.now() + 60_000 }));
    expect(rule.expiresAt).toBeGreaterThan(0);

    const updated = store.update(rule.id, { expiresAt: null });
    expect(updated).toBeTruthy();
    expect(updated?.expiresAt).toBeUndefined();
  });

  it("removes persisted rule", () => {
    const store = new RuleStore(rulesPath);
    const rule = store.add(makeRule());
    expect(store.getAll()).toHaveLength(1);

    const removed = store.remove(rule.id);
    expect(removed).toBe(true);
    expect(store.getAll()).toHaveLength(0);

    const onDisk = JSON.parse(readFileSync(rulesPath, "utf-8"));
    expect(onDisk).toHaveLength(0);
  });

  it("filters by workspace and session", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ scope: "global", label: "g" }));
    store.add(makeRule({ scope: "workspace", workspaceId: "w1", label: "w1" }));
    store.add(makeRule({ scope: "workspace", workspaceId: "w2", label: "w2" }));
    store.add(makeRule({ scope: "session", sessionId: "s1", label: "s1" }));

    expect(store.getForWorkspace("w1").map((r) => r.label).sort()).toEqual(["g", "w1"]);
    expect(store.getForSession("s1")).toHaveLength(1);
  });

  it("findMatching filters by tool, executable, and pattern", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ tool: "bash", pattern: "git push*", executable: "git" }));

    const matches = store.findMatching(
      "bash",
      { command: "git push origin main" },
      "s1",
      "w1",
      { executable: "git" },
    );

    expect(matches).toHaveLength(1);
  });

  it("dedupes duplicates on reload and migrates legacy file", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-rules-legacy-"));
    const path = join(dir, "rules.json");

    writeFileSync(
      path,
      JSON.stringify(
        [
          {
            id: "a",
            effect: "allow",
            tool: "bash",
            match: { executable: "git" },
            scope: "global",
            source: "learned",
            description: "legacy",
            createdAt: Date.now(),
          },
          {
            id: "b",
            effect: "allow",
            tool: "bash",
            match: { executable: "git" },
            scope: "global",
            source: "learned",
            description: "legacy",
            createdAt: Date.now(),
          },
        ],
        null,
        2,
      ),
      "utf-8",
    );

    const store = new RuleStore(path);
    expect(store.getAll()).toHaveLength(1);
    expect(store.getAll()[0].decision).toBe("allow");

    rmSync(dir, { recursive: true });
  });

  it("handles corrupt and empty files gracefully", () => {
    const dir1 = mkdtempSync(join(tmpdir(), "oppi-rules-corrupt-"));
    const p1 = join(dir1, "rules.json");
    writeFileSync(p1, "NOT JSON");
    expect(new RuleStore(p1).getAll()).toHaveLength(0);

    const dir2 = mkdtempSync(join(tmpdir(), "oppi-rules-empty-"));
    const p2 = join(dir2, "rules.json");
    writeFileSync(p2, "");
    expect(new RuleStore(p2).getAll()).toHaveLength(0);

    rmSync(dir1, { recursive: true });
    rmSync(dir2, { recursive: true });
  });

  // ── Hot-reload (mtime-based) ──

  it("hot-reloads rules when file is modified externally", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ label: "original" }));
    expect(store.getAll()).toHaveLength(1);

    // Externally write a different rules file with a bumped mtime
    const externalRules = [
      { id: "ext1", tool: "bash", decision: "allow", label: "external-1", scope: "global", source: "manual", createdAt: Date.now() },
      { id: "ext2", tool: "read", decision: "deny", label: "external-2", scope: "global", source: "manual", createdAt: Date.now() },
    ];
    writeFileSync(rulesPath, JSON.stringify(externalRules, null, 2));
    // Bump mtime to ensure it differs (macOS HFS+ has 1s mtime granularity)
    const future = new Date(Date.now() + 2000);
    utimesSync(rulesPath, future, future);

    // getAll should pick up the external change
    const reloaded = store.getAll();
    expect(reloaded).toHaveLength(2);
    expect(reloaded.map((r) => r.label).sort()).toEqual(["external-1", "external-2"]);
  });

  it("does not reload when file is unchanged", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ label: "stable" }));

    // Call getAll multiple times — should return same data without re-reading
    const first = store.getAll();
    const second = store.getAll();
    expect(first).toEqual(second);
    expect(first).toHaveLength(1);
  });

  it("hot-reload does not discard session rules", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ scope: "global", label: "persisted" }));
    store.add(makeRule({ scope: "session", sessionId: "s1", label: "session-only" }));
    expect(store.getAll()).toHaveLength(2);

    // External write replaces persisted rules
    const externalRules = [
      { id: "ext1", tool: "bash", decision: "allow", label: "replaced", scope: "global", source: "manual", createdAt: Date.now() },
    ];
    writeFileSync(rulesPath, JSON.stringify(externalRules, null, 2));
    const future = new Date(Date.now() + 2000);
    utimesSync(rulesPath, future, future);

    // Session rule should survive the reload
    const reloaded = store.getAll();
    expect(reloaded).toHaveLength(2);
    expect(reloaded.map((r) => r.label).sort()).toEqual(["replaced", "session-only"]);
  });

  it("hot-reload survives file deletion", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ label: "will-survive" }));
    expect(store.getAll()).toHaveLength(1);

    // Delete the file externally
    rmSync(rulesPath);

    // getAll should still work (mtime changes to 0, triggers reload, load handles missing file)
    const afterDelete = store.getAll();
    expect(afterDelete).toHaveLength(0);
  });

  it("own save does not trigger redundant reload", () => {
    const store = new RuleStore(rulesPath);
    store.add(makeRule({ label: "rule-1" }));
    store.add(makeRule({ label: "rule-2", executable: "npm" }));

    // After save, getAll should still work without a reload cycle
    expect(store.getAll()).toHaveLength(2);
  });
});
