import type { ChildProcess } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("node:child_process", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    spawn: vi.fn(),
  };
});

vi.mock("node:fs", async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return {
    ...actual,
    existsSync: vi.fn(),
    mkdirSync: vi.fn(),
    writeFileSync: vi.fn(),
  };
});

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import {
  HOST_MEMORY_EXTENSION,
  HOST_TODOS_EXTENSION,
  OPPI_GATE_EXTENSION,
  spawnPiHost,
  type SpawnDeps,
} from "../src/session-spawn.js";
import { PolicyEngine } from "../src/policy.js";
import {
  awaitProcessReady,
  getSpawnPolicy,
  makeDeps,
  makeSession,
  makeWorkspace,
  StubProcess,
} from "./session-spawn.helpers.js";

const mockedSpawn = vi.mocked(spawn);
const mockedExistsSync = vi.mocked(existsSync);
const mockedMkdirSync = vi.mocked(mkdirSync);
const mockedWriteFileSync = vi.mocked(writeFileSync);

describe("session-spawn spawnPiHost", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("composes spawn args/env for provider/model, extensions, and session resume", async () => {
    const session = makeSession();
    session.model = "openai-codex/gpt-5.3-codex";
    session.piSessionFile = "/tmp/pi-session.jsonl";

    const workspace = makeWorkspace({
      memoryEnabled: true,
      extensions: ["memory", "todos"],
      allowedExecutables: ["node", "npx"],
      allowedPaths: [{ path: "~/.config/dotfiles", access: "read" }],
    });

    const createSessionSocket = vi.fn(async () => 45678);
    const setSessionPolicy = vi.fn();
    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      piExecutable: "/opt/homebrew/bin/pi",
    });

    const expectedCwd = join(homedir(), "workspace", "oppi");
    const existing = new Set<string>([
      expectedCwd,
      OPPI_GATE_EXTENSION,
      HOST_MEMORY_EXTENSION,
      HOST_TODOS_EXTENSION,
      "/tmp/pi-session.jsonl",
    ]);
    mockedExistsSync.mockImplementation((path) =>
      typeof path === "string" && existing.has(path),
    );

    const proc = new StubProcess();
    mockedSpawn.mockReturnValue(proc as unknown as ReturnType<typeof spawn>);

    await awaitProcessReady(spawnPiHost(session, workspace, deps), proc);

    expect(createSessionSocket).toHaveBeenCalledWith("s1", "w1");
    const hostPolicy = getSpawnPolicy(setSessionPolicy, "s1", "host");
    const hostDecision = hostPolicy.evaluate({
      tool: "bash",
      input: { command: "git push origin main" },
      toolCallId: "tc-host",
    });
    expect(hostDecision.action).toBe("ask");

    expect(mockedSpawn).toHaveBeenCalledTimes(1);
    const [command, args, options] = mockedSpawn.mock.calls[0];

    expect(command).toBe("/opt/homebrew/bin/pi");
    expect(args).toEqual([
      "--mode",
      "rpc",
      "--no-extensions",
      "--extension",
      OPPI_GATE_EXTENSION,
      "--extension",
      HOST_MEMORY_EXTENSION,
      "--extension",
      HOST_TODOS_EXTENSION,
      "--provider",
      "openai-codex",
      "--model",
      "gpt-5.3-codex",
      "--session",
      "/tmp/pi-session.jsonl",
    ]);

    const opts = options as {
      cwd: string;
      stdio: [string, string, string];
      env: Record<string, string | undefined>;
    };

    expect(opts.cwd).toBe(expectedCwd);
    expect(opts.stdio).toEqual(["pipe", "pipe", "pipe"]);
    expect(opts.env.OPPI_SESSION).toBe("s1");
        expect(opts.env.OPPI_GATE_HOST).toBe("127.0.0.1");
    expect(opts.env.OPPI_GATE_PORT).toBe("45678");
  });

  it("applies workspace fallback overrides when toggled ask ⇄ allow", async () => {
    const evaluateDefaultAction = async (workspaceFallback: "allow" | "ask") => {
      const session = makeSession();
      const workspace = makeWorkspace({
        memoryEnabled: false,
        policy: { permissions: [], fallback: workspaceFallback },
      });

      const createSessionSocket = vi.fn(async () => 49001);
      const setSessionPolicy = vi.fn();
      const deps = makeDeps({
        gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
        piExecutable: "/opt/homebrew/bin/pi",
        globalPolicy: {
          schemaVersion: 1,
          mode: "host",
          fallback: "ask",
          guardrails: [],
          permissions: [],
        },
      });

      const expectedCwd = join(homedir(), "workspace", "oppi");
      const existing = new Set<string>([expectedCwd, OPPI_GATE_EXTENSION]);
      mockedExistsSync.mockImplementation((path) =>
        typeof path === "string" && existing.has(path),
      );

      const proc = new StubProcess();
      mockedSpawn.mockReturnValue(proc as unknown as ReturnType<typeof spawn>);

      await awaitProcessReady(spawnPiHost(session, workspace, deps), proc);

      expect(setSessionPolicy).toHaveBeenCalledWith("s1", expect.any(PolicyEngine));
      const policy = setSessionPolicy.mock.calls.at(-1)?.[1] as PolicyEngine | undefined;
      if (!policy) throw new Error("Expected setSessionPolicy to receive a policy engine");

      const decision = policy.evaluate({
        tool: "bash",
        input: { command: "echo fallback-check" },
        toolCallId: "tc-fallback",
      });

      return decision.action;
    };

    expect(await evaluateDefaultAction("allow")).toBe("allow");
    expect(await evaluateDefaultAction("ask")).toBe("ask");
    expect(await evaluateDefaultAction("allow")).toBe("allow");
  });

  it("loads named extensions from workspace.extensions", async () => {
    const session = makeSession();
    const workspace = makeWorkspace({
      extensions: ["memory"],
      memoryEnabled: true,
    });

    const createSessionSocket = vi.fn(async () => 45679);
    const setSessionPolicy = vi.fn();
    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      piExecutable: "/opt/homebrew/bin/pi",
    });

    const expectedCwd = join(homedir(), "workspace", "oppi");
    const existing = new Set<string>([
      expectedCwd,
      OPPI_GATE_EXTENSION,
      HOST_MEMORY_EXTENSION,
      HOST_TODOS_EXTENSION,
    ]);
    mockedExistsSync.mockImplementation((path) =>
      typeof path === "string" && existing.has(path),
    );

    const proc = new StubProcess();
    mockedSpawn.mockReturnValue(proc as unknown as ReturnType<typeof spawn>);

    await awaitProcessReady(spawnPiHost(session, workspace, deps), proc);

    const [, args] = mockedSpawn.mock.calls[0];
    expect(args).toContain("--extension");
    expect(args).toContain(HOST_MEMORY_EXTENSION);
    expect(args).not.toContain(HOST_TODOS_EXTENSION);
  });

  it("writes system prompt and appends --append-system-prompt", async () => {
    const session = makeSession();
    session.model = "gpt-5.3-codex";

    const workspace = makeWorkspace({
      systemPrompt: "be strict",
      memoryEnabled: false,
    });

    const createSessionSocket = vi.fn(async () => 40001);
    const setSessionPolicy = vi.fn();
    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      piExecutable: "pi",
    });

    const expectedCwd = join(homedir(), "workspace", "oppi");
    const promptDir = join(homedir(), ".config", "oppi", "prompts");
    const promptPath = join(promptDir, "s1.md");

    const existing = new Set<string>([expectedCwd, OPPI_GATE_EXTENSION]);
    mockedExistsSync.mockImplementation((path) =>
      typeof path === "string" && existing.has(path),
    );

    const proc = new StubProcess();
    mockedSpawn.mockReturnValue(proc as unknown as ReturnType<typeof spawn>);

    await awaitProcessReady(spawnPiHost(session, workspace, deps), proc);

    expect(mockedMkdirSync).toHaveBeenCalledWith(promptDir, { recursive: true });
    expect(mockedWriteFileSync).toHaveBeenCalledWith(promptPath, "be strict");

    const [, args] = mockedSpawn.mock.calls[0];
    expect(args).toContain("--append-system-prompt");
    expect(args).toContain(promptPath);
    expect(args).toContain("--model");
    expect(args).toContain("gpt-5.3-codex");
    expect(args).not.toContain("--provider");
  });

  it("splits nested provider/model correctly (e.g. openrouter/z.ai/glm-5)", async () => {
    const session = makeSession();
    session.model = "openrouter/z.ai/glm-5";

    const workspace = makeWorkspace({ memoryEnabled: false });

    const createSessionSocket = vi.fn(async () => 40010);
    const setSessionPolicy = vi.fn();
    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
      piExecutable: "pi",
    });

    const expectedCwd = join(homedir(), "workspace", "oppi");
    const existing = new Set<string>([expectedCwd, OPPI_GATE_EXTENSION]);
    mockedExistsSync.mockImplementation((path) =>
      typeof path === "string" && existing.has(path),
    );

    const proc = new StubProcess();
    mockedSpawn.mockReturnValue(proc as unknown as ReturnType<typeof spawn>);

    await awaitProcessReady(spawnPiHost(session, workspace, deps), proc);

    const [, args] = mockedSpawn.mock.calls[0];
    expect(args).toContain("--provider");
    expect(args).toContain("openrouter");
    expect(args).toContain("--model");
    expect(args).toContain("z.ai/glm-5");
  });

  it("throws when host workspace cwd does not exist", async () => {
    const session = makeSession();
    const workspace = makeWorkspace({ hostMount: "~/does-not-exist" });

    const createSessionSocket = vi.fn(async () => 40002);
    const setSessionPolicy = vi.fn();
    const deps = makeDeps({
      gate: { createSessionSocket, setSessionPolicy } as unknown as SpawnDeps["gate"],
    });

    mockedExistsSync.mockImplementation((path) => {
      if (path === OPPI_GATE_EXTENSION) return true;
      if (path === HOST_TODOS_EXTENSION) return true;
      return false;
    });

    await expect(spawnPiHost(session, workspace, deps)).rejects.toThrow(
      "Host workspace path not found",
    );
    expect(mockedSpawn).not.toHaveBeenCalled();
  });
});
