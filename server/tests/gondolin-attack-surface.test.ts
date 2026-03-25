/**
 * Gondolin sandbox attack surface tests.
 *
 * Boots a real QEMU VM with readonlyMounts (simulating what sdk-backend.ts does)
 * and probes for the lethal trifecta:
 *   1. Can the VM read auth.json via readonlyMount? → YES (proven)
 *   2. Can the VM write to readonlyMounts? → NO (ReadonlyProvider blocks)
 *   3. Can the VM read host paths outside of mounts? → NO (VFS boundary)
 *   4. Env var leakage? → API keys pass through (STRIP_ENV only strips HOME/USER/PATH)
 *   5. Network egress with empty allowedHosts? → STILL WORKS (allowedHosts:[] != blocked)
 *
 * Requires QEMU installed. Skipped automatically if not available.
 *
 * KNOWN ISSUES (documented):
 * - auth.json readable via readonlyMount of agentDir (production mounts it)
 * - allowedHosts: [] does not block network egress
 * - STRIP_ENV only blocks 5 exact names, other env vars pass through
 *   (low severity: server process.env typically has no credential env vars)
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import {
  isQemuAvailable,
  GondolinManager,
} from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { createGondolinBashOps } from "../src/gondolin-ops.js";

let qemuAvailable = false;

beforeAll(async () => {
  qemuAvailable = await isQemuAvailable();
  if (!qemuAvailable) {
    console.log("[attack-surface] Skipping: QEMU not installed");
  }
}, 10_000);

describe("Gondolin attack surface", { timeout: 120_000 }, () => {
  let hostDir: string;
  let fakeAgentDir: string;
  let manager: GondolinManager;
  let vm: GondolinVm;

  beforeAll(async () => {
    if (!qemuAvailable) return;

    // Create a fake workspace directory
    hostDir = mkdtempSync(join(tmpdir(), "gondolin-attack-"));
    writeFileSync(join(hostDir, "workspace-file.txt"), "workspace content");

    // Create a fake agent directory that mirrors ~/.pi/agent/ structure
    // with a fake auth.json to test whether it's readable
    fakeAgentDir = mkdtempSync(join(tmpdir(), "gondolin-agent-"));
    writeFileSync(
      join(fakeAgentDir, "auth.json"),
      JSON.stringify({ anthropic: { type: "api_key", key: "sk-ant-FAKE-TEST-KEY" } }),
    );
    mkdirSync(join(fakeAgentDir, "skills"), { recursive: true });
    writeFileSync(join(fakeAgentDir, "skills", "test-skill.md"), "# Test Skill");
    writeFileSync(join(fakeAgentDir, "AGENTS.md"), "# Test Agent Config");

    // Boot VM with readonlyMounts matching what sdk-backend.ts does
    manager = new GondolinManager();

    const workspace = {
      id: "attack-test",
      name: "Attack Surface Test",
      skills: [] as string[],
      runtime: "sandbox" as const,
      sandboxConfig: { allowedHosts: [] as string[] }, // no network
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    // Use the real factory but with our fake agent dir as a readonlyMount
    vm = await manager.ensureWorkspaceVm(workspace, hostDir, undefined, [fakeAgentDir]);
  }, 90_000);

  afterAll(async () => {
    if (manager) await manager.stopAll();
    if (hostDir) rmSync(hostDir, { recursive: true, force: true });
    if (fakeAgentDir) rmSync(fakeAgentDir, { recursive: true, force: true });
  }, 30_000);

  // ─── Attack Vector 1: Can the VM read auth.json via readonlyMount? ───

  it("ATTACK: auth.json IS readable via readonlyMount", async () => {
    if (!qemuAvailable) return;

    // PROVEN: readonlyMount mounts the entire agentDir including auth.json.
    // The VM can read API keys at the mounted path.
    const result = await vm.exec(`cat ${fakeAgentDir}/auth.json`);

    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("sk-ant-FAKE-TEST-KEY");
  });

  it("AGENTS.md is readable via readonlyMount (intended)", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${fakeAgentDir}/AGENTS.md`);
    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("# Test Agent Config");
  });

  it("skill files are readable via readonlyMount (intended)", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${fakeAgentDir}/skills/test-skill.md`);
    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("# Test Skill");
  });

  // ─── Attack Vector 2: Can the VM write to readonlyMounts? ───

  it("SAFE: writes to readonlyMount are blocked", async () => {
    if (!qemuAvailable) return;

    // ReadonlyProvider wraps the RealFSProvider — writes fail.
    await vm.exec(`echo "HACKED" > ${fakeAgentDir}/auth.json 2>&1`);

    // Verify the original content is unchanged
    const verify = await vm.exec(`cat ${fakeAgentDir}/auth.json`);
    expect(verify.ok).toBe(true);
    expect(verify.stdout).toContain("sk-ant-FAKE-TEST-KEY");
    expect(verify.stdout).not.toContain("HACKED");
  });

  // ─── Attack Vector 3: Can the VM see the REAL ~/.pi/agent? ───

  it("SAFE: real host ~/.pi/agent is not accessible (only the mounted fake)", async () => {
    if (!qemuAvailable) return;

    const realAgentDir = join(homedir(), ".pi", "agent");
    const result = await vm.exec(`cat ${realAgentDir}/auth.json 2>&1 || true`);

    // Only our fake agentDir is mounted — the real one is not visible.
    expect(result.stdout).toContain("No such file");
    expect(result.stdout).not.toContain("api_key");
  });

  it("readonlyMount directory listing exposes auth.json", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`ls ${fakeAgentDir}/`);
    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("auth.json");
    expect(result.stdout).toContain("AGENTS.md");
    expect(result.stdout).toContain("skills");
  });

  // ─── Attack Vector 5: Env var leakage ───

  it("SAFE: HOME and USER are stripped from env", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinBashOps(vm, hostDir);
    const chunks: Buffer[] = [];
    await ops.exec("env", hostDir, {
      onData: (d) => chunks.push(d),
      env: {
        ANTHROPIC_API_KEY: "sk-ant-real-key-12345",
        HOME: "/Users/chenda",
        USER: "chenda",
        SECRET_TOKEN: "super-secret",
        SAFE_VAR: "this-is-fine",
      } as unknown as NodeJS.ProcessEnv,
    });
    const env = Buffer.concat(chunks).toString();

    // STRIP_ENV removes HOME, USER, LOGNAME, SHELL, PATH
    expect(env).not.toContain("HOME=/Users/chenda");
    expect(env).not.toContain("USER=chenda");
  });

  it("STRIP_ENV does not filter arbitrary env var names", async () => {
    if (!qemuAvailable) return;

    // STRIP_ENV only filters HOME/USER/LOGNAME/SHELL/PATH by exact name.
    // Any other env var passes through. In practice, oppi reads API keys
    // from auth.json (not env vars), so the server's process.env typically
    // has no credential env vars. But if someone runs the server with
    // ANTHROPIC_API_KEY=... in the environment, it would leak through.
    const ops = createGondolinBashOps(vm, hostDir);
    const chunks: Buffer[] = [];
    await ops.exec("env", hostDir, {
      onData: (d) => chunks.push(d),
      env: {
        SOME_CUSTOM_VAR: "custom-value",
        ANOTHER_VAR: "another-value",
      } as unknown as NodeJS.ProcessEnv,
    });
    const env = Buffer.concat(chunks).toString();

    expect(env).toContain("custom-value");
    expect(env).toContain("another-value");
  });

  // ─── Attack Vector 6: Network egress ───

  it("ATTACK: network egress works even with allowedHosts: []", async () => {
    if (!qemuAvailable) return;

    // PROVEN: allowedHosts: [] does NOT block outbound HTTP.
    // Gondolin's createHttpHooks apparently treats empty array differently
    // from what you'd expect — it does not deny all traffic.
    const result = await vm.exec(
      `curl -s --max-time 5 https://httpbin.org/get 2>&1 || echo "CURL_FAILED:$?"`,
    );

    // The request succeeds — httpbin returns a JSON response with "origin"
    expect(result.stdout).toContain('"origin"');
  });

  // ─── Workspace isolation ───

  it("workspace files are accessible at /workspace", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec("cat /workspace/workspace-file.txt");
    expect(result.ok).toBe(true);
    expect(result.stdout.trim()).toBe("workspace content");
  });

  it("can write to /workspace", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec('echo "new file" > /workspace/test-write.txt');
    expect(result.ok).toBe(true);

    const verify = await vm.exec("cat /workspace/test-write.txt");
    expect(verify.ok).toBe(true);
    expect(verify.stdout.trim()).toBe("new file");
  });
});
