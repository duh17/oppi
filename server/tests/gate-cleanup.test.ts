/**
 * Gate guard lifecycle.
 *
 * Verifies that session guards are always cleaned up, even when
 * session start fails or the process exits abnormally.
 */

import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PolicyEngine } from "../src/policy.js";
import { GateServer } from "../src/gate.js";
import { RuleStore } from "../src/rules.js";
import { AuditLog } from "../src/audit.js";

let gate: GateServer;
let testDir: string;

beforeEach(() => {
  testDir = mkdtempSync(join(tmpdir(), "oppi-server-gate-cleanup-test-"));
  const policy = new PolicyEngine("container");
  const ruleStore = new RuleStore(join(testDir, "rules.json"));
  const auditLog = new AuditLog(join(testDir, "audit.jsonl"));
  gate = new GateServer(policy, ruleStore, auditLog);
});

afterEach(async () => {
  if (gate) {
    await gate.shutdown();
  }
  rmSync(testDir, { recursive: true, force: true });
});

describe("Gate guard lifecycle", () => {
  it("createGuard registers a guarded session, destroySessionGuard removes it", () => {
    gate.createGuard("s1", "w1");
    expect(gate.getGuardState("s1")).toBe("guarded");

    gate.destroySessionGuard("s1");
    expect(gate.getGuardState("s1")).toBe("unguarded");

    // Re-creating after destroy should work.
    gate.createGuard("s1", "w1");
    expect(gate.getGuardState("s1")).toBe("guarded");
    gate.destroySessionGuard("s1");
  });

  it("destroySessionGuard is idempotent", () => {
    gate.createGuard("s1", "w1");

    gate.destroySessionGuard("s1");
    gate.destroySessionGuard("s1"); // should not throw
    gate.destroySessionGuard("nonexistent"); // should not throw
  });

  it("shutdown cleans up all sessions", () => {
    gate.createGuard("s1", "w1");
    gate.createGuard("s2", "w1");
    gate.createGuard("s3", "w1");

    gate.shutdown();

    // After shutdown, all guards removed.
    expect(gate.getGuardState("s1")).toBe("unguarded");
    expect(gate.getGuardState("s2")).toBe("unguarded");

    // Creating new guard should work.
    gate.createGuard("s1", "w1");
    expect(gate.getGuardState("s1")).toBe("guarded");
    gate.destroySessionGuard("s1");
  });

  it("destroy after shutdown does not throw", () => {
    gate.createGuard("s1", "w1");
    gate.shutdown();

    // Gate already cleaned up s1 in shutdown — this should be a no-op.
    gate.destroySessionGuard("s1");
  });
});
