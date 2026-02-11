import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from "node:fs";
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

describe("Sandbox workspace layout", () => {
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

  it("validateSession fails when workspace-scoped gate extension is missing", () => {
    const agentDir = join(tmp, "u1", "w1", "sessions", "s1", "agent");
    mkdirSync(agentDir, { recursive: true });

    const { errors, warnings } = sandbox.validateSession("u1", "s1", { workspaceId: "w1" });
    expect(errors.some((error) => error.includes("Permission gate extension directory missing"))).toBe(true);
    expect(warnings.some((warning) => warning.includes("auth.json not synced"))).toBe(true);
  });

  it("getWorkDir uses workspace id (no session-id fallback)", () => {
    const workDir = sandbox.getWorkDir("u1", "s1", "w1");
    expect(workDir).toContain("/u1/w1/workspace");
    expect(existsSync(workDir)).toBe(true);
  });
});
