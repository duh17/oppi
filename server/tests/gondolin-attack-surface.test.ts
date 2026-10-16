/**
 * Gondolin sandbox attack surface tests.
 *
 * Boots a real QEMU VM through GondolinManager, which mounts the workspace's
 * `.pi/skills` entries read-only, and probes for the lethal trifecta:
 *   1. Can the VM read auth.json? → NO (only subdirs mounted, not agentDir root)
 *   2. Can the VM write to readonlyMounts? → NO (ReadonlyProvider blocks)
 *   3. Can the VM read host paths outside of mounts? → NO (VFS boundary)
 *   4. Env var leakage? → per-command host env is not forwarded into the VM
 *   5. Network egress with empty allowedHosts? → NO (deny-all)
 *
 * Requires QEMU installed. Skipped automatically if not available.
 */
import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
  closeSync,
  ftruncateSync,
  mkdtempSync,
  openSync,
  rmSync,
  writeFileSync,
  mkdirSync,
  symlinkSync,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { isQemuAvailable, GondolinManager } from "../src/gondolin-manager.js";
import type { GondolinVm } from "../src/gondolin-ops.js";
import { createGondolinBashOps } from "../src/gondolin-ops.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import {
  expandSkillCommand,
  loadDurableProjectResources,
  renderSkills,
  type DurableProjectResources,
} from "../src/durable-project-resources.js";
import type { Workspace } from "../src/types.js";

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
  let outsideSkillDir: string;
  const SECRET_SKILL_GUEST = "/workspace/.pi/skills/secret-skill";
  const LOCAL_SKILL_GUEST = "/workspace/.pi/skills/local-skill";
  const workspace: Workspace = {
    id: "attack-test",
    name: "Attack Surface Test",
    runtime: "sandbox",
    sandboxConfig: { allowedHosts: [] }, // no network
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  let manager: GondolinManager;
  let vm: GondolinVm;
  const vmRead = async (path: string) => Buffer.from(await vm.fs.readFile(path)).toString("utf8");
  /** One durable sandbox session's resources, discovered through its own env on the VM. */
  const sessionResources = async (resources?: { skillPaths?: string[] }) => {
    const sessionVm = await manager.ensureWorkspaceVm(workspace, hostDir);
    return loadDurableProjectResources({
      hostCwd: hostDir,
      agentDir: fakeAgentDir,
      sandbox: new GondolinExecutionEnv(sessionVm, workspace.id, "/workspace"),
      projectTrusted: true,
      ...(resources ? { resources } : {}),
    });
  };

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

    // The owner's `.pi/skills`, which the manager mounts at boot: a Skill directory outside
    // the workspace holding secret-bearing names (`.pi/skills/foo -> ~/elsewhere`, as real
    // setups link shared Skills), and a Skill inside the workspace that the guest may later
    // retarget (`/skill:` reads through the VM).
    secretSkillDir = mkdtempSync(join(tmpdir(), "gondolin-secret-skill-"));
    writeFileSync(
      join(secretSkillDir, "SKILL.md"),
      "---\nname: secret-skill\ndescription: Linked owner Skill.\n---\nsecret skill body",
    );
    writeFileSync(join(secretSkillDir, ".env"), "SKILL_ENV_SECRET=1");
    writeFileSync(join(secretSkillDir, "signing.pem"), "PEM-SKILL-SECRET");
    mkdirSync(join(hostDir, ".pi", "skills", "local-skill"), { recursive: true });
    symlinkSync(secretSkillDir, join(hostDir, ".pi", "skills", "secret-skill"));
    writeFileSync(
      join(hostDir, ".pi", "skills", "local-skill", "SKILL.md"),
      "---\nname: local-skill\ndescription: Workspace owner Skill.\n---\nlocal skill body",
    );

    // Guest-writable `.agents/skills`: one real Skill, and links out of the workspace and to
    // a shadowed file. The `.env` is written as a Skill so a read of it would present it.
    outsideSkillDir = mkdtempSync(join(tmpdir(), "gondolin-outside-skill-"));
    writeFileSync(
      join(outsideSkillDir, "SKILL.md"),
      "---\nname: outside-skill\ndescription: OUTSIDE_SKILL_SECRET\n---\nOUTSIDE_SKILL_SECRET",
    );
    writeFileSync(
      join(hostDir, ".env"),
      "---\nname: env-skill\ndescription: WORKSPACE_ENV_SECRET\n---\nWORKSPACE_ENV_SECRET=1",
    );
    const agentsSkills = join(hostDir, ".agents", "skills");
    mkdirSync(join(agentsSkills, "env-skill"), { recursive: true });
    mkdirSync(join(agentsSkills, "ok"), { recursive: true });
    writeFileSync(
      join(agentsSkills, "ok", "SKILL.md"),
      "---\nname: ok-skill\ndescription: Guest workspace Skill.\n---\nok body",
    );
    symlinkSync(outsideSkillDir, join(agentsSkills, "x"));
    symlinkSync("../../.env", join(agentsSkills, "y.md"));
    symlinkSync("../../../.env", join(agentsSkills, "env-skill", "SKILL.md"));
    // A cycle the walk must not follow forever.
    symlinkSync(".", join(agentsSkills, "loop"));
    symlinkSync(".", join(agentsSkills, "loop2"));

    vm = await manager.ensureWorkspaceVm(workspace, hostDir);
  }, 90_000);

  afterAll(async () => {
    if (manager) await manager.stopAll();
    if (hostDir) rmSync(hostDir, { recursive: true, force: true });
    if (fakeAgentDir) rmSync(fakeAgentDir, { recursive: true, force: true });
    if (secretSkillDir) rmSync(secretSkillDir, { recursive: true, force: true });
    if (outsideSkillDir) rmSync(outsideSkillDir, { recursive: true, force: true });
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

  // ─── Resource discovery: only through the VM ───

  it("an owner .pi/skills symlink out of the workspace is mounted and readable", async () => {
    if (!qemuAvailable) return;

    const cat = await vm.exec(`cat ${SECRET_SKILL_GUEST}/SKILL.md`);
    expect(cat.ok).toBe(true);
    expect(cat.stdout).toContain("secret skill body");
    const resources = await sessionResources();
    expect(resources.skills.find((skill) => skill.name === "secret-skill")).toMatchObject({
      filePath: `${SECRET_SKILL_GUEST}/SKILL.md`,
      baseDir: SECRET_SKILL_GUEST,
    });
  });

  it("a second session on the live VM sees its saved Agent's .pi/skills selection", async () => {
    if (!qemuAvailable) return;

    // The first session booted the VM; this one only attaches to it.
    expect(await manager.ensureWorkspaceVm(workspace, hostDir)).toBe(vm);
    const resources = await sessionResources({ skillPaths: [".pi/skills/secret-skill"] });
    expect(resources.skills.map((skill) => skill.name)).toEqual(["secret-skill"]);
    expect(renderSkills(resources.skills, ["read"])).toContain(
      `<location>${SECRET_SKILL_GUEST}/SKILL.md</location>`,
    );
    expect(await expandSkillCommand("/skill:secret-skill go", resources, vmRead)).toContain(
      "secret skill body",
    );
  });

  it("SAFE: guest .agents/skills links out of the workspace or to .env yield no Skill or bytes", async () => {
    if (!qemuAvailable) return;

    const resources = await sessionResources();
    expect(resources.skills.map((skill) => skill.name)).toEqual([
      "local-skill",
      "secret-skill",
      "ok-skill",
    ]);
    const text = JSON.stringify(resources);
    expect(text).not.toContain("OUTSIDE_SKILL_SECRET");
    expect(text).not.toContain("WORKSPACE_ENV_SECRET");
  });

  it("SAFE: a selected Skill outside the workspace fails agent_skills_unavailable", async () => {
    if (!qemuAvailable) return;

    for (const skillPath of [outsideSkillDir, "../outside-skill", ".agents/skills/x"]) {
      await expect(sessionResources({ skillPaths: [skillPath] }), skillPath).rejects.toMatchObject({
        code: "agent_skills_unavailable",
      });
    }
  });

  it("SAFE: a workspace AGENTS.md symlinked to .env reads as missing through the VM", async () => {
    if (!qemuAvailable) return;

    const agents = join(hostDir, "AGENTS.md");
    symlinkSync(".env", agents);
    const refused = await sessionResources();
    expect(refused.contextFiles).toEqual([]);
    expect(JSON.stringify(refused)).not.toContain("WORKSPACE_ENV_SECRET");

    // A real file is the VM's text, redacted like the host loader's.
    rmSync(agents);
    writeFileSync(agents, `Build in ${hostDir}/src.`);
    const read = await sessionResources();
    expect(read.contextFiles).toEqual([
      { path: "/workspace/AGENTS.md", content: "Build in /workspace/src." },
    ]);
    rmSync(agents);
  });

  it("SAFE: an AGENTS.md linked to a 1 GiB sparse workspace file is skipped, quickly", async () => {
    if (!qemuAvailable) return;

    const big = join(hostDir, "big.bin");
    const fd = openSync(big, "w");
    ftruncateSync(fd, 1024 * 1024 * 1024);
    closeSync(fd);
    symlinkSync("big.bin", join(hostDir, "AGENTS.md"));
    const started = Date.now();
    const resources = await sessionResources();
    expect(Date.now() - started).toBeLessThan(5_000);
    expect(resources.contextFiles).toEqual([]);
    rmSync(join(hostDir, "AGENTS.md"));
    rmSync(big);
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
    };
    expect(await expandSkillCommand("/skill:local-skill go", resources, vmRead)).toContain(
      "local skill body",
    );

    // The Skill file now points at a host credential.
    const hostFile = join(hostDir, ".pi", "skills", "local-skill", "SKILL.md");
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

    // Only the workspace and its `.pi/skills` entries are mounted, never the agent dir.
    const result = await vm.exec(`cat ${fakeAgentDir}/auth.json 2>&1 || true`);

    expect(result.stdout).toContain("No such file");
    expect(result.stdout).not.toContain("sk-ant-FAKE-TEST-KEY");
  });

  // ─── Attack Vector 3: Can the VM see the REAL ~/.pi/agent? ───

  it("SAFE: real host ~/.pi/agent is not accessible", async () => {
    if (!qemuAvailable) return;

    const realAgentDir = join(homedir(), ".pi", "agent");
    const result = await vm.exec(`cat ${realAgentDir}/auth.json 2>&1 || true`);

    expect(result.stdout).toContain("No such file");
    expect(result.stdout).not.toContain("api_key");
  });

  it("SAFE: agentDir root is not listable", async () => {
    if (!qemuAvailable) return;

    const result = await vm.exec(`ls ${fakeAgentDir}/ 2>&1 || true`);

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
