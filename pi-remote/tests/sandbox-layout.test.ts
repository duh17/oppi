import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SandboxManager } from "../src/sandbox.js";

let tmp: string;
let sandbox: SandboxManager;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "pi-remote-sandbox-layout-test-"));
  sandbox = new SandboxManager({ sandboxBaseDir: tmp });
});

afterEach(() => {
  rmSync(tmp, { recursive: true, force: true });
});

describe("Sandbox workspace layout migration", () => {
  it("migrates legacy session-scoped sandbox into workspace layout", () => {
    const legacyRoot = join(tmp, "u1", "s1");

    mkdirSync(join(legacyRoot, "workspace"), { recursive: true });
    writeFileSync(join(legacyRoot, "workspace", "note.txt"), "hello");

    mkdirSync(join(legacyRoot, "agent", "extensions", "permission-gate"), { recursive: true });
    writeFileSync(join(legacyRoot, "agent", "extensions", "permission-gate", "index.ts"), "export default 1;");
    writeFileSync(join(legacyRoot, "agent", "extensions", "permission-gate", "package.json"), "{}");
    writeFileSync(join(legacyRoot, "agent", "auth.json"), "{}");

    sandbox.migrateLegacySessionLayout("u1", "w1", "s1");

    const workspaceFile = join(tmp, "u1", "w1", "workspace", "note.txt");
    const migratedAuth = join(tmp, "u1", "w1", "sessions", "s1", "agent", "auth.json");
    const marker = join(tmp, "u1", "w1", ".migration", "s1.json");

    expect(existsSync(workspaceFile)).toBe(true);
    expect(existsSync(migratedAuth)).toBe(true);
    expect(existsSync(marker)).toBe(true);

    const markerData = JSON.parse(readFileSync(marker, "utf-8")) as { source: string; destination: string };
    expect(markerData.source).toContain("/u1/s1");
    expect(markerData.destination).toContain("/u1/w1/sessions/s1");
  });

  it("migrateAllLegacySandboxes scans and migrates legacy dirs on startup", () => {
    // Create two legacy session dirs and one already-workspace dir.
    const legacy1 = join(tmp, "u1", "sess-a");
    mkdirSync(join(legacy1, "agent"), { recursive: true });
    writeFileSync(join(legacy1, "agent", "auth.json"), "{}");
    mkdirSync(join(legacy1, "workspace"), { recursive: true });
    writeFileSync(join(legacy1, "workspace", "file.txt"), "data");

    const legacy2 = join(tmp, "u1", "sess-b");
    mkdirSync(join(legacy2, "agent"), { recursive: true });
    writeFileSync(join(legacy2, "agent", "auth.json"), "{}");

    const workspaceDir = join(tmp, "u1", "my-workspace");
    mkdirSync(join(workspaceDir, "sessions", "s1"), { recursive: true });

    const result = sandbox.migrateAllLegacySandboxes();

    expect(result.migrated).toBe(2);
    expect(result.skipped).toBe(1); // my-workspace already has sessions/
    expect(result.errors).toHaveLength(0);

    // Verify migrated layout.
    expect(existsSync(join(tmp, "u1", "session-sess-a", "sessions", "sess-a", "agent", "auth.json"))).toBe(true);
    expect(existsSync(join(tmp, "u1", "session-sess-a", "workspace", "file.txt"))).toBe(true);
    expect(existsSync(join(tmp, "u1", "session-sess-b", "sessions", "sess-b", "agent", "auth.json"))).toBe(true);

    // Verify rollback markers.
    expect(existsSync(join(tmp, "u1", "session-sess-a", ".migration", "sess-a.json"))).toBe(true);
    expect(existsSync(join(tmp, "u1", "session-sess-b", ".migration", "sess-b.json"))).toBe(true);
  });

  it("migrateAllLegacySandboxes is idempotent", () => {
    const legacy = join(tmp, "u1", "sess-c");
    mkdirSync(join(legacy, "agent"), { recursive: true });
    writeFileSync(join(legacy, "agent", "auth.json"), "{}");

    const first = sandbox.migrateAllLegacySandboxes();
    expect(first.migrated).toBe(1);

    // Second run — legacy dir still has agent/ (copy-based, not moved)
    // but workspace target already exists, so cpSync is skipped inside migrateLegacy.
    const second = sandbox.migrateAllLegacySandboxes();
    // Still counts as "migrated" because the legacy dir still matches the pattern,
    // but the actual copy is a no-op (destination exists).
    expect(second.migrated).toBe(1);
    expect(second.errors).toHaveLength(0);
  });

  it("migrateAllLegacySandboxes skips special dirs (_memory, .hidden)", () => {
    mkdirSync(join(tmp, "_memory", "u1", "default"), { recursive: true });
    mkdirSync(join(tmp, ".internal"), { recursive: true });

    const result = sandbox.migrateAllLegacySandboxes();
    expect(result.migrated).toBe(0);
    expect(result.skipped).toBe(0);
    expect(result.errors).toHaveLength(0);
  });

  it("migrateAllLegacySandboxes returns empty on fresh install", () => {
    const result = sandbox.migrateAllLegacySandboxes();
    expect(result.migrated).toBe(0);
    expect(result.skipped).toBe(0);
    expect(result.errors).toHaveLength(0);
  });

  it("validateSession supports workspace-scoped session directories", () => {
    const agentDir = join(tmp, "u1", "w1", "sessions", "s1", "agent");
    const gateDir = join(agentDir, "extensions", "permission-gate");

    mkdirSync(gateDir, { recursive: true });
    writeFileSync(join(gateDir, "index.ts"), "export default function() {}");
    writeFileSync(join(gateDir, "package.json"), "{}");
    writeFileSync(join(agentDir, "auth.json"), "{}");

    const { errors, warnings } = sandbox.validateSession("u1", "s1", { workspaceId: "w1" });
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(0);
  });
});
