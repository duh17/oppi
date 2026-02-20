import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RuleStore, type LearnedRule } from "../src/rules.js";

function tmpRulesPath(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-rules-"));
  return join(dir, "rules.json");
}

function makeRule(overrides: Partial<Omit<LearnedRule, "id" | "createdAt">> = {}): Omit<LearnedRule, "id" | "createdAt"> {
  return {
    effect: "allow",
    tool: "bash",
    scope: "global",
    source: "learned",
    description: "test rule",
    risk: "low",
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

  // ── CRUD ──

  describe("add / getAll", () => {
    it("adds a global rule and persists to disk", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule());

      expect(rule.id).toBeTruthy();
      expect(rule.createdAt).toBeGreaterThan(0);
      expect(store.getAll()).toHaveLength(1);

      // Persisted to disk
      expect(existsSync(rulesPath)).toBe(true);
      const onDisk = JSON.parse(readFileSync(rulesPath, "utf-8"));
      expect(onDisk).toHaveLength(1);
      expect(onDisk[0].id).toBe(rule.id);
    });

    it("adds a session rule in-memory only", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "session", sessionId: "s1" }));

      expect(store.getAll()).toHaveLength(1);
      // NOT persisted
      expect(existsSync(rulesPath)).toBe(false);
    });

    it("adds workspace-scoped rule with workspaceId", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule({ scope: "workspace", workspaceId: "ws1" }));

      expect(rule.scope).toBe("workspace");
      expect(rule.workspaceId).toBe("ws1");
      // Persisted
      expect(existsSync(rulesPath)).toBe(true);
    });
  });

  describe("remove", () => {
    it("removes a persisted rule", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule());
      expect(store.getAll()).toHaveLength(1);

      const removed = store.remove(rule.id);
      expect(removed).toBe(true);
      expect(store.getAll()).toHaveLength(0);

      // Disk updated
      const onDisk = JSON.parse(readFileSync(rulesPath, "utf-8"));
      expect(onDisk).toHaveLength(0);
    });

    it("removes a session rule", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule({ scope: "session", sessionId: "s1" }));

      const removed = store.remove(rule.id);
      expect(removed).toBe(true);
      expect(store.getAll()).toHaveLength(0);
    });

    it("returns false for unknown id", () => {
      const store = new RuleStore(rulesPath);
      expect(store.remove("nonexistent")).toBe(false);
    });
  });

  describe("update", () => {
    it("updates a persisted rule and writes changes to disk", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule({ description: "before" }));

      const updated = store.update(rule.id, {
        effect: "deny",
        description: "after",
        match: { executable: "git", commandPattern: "git push*" },
      });

      expect(updated).toBeTruthy();
      expect(updated?.effect).toBe("deny");
      expect(updated?.description).toBe("after");
      expect(updated?.match?.executable).toBe("git");

      const onDisk = JSON.parse(readFileSync(rulesPath, "utf-8"));
      expect(onDisk[0].effect).toBe("deny");
      expect(onDisk[0].description).toBe("after");
      expect(onDisk[0].match.executable).toBe("git");
    });

    it("updates session rules in-memory", () => {
      const store = new RuleStore(rulesPath);
      const rule = store.add(makeRule({ scope: "session", sessionId: "s1", tool: "bash" }));

      const updated = store.update(rule.id, { tool: "write", expiresAt: Date.now() + 10_000 });
      expect(updated?.tool).toBe("write");
      expect(updated?.expiresAt).toBeGreaterThan(Date.now());
      expect(existsSync(rulesPath)).toBe(false);
    });

    it("returns null for unknown id", () => {
      const store = new RuleStore(rulesPath);
      expect(store.update("missing", { description: "nope" })).toBeNull();
    });
  });

  // ── Queries ──

  describe("getGlobal", () => {
    it("returns only global rules", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "global", description: "g1" }));
      store.add(makeRule({ scope: "workspace", workspaceId: "ws1", description: "w1" }));
      store.add(makeRule({ scope: "session", sessionId: "s1", description: "s1" }));

      const globals = store.getGlobal();
      expect(globals).toHaveLength(1);
      expect(globals[0].description).toBe("g1");
    });
  });

  describe("getForWorkspace", () => {
    it("returns global + matching workspace rules", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "global", description: "g" }));
      store.add(makeRule({ scope: "workspace", workspaceId: "ws1", description: "w1" }));
      store.add(makeRule({ scope: "workspace", workspaceId: "ws2", description: "w2" }));

      const rules = store.getForWorkspace("ws1");
      expect(rules).toHaveLength(2); // global + ws1
      expect(rules.map((r) => r.description).sort()).toEqual(["g", "w1"]);
    });
  });

  describe("getForSession", () => {
    it("returns only session rules for that session", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "session", sessionId: "s1", description: "a" }));
      store.add(makeRule({ scope: "session", sessionId: "s2", description: "b" }));

      const rules = store.getForSession("s1");
      expect(rules).toHaveLength(1);
      expect(rules[0].description).toBe("a");
    });
  });

  // ── findMatching ──

  describe("findMatching", () => {
    it("matches by tool name", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "bash" }));
      store.add(makeRule({ tool: "write" }));

      const matches = store.findMatching("bash", {}, "s1", "ws1");
      expect(matches).toHaveLength(1);
      expect(matches[0].tool).toBe("bash");
    });

    it("wildcard tool matches everything", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "*" }));

      expect(store.findMatching("bash", {}, "s1", "ws1")).toHaveLength(1);
      expect(store.findMatching("write", {}, "s1", "ws1")).toHaveLength(1);
    });

    it("matches by executable", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "bash", match: { executable: "git" } }));

      expect(store.findMatching("bash", {}, "s1", "ws1", { executable: "git" })).toHaveLength(1);
      expect(store.findMatching("bash", {}, "s1", "ws1", { executable: "npm" })).toHaveLength(0);
    });

    it("matches by domain", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "bash", match: { domain: "github.com" } }));

      expect(store.findMatching("bash", {}, "s1", "ws1", { domain: "github.com" })).toHaveLength(1);
      expect(store.findMatching("bash", {}, "s1", "ws1", { domain: "evil.com" })).toHaveLength(0);
    });

    it("matches by path pattern with glob", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "write", match: { pathPattern: "/workspace/**" } }));

      expect(store.findMatching("write", {}, "s1", "ws1", { path: "/workspace/src/foo.ts" })).toHaveLength(1);
      expect(store.findMatching("write", {}, "s1", "ws1", { path: "/etc/passwd" })).toHaveLength(0);
    });

    it("path pattern requires path in parsed context", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "write", match: { pathPattern: "/workspace/**" } }));

      // No path in parsed → no match
      expect(store.findMatching("write", {}, "s1", "ws1")).toHaveLength(0);
    });

    it("matches by command pattern glob", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ tool: "bash", match: { commandPattern: "git *" } }));

      expect(store.findMatching("bash", { command: "git push origin main" }, "s1", "ws1")).toHaveLength(1);
      expect(store.findMatching("bash", { command: "rm -rf /" }, "s1", "ws1")).toHaveLength(0);
    });

    it("skips expired rules", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ expiresAt: Date.now() - 1000 } as any));

      expect(store.findMatching("bash", {}, "s1", "ws1")).toHaveLength(0);
    });

    it("includes non-expired rules", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ expiresAt: Date.now() + 60_000 } as any));

      expect(store.findMatching("bash", {}, "s1", "ws1")).toHaveLength(1);
    });

    it("includes session rules in matching", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "session", sessionId: "s1", tool: "bash" }));

      expect(store.findMatching("bash", {}, "s1", "ws1")).toHaveLength(1);
      // Different session → no match
      expect(store.findMatching("bash", {}, "s2", "ws1")).toHaveLength(0);
    });
  });

  // ── Session lifecycle ──

  describe("clearSessionRules", () => {
    it("removes all rules for a session", () => {
      const store = new RuleStore(rulesPath);
      store.add(makeRule({ scope: "session", sessionId: "s1" }));
      store.add(makeRule({ scope: "session", sessionId: "s1" }));
      store.add(makeRule({ scope: "session", sessionId: "s2" }));
      store.add(makeRule({ scope: "global" }));

      store.clearSessionRules("s1");

      expect(store.getAll()).toHaveLength(2); // s2 + global
      expect(store.getForSession("s1")).toHaveLength(0);
      expect(store.getForSession("s2")).toHaveLength(1);
    });
  });

  // ── Persistence ──

  describe("persistence", () => {
    it("survives reload", () => {
      const store1 = new RuleStore(rulesPath);
      store1.add(makeRule({ description: "persistent" }));

      const store2 = new RuleStore(rulesPath);
      expect(store2.getAll()).toHaveLength(1);
      expect(store2.getAll()[0].description).toBe("persistent");
    });

    it("session rules do NOT survive reload", () => {
      const store1 = new RuleStore(rulesPath);
      store1.add(makeRule({ scope: "session", sessionId: "s1" }));

      const store2 = new RuleStore(rulesPath);
      expect(store2.getAll()).toHaveLength(0);
    });

    it("handles missing file gracefully", () => {
      const store = new RuleStore(join(tmpdir(), "nonexistent", "rules.json"));
      expect(store.getAll()).toHaveLength(0);
    });

    it("handles corrupt file gracefully", () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-rules-corrupt-"));
      const path = join(dir, "rules.json");
      writeFileSync(path, "NOT JSON AT ALL");

      const store = new RuleStore(path);
      expect(store.getAll()).toHaveLength(0);

      rmSync(dir, { recursive: true });
    });

    it("handles empty file gracefully", () => {
      const dir = mkdtempSync(join(tmpdir(), "oppi-rules-empty-"));
      const path = join(dir, "rules.json");
      writeFileSync(path, "");

      const store = new RuleStore(path);
      expect(store.getAll()).toHaveLength(0);

      rmSync(dir, { recursive: true });
    });
  });
});
