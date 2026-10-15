/**
 * Gondolin sandbox attack surface tests.
 *
 * Boots a real QEMU VM with readonlyMounts (matching what sdk-backend.ts does)
 * and probes for the lethal trifecta:
 *   1. Can the VM read auth.json? → NO (only subdirs mounted, not agentDir root)
 *   2. Can the VM write to readonlyMounts? → NO (ReadonlyProvider blocks)
 *   3. Can the VM read host paths outside of mounts? → NO (VFS boundary)
 *   4. Env var leakage? → per-command host env is not forwarded into the VM
 *   5. Network egress with empty allowedHosts? → NO (deny-all)
 *
 * Requires QEMU installed. Skipped automatically if not available.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync, symlinkSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { isQemuAvailable, GondolinManager } from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { createGondolinBashOps } from "../src/gondolin-ops.js";
import {
  expandSkillCommand,
  readSandboxContextFiles,
  type DurableProjectResources,
} from "../src/durable-project-resources.js";

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
  let secretSkillDir: string;
  const SECRET_SKILL_GUEST = "/skills-probe/secret-skill";
  const LOCAL_SKILL_GUEST = "/skills-probe/local-skill";
  let manager: GondolinManager;
  let vm: GondolinVm;

  beforeAll(async () => {
    if (!qemuAvailable) return;

    // Create a fake workspace directory
    hostDir = mkdtempSync(join(tmpdir(), "gondolin-attack-"));
    writeFileSync(join(hostDir, "workspace-file.txt"), "workspace content");

    // Create a fake agent directory that mirrors ~/.pi/agent/ structure.
    // auth.json sits at the root — it should NOT be mounted into the VM.
    fakeAgentDir = mkdtempSync(join(tmpdir(), "gondolin-agent-"));
    writeFileSync(
      join(fakeAgentDir, "auth.json"),
      JSON.stringify({ anthropic: { type: "api_key", key: "sk-ant-FAKE-TEST-KEY" } }),
    );
    mkdirSync(join(fakeAgentDir, "skills"), { recursive: true });
    writeFileSync(join(fakeAgentDir, "skills", "test-skill.md"), "# Test Skill");
    mkdirSync(join(fakeAgentDir, "extensions"), { recursive: true });
    writeFileSync(join(fakeAgentDir, "extensions", "test-ext.js"), "// test extension");
    writeFileSync(join(fakeAgentDir, "AGENTS.md"), "# Test Agent Config");

    manager = new GondolinManager();

    const workspace = {
      id: "attack-test",
      name: "Attack Surface Test",
      runtime: "sandbox" as const,
      sandboxConfig: { allowedHosts: [] as string[] }, // no network
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };

    // Mount only what production mounts: specific subdirs, NOT agentDir root.
    // This matches the fixed sdk-backend.ts: skillPaths + extensions/ only.
    // A Skill directory holding secret-bearing names, and a Skill inside the writable
    // workspace that the guest may later retarget (durable `/skill:` reads through the VM).
    secretSkillDir = mkdtempSync(join(tmpdir(), "gondolin-secret-skill-"));
    writeFileSync(join(secretSkillDir, "SKILL.md"), "# Secret Skill");
    writeFileSync(join(secretSkillDir, ".env"), "SKILL_ENV_SECRET=1");
    writeFileSync(join(secretSkillDir, "signing.pem"), "PEM-SKILL-SECRET");
    mkdirSync(join(hostDir, "skills", "local-skill"), { recursive: true });
    writeFileSync(join(hostDir, "skills", "local-skill", "SKILL.md"), "local skill body");

    const readonlyMounts = [
      join(fakeAgentDir, "skills"),
      join(fakeAgentDir, "extensions"),
      { hostPath: secretSkillDir, guestPath: SECRET_SKILL_GUEST },
      { hostPath: join(hostDir, "skills", "local-skill"), guestPath: LOCAL_SKILL_GUEST },
    ];
    vm = await manager.ensureWorkspaceVm(workspace, hostDir, undefined, readonlyMounts);
  }, 90_000);

  afterAll(async () => {
    if (manager) await manager.stopAll();
    if (hostDir) rmSync(hostDir, { recursive: true, force: true });
    if (fakeAgentDir) rmSync(fakeAgentDir, { recursive: true, force: true });
    if (secretSkillDir) rmSync(secretSkillDir, { recursive: true, force: true });
  }, 30_000);

  // ─── Skill mounts: shadowed like the workspace; `/skill:` reads through the VM ───

  it("SAFE: a Skill mount hides secret-bearing names, like the workspace", async () => {
    if (!qemuAvailable) return;

    const listing = await vm.exec(`ls -A ${SECRET_SKILL_GUEST}`);
    expect(listing.ok).toBe(true);
    expect(listing.stdout).toContain("SKILL.md");
    expect(listing.stdout).not.toContain(".env");
    expect(listing.stdout).not.toContain("signing.pem");
    const read = await vm.exec(
      `cat ${SECRET_SKILL_GUEST}/.env ${SECRET_SKILL_GUEST}/signing.pem 2>&1 || true`,
    );
    expect(read.stdout).not.toContain("SKILL_ENV_SECRET");
    expect(read.stdout).not.toContain("PEM-SKILL-SECRET");
  });

  it("SAFE: a workspace AGENTS.md symlinked to .env reads as missing through the VM", async () => {
    if (!qemuAvailable) return;

    writeFileSync(join(hostDir, ".env"), "WORKSPACE_ENV_SECRET=1");
    symlinkSync(".env", join(hostDir, "AGENTS.md"));
    const resources: DurableProjectResources = {
      contextFiles: [{ path: "/workspace/AGENTS.md", content: "" }],
      guestContextPaths: new Set(["/workspace/AGENTS.md"]),
      skills: [],
      readonlyMounts: [],
    };
    const vmRead = async (path: string) => Buffer.from(await vm.fs.readFile(path)).toString("utf8");
    const presented = await readSandboxContextFiles(resources, vmRead, hostDir, "/workspace");
    expect(presented.contextFiles).toEqual([]);
    expect(JSON.stringify(presented)).not.toContain("WORKSPACE_ENV_SECRET");
  });

  it("SAFE: /skill: through the VM refuses a SKILL.md swapped for a host symlink", async () => {
    if (!qemuAvailable) return;

    const skillFile = `${LOCAL_SKILL_GUEST}/SKILL.md`;
    const resources: DurableProjectResources = {
      contextFiles: [],
      skills: [
        {
          name: "local-skill",
          description: "probe",
          filePath: skillFile,
          baseDir: LOCAL_SKILL_GUEST,
          source: "path",
          disableModelInvocation: false,
        } as DurableProjectResources["skills"][number],
      ],
      readonlyMounts: [],
    };
    const vmRead = async (path: string) => Buffer.from(await vm.fs.readFile(path)).toString("utf8");
    expect(await expandSkillCommand("/skill:local-skill go", resources, vmRead)).toContain(
      "local skill body",
    );

    // The guest-writable workspace file now points at a host credential.
    const hostFile = join(hostDir, "skills", "local-skill", "SKILL.md");
    rmSync(hostFile);
    symlinkSync(join(fakeAgentDir, "auth.json"), hostFile);
    const expanded = expandSkillCommand("/skill:local-skill go", resources, vmRead);
    await expect(expanded).rejects.toThrow();
    await expanded.catch((error: unknown) => {
      expect(String(error)).not.toContain("sk-ant-FAKE-TEST-KEY");
    });
  });

  // ─── Credential isolation: agentDir is NOT mounted ───

  it("SAFE: credential file is NOT accessible (agentDir not mounted)", async () => {
    if (!qemuAvailable) return;

    // After fix: only extensions/ subdir is mounted, not the whole agentDir.
    // auth.json should not be reachable.
    const result = await vm.exec(`cat ${fakeAgentDir}/auth.json 2>&1 || true`);

    expect(result.stdout).toContain("No such file");
    expect(result.stdout).not.toContain("sk-ant-FAKE-TEST-KEY");
  });

  it("skill files are readable via skillPaths mount (intended)", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${fakeAgentDir}/skills/test-skill.md`);
    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("# Test Skill");
  });

  it("extensions subdir is readable via readonlyMount (intended)", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`cat ${fakeAgentDir}/extensions/test-ext.js`);
    expect(result.ok).toBe(true);
    expect(result.stdout).toContain("test extension");
  });

  // ─── Attack Vector 3: Can the VM see the REAL ~/.pi/agent? ───

  it("SAFE: real host ~/.pi/agent is not accessible", async () => {
    if (!qemuAvailable) return;

    const realAgentDir = join(homedir(), ".pi", "agent");
    const result = await vm.exec(`cat ${realAgentDir}/auth.json 2>&1 || true`);

    expect(result.stdout).toContain("No such file");
    expect(result.stdout).not.toContain("api_key");
  });

  it("SAFE: agentDir root is not listable (only subdirs mounted)", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`ls ${fakeAgentDir}/ 2>&1 || true`);

    // The parent dir itself is not mounted — only skills/ and extensions/ are.
    // ls of the parent should fail or show only the mounted subdirs.
    expect(result.stdout).not.toContain("auth.json");
  });

  // ─── Attack Vector 5: Env var leakage ───

  it("SAFE: host env is not forwarded into the VM", async () => {
    if (!qemuAvailable) return;

    const ops = createGondolinBashOps(vm, hostDir);
    const chunks: Buffer[] = [];
    await ops.exec("env", hostDir, {
      onData: (d) => chunks.push(d),
      env: {
        ANTHROPIC_API_KEY: "sk-ant-real-key-12345",
        HOME: "/Users/testuser",
        USER: "testuser",
        SECRET_TOKEN: "super-secret",
        SAFE_VAR: "this-is-fine",
      } as unknown as NodeJS.ProcessEnv,
    });
    const env = Buffer.concat(chunks).toString();

    // Per-command host env is ignored. Workspace-level sandbox env is injected
    // at VM creation time through GondolinManager instead.
    expect(env).not.toContain("HOME=/Users/testuser");
    expect(env).not.toContain("USER=testuser");
    expect(env).not.toContain("ANTHROPIC_API_KEY=sk-ant-real-key-12345");
    expect(env).not.toContain("SECRET_TOKEN=super-secret");
    expect(env).not.toContain("SAFE_VAR=this-is-fine");
  });

  it("SAFE: arbitrary host env var names are not forwarded", async () => {
    if (!qemuAvailable) return;

    // Pi's bash tool supplies the host shell environment to BashOperations by
    // default. The Gondolin implementation must ignore it unless a value was
    // deliberately injected at VM creation time.
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

    expect(env).not.toContain("custom-value");
    expect(env).not.toContain("another-value");
  });

  // ─── Attack Vector 6: Network egress ───

  it("SAFE: network egress is blocked when allowedHosts is empty", async () => {
    if (!qemuAvailable) return;

    // Use a stable hostname, but assert on the sandbox block itself rather than
    // a successful upstream response so the test stays deterministic offline.
    const result = await vm.exec(
      `curl -sv --max-time 5 https://example.com/ -o /dev/null 2>&1 || true`,
    );

    expect(result.stdout).toMatch(/blocked by policy|Could not resolve host|Forbidden/i);
    expect(result.stdout).not.toContain("HTTP/1.1 200 OK");
    expect(result.stdout).not.toContain("HTTP/2 200");
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
