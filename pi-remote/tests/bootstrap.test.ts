import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync, writeFileSync, mkdirSync, rmSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { SandboxManager } from "../src/sandbox.js";

let tmp: string;
let sandbox: SandboxManager;

beforeEach(() => {
  tmp = mkdtempSync(join(tmpdir(), "pi-remote-bootstrap-test-"));
  sandbox = new SandboxManager({ sandboxBaseDir: tmp });
});

afterEach(() => {
  rmSync(tmp, { recursive: true });
});

/**
 * Create a minimal sandbox directory structure matching what initSession() produces.
 * Caller can omit specific files to test validation.
 */
function setupSandboxDir(
  userId: string,
  sessionId: string,
  opts?: {
    skipGateDir?: boolean;
    skipGateIndex?: boolean;
    skipGatePackage?: boolean;
    includeMemory?: boolean;
    skipAuth?: boolean;
  },
): void {
  const agentDir = join(tmp, userId, sessionId, "agent");
  const extensionsDir = join(agentDir, "extensions");

  mkdirSync(extensionsDir, { recursive: true });

  if (!opts?.skipGateDir) {
    const gateDir = join(extensionsDir, "permission-gate");
    mkdirSync(gateDir, { recursive: true });
    if (!opts?.skipGateIndex) {
      writeFileSync(join(gateDir, "index.ts"), 'export default function() {}');
    }
    if (!opts?.skipGatePackage) {
      writeFileSync(join(gateDir, "package.json"), '{"name":"permission-gate"}');
    }
  }

  if (opts?.includeMemory) {
    writeFileSync(join(extensionsDir, "memory.ts"), 'export default function() {}');
  }

  if (!opts?.skipAuth) {
    writeFileSync(join(agentDir, "auth.json"), '{"providers":{}}');
  }
}

// ─── Healthy sessions ───

describe("validateSession — healthy", () => {
  it("passes with all files present", () => {
    setupSandboxDir("user1", "sess1");
    const { errors, warnings } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(0);
  });

  it("passes with memory extension", () => {
    setupSandboxDir("user1", "sess1", { includeMemory: true });
    const { errors, warnings } = sandbox.validateSession("user1", "sess1", { memoryEnabled: true });
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(0);
  });

  it("passes with memory present but not requested", () => {
    setupSandboxDir("user1", "sess1", { includeMemory: true });
    const { errors, warnings } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(0);
  });
});

// ─── Missing gate ───

describe("validateSession — missing gate", () => {
  it("errors on missing gate directory", () => {
    setupSandboxDir("user1", "sess1", { skipGateDir: true });
    const { errors } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("directory missing");
  });

  it("errors on missing gate index.ts", () => {
    setupSandboxDir("user1", "sess1", { skipGateIndex: true });
    const { errors } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("index.ts");
  });

  it("errors on missing gate package.json", () => {
    setupSandboxDir("user1", "sess1", { skipGatePackage: true });
    const { errors } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("package.json");
  });

  it("errors on both index.ts and package.json missing", () => {
    setupSandboxDir("user1", "sess1", { skipGateIndex: true, skipGatePackage: true });
    const { errors } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(2);
  });
});

// ─── Memory ───

describe("validateSession — memory", () => {
  it("warns when memory enabled but extension missing", () => {
    setupSandboxDir("user1", "sess1");
    const { errors, warnings } = sandbox.validateSession("user1", "sess1", { memoryEnabled: true });
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("Memory");
  });

  it("no warning when memory disabled", () => {
    setupSandboxDir("user1", "sess1");
    const { errors, warnings } = sandbox.validateSession("user1", "sess1", { memoryEnabled: false });
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(0);
  });

  it("no warning when memory not specified (undefined)", () => {
    setupSandboxDir("user1", "sess1");
    const { warnings } = sandbox.validateSession("user1", "sess1");
    expect(warnings).toHaveLength(0);
  });
});

// ─── Auth ───

describe("validateSession — auth", () => {
  it("warns on missing auth.json", () => {
    setupSandboxDir("user1", "sess1", { skipAuth: true });
    const { errors, warnings } = sandbox.validateSession("user1", "sess1");
    expect(errors).toHaveLength(0);
    expect(warnings).toHaveLength(1);
    expect(warnings[0]).toContain("auth.json");
  });
});

// ─── Combined ───

describe("validateSession — combined", () => {
  it("reports gate error + memory warning + auth warning", () => {
    setupSandboxDir("user1", "sess1", { skipGateDir: true, skipAuth: true });
    const { errors, warnings } = sandbox.validateSession("user1", "sess1", { memoryEnabled: true });
    expect(errors).toHaveLength(1);
    expect(warnings).toHaveLength(2);
  });

  it("reports errors for empty sandbox dir (nothing synced)", () => {
    mkdirSync(join(tmp, "user1", "sess1", "agent", "extensions"), { recursive: true });
    const { errors, warnings } = sandbox.validateSession("user1", "sess1");
    expect(errors.length).toBeGreaterThan(0);
    expect(warnings.some(w => w.includes("auth"))).toBe(true);
  });
});
