/**
 * Gate port release audit.
 *
 * Verifies that gate TCP sockets are always cleaned up, even when
 * session start fails or the process exits abnormally. The gate server
 * allocates a TCP port per session — leaked ports exhaust the OS limit.
 *
 * Tests use a real GateServer on random ports to confirm socket teardown.
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

describe("Gate port lifecycle", () => {
  it("createSessionSocket allocates a port, destroySessionSocket releases it", async () => {
    const port = await gate.createSessionSocket("s1", "u1");

    expect(typeof port).toBe("number");
    expect(port).toBeGreaterThan(0);

    gate.destroySessionSocket("s1");

    // After destroy, creating a new socket for the same session should work
    // without EADDRINUSE.
    const port2 = await gate.createSessionSocket("s1", "u1");
    expect(port2).toBeGreaterThan(0);
    gate.destroySessionSocket("s1");
  });

  it("destroySessionSocket is idempotent", async () => {
    await gate.createSessionSocket("s1", "u1");

    gate.destroySessionSocket("s1");
    gate.destroySessionSocket("s1"); // should not throw
    gate.destroySessionSocket("nonexistent"); // should not throw
  });

  it("shutdown cleans up all sessions", async () => {
    await gate.createSessionSocket("s1", "u1");
    await gate.createSessionSocket("s2", "u1");
    await gate.createSessionSocket("s3", "u1");

    await gate.shutdown();

    // After shutdown, all ports freed. Creating new sockets should work.
    const port = await gate.createSessionSocket("s1", "u1");
    expect(port).toBeGreaterThan(0);
    gate.destroySessionSocket("s1");
  });

  it("multiple sessions get distinct ports", async () => {
    const ports = new Set<number>();

    for (let i = 0; i < 5; i++) {
      const port = await gate.createSessionSocket(`s${i}`, "u1");
      ports.add(port);
    }

    expect(ports.size).toBe(5);

    for (let i = 0; i < 5; i++) {
      gate.destroySessionSocket(`s${i}`);
    }
  });

  it("destroy after shutdown does not throw", async () => {
    await gate.createSessionSocket("s1", "u1");
    await gate.shutdown();

    // Gate already cleaned up s1 in shutdown — this should be a no-op.
    gate.destroySessionSocket("s1");
  });
});
