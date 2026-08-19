import { describe, it, expect, vi } from "vitest";
import {
  toGuestPath,
  toHostPath,
  GUEST_WORKSPACE,
  createSandboxLsOps,
  createGondolinBashOps,
  createGondolinReadOps,
  createGondolinWriteOps,
  createGondolinEditOps,
  createGondolinFindOps,
  createSandboxGrepToolDefinition,
  type GondolinVm,
  type GondolinProcess,
  type GondolinExecResult,
} from "../src/gondolin-ops.js";

// ─── toGuestPath ───

describe("toGuestPath", () => {
  const cwd = "/Users/alice/workspace/myproject";

  it("maps a file at workspace root", () => {
    expect(toGuestPath(cwd, `${cwd}/README.md`)).toBe("/workspace/README.md");
  });

  it("maps a nested file", () => {
    expect(toGuestPath(cwd, `${cwd}/src/index.ts`)).toBe("/workspace/src/index.ts");
  });

  it("maps the workspace root itself", () => {
    expect(toGuestPath(cwd, cwd)).toBe("/workspace");
  });

  it("rejects paths outside workspace", () => {
    expect(() => toGuestPath(cwd, "/etc/passwd")).toThrow(/outside the sandbox workspace/);
  });

  it("rejects parent-escaping paths", () => {
    expect(() => toGuestPath(cwd, "/Users/alice/other/file.txt")).toThrow(
      /outside the sandbox workspace/,
    );
  });

  it("handles trailing slashes in cwd", () => {
    // resolve() normalizes trailing slashes
    expect(toGuestPath(`${cwd}/`, `${cwd}/file.txt`)).toBe("/workspace/file.txt");
  });

  it("uses forward slashes in guest paths", () => {
    const result = toGuestPath(cwd, `${cwd}/deep/nested/path/file.ts`);
    expect(result).toBe("/workspace/deep/nested/path/file.ts");
    expect(result).not.toContain("\\");
  });

  it("can map into a named sandbox workspace root", () => {
    expect(toGuestPath(cwd, `${cwd}/README.md`, "/workspace/myproject")).toBe(
      "/workspace/myproject/README.md",
    );
    expect(toGuestPath(cwd, cwd, "/workspace/myproject")).toBe("/workspace/myproject");
  });
});

describe("GUEST_WORKSPACE", () => {
  it("is /workspace", () => {
    expect(GUEST_WORKSPACE).toBe("/workspace");
  });
});

describe("toHostPath", () => {
  const hostCwd = "/Users/alice/workspace/myproject";
  const guestCwd = "/workspace/myproject";

  it("maps the guest workspace root to the host mount", () => {
    expect(toHostPath(guestCwd, hostCwd, guestCwd)).toBe(hostCwd);
  });

  it("maps a nested guest path onto the host mount", () => {
    expect(toHostPath(`${guestCwd}/notes/packet.md`, hostCwd, guestCwd)).toBe(
      `${hostCwd}/notes/packet.md`,
    );
  });

  it("rejects host-absolute paths that are not guest-mapped", () => {
    expect(() => toHostPath(`${hostCwd}/notes/packet.md`, hostCwd, guestCwd)).toThrow(
      /outside the sandbox workspace/,
    );
  });

  it("rejects paths outside both roots", () => {
    expect(() => toHostPath("/etc/passwd", hostCwd, guestCwd)).toThrow(
      /outside the sandbox workspace/,
    );
  });

  it("does not treat a sibling guest slug as inside the workspace", () => {
    expect(() => toHostPath("/workspace/myproject-other/file", hostCwd, guestCwd)).toThrow(
      /outside the sandbox workspace/,
    );
  });
});

describe("createSandboxLsOps", () => {
  const guestCwd = "/workspace/box";
  const shadow = (posixPath: string) =>
    posixPath.endsWith("/.env") || posixPath === "/.env" || posixPath.split("/").includes(".ssh");

  it("lists through vm.fs, hides shadowed names, and rejects paths outside the workspace", async () => {
    const listDir = vi.fn(async () => ["packet.md", ".env", ".ssh"]);
    const access = vi.fn(async (path: string) => {
      if (path.endsWith("/.env") || path.endsWith("/.ssh")) throw new Error("ENOENT");
    });
    const stat = vi.fn(async () => ({ isDirectory: () => true }));
    const vm = createMockVm(undefined, { listDir, access, stat });
    const ops = createSandboxLsOps(vm, guestCwd, guestCwd, { shouldShadow: shadow });

    expect(await ops.readdir(guestCwd)).toEqual(["packet.md"]);
    expect(await ops.exists(`${guestCwd}/.env`)).toBe(false);
    expect(await ops.exists(`${guestCwd}/packet.md`)).toBe(true);
    await expect(ops.stat("/etc/passwd")).rejects.toThrow(/outside the sandbox workspace/);
    await expect(ops.stat(`${guestCwd}/../../../etc/passwd`)).rejects.toThrow(
      /outside the sandbox workspace/,
    );
    expect(listDir).toHaveBeenCalledWith(guestCwd);
    expect(vm.exec).not.toHaveBeenCalled();
  });
});

// ─── Mock VM ───

function createMockProcess(
  overrides: {
    exitCode?: number;
    stdout?: string;
    stderr?: string;
    chunks?: Array<{ stream: "stdout" | "stderr"; data: string }>;
  } = {},
): GondolinProcess {
  const { exitCode = 0, stdout = "", chunks } = overrides;
  const stdoutBuf = Buffer.from(stdout);
  const result: GondolinExecResult = {
    exitCode,
    stdout,
    stdoutBuffer: stdoutBuf,
    ok: exitCode === 0,
  };

  const proc: GondolinProcess = {
    then(onfulfilled, onrejected) {
      return Promise.resolve(result).then(onfulfilled, onrejected);
    },
    output() {
      const items = chunks ?? [{ stream: "stdout" as const, data: stdout }];
      return {
        async *[Symbol.asyncIterator]() {
          for (const item of items) {
            yield { stream: item.stream, data: Buffer.from(item.data) };
          }
        },
      };
    },
  };
  return proc;
}

function createMockVm(
  execImpl?: (args: string[] | string, options?: Record<string, unknown>) => GondolinProcess,
  fsOverrides: Partial<GondolinVm["fs"]> = {},
): GondolinVm {
  return {
    fs: {
      access: vi.fn(async () => undefined),
      mkdir: vi.fn(async () => undefined),
      listDir: vi.fn(async () => []),
      stat: vi.fn(async () => ({ isDirectory: () => false, isFile: () => true })),
      readFile: vi.fn(async () => Buffer.from("")),
      writeFile: vi.fn(async () => undefined),
      ...fsOverrides,
    },
    exec: vi.fn(execImpl ?? (() => createMockProcess())),
  };
}

// ─── BashOperations ───

describe("createGondolinBashOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("passes command to bash -lc inside VM", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess({ stdout: "hello\n" });
    });

    const ops = createGondolinBashOps(vm, localCwd);
    const chunks: Buffer[] = [];
    await ops.exec("echo hello", localCwd, {
      onData: (d) => chunks.push(d),
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].args).toEqual(["/bin/bash", "-lc", "echo hello"]);
    expect(calls[0].options).toMatchObject({
      cwd: "/workspace",
      stdout: "pipe",
      stderr: "pipe",
    });
  });

  it("maps cwd into guest path", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess();
    });

    const ops = createGondolinBashOps(vm, localCwd);
    await ops.exec("ls", `${localCwd}/src`, { onData: () => {} });

    expect(calls[0].options).toMatchObject({ cwd: "/workspace/src" });
  });

  it("starts in the named guest workspace when the session cwd is virtual", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess();
    });

    const guestCwd = "/workspace/myproject";
    const ops = createGondolinBashOps(vm, guestCwd, guestCwd);
    await ops.exec("pwd", guestCwd, { onData: () => {} });

    expect(calls[0].options).toMatchObject({ cwd: guestCwd });
  });

  it("streams output chunks via onData", async () => {
    const vm = createMockVm(() =>
      createMockProcess({
        chunks: [
          { stream: "stdout", data: "line1\n" },
          { stream: "stderr", data: "warn\n" },
          { stream: "stdout", data: "line2\n" },
        ],
      }),
    );

    const ops = createGondolinBashOps(vm, localCwd);
    const chunks: Buffer[] = [];
    await ops.exec("cmd", localCwd, { onData: (d) => chunks.push(d) });

    expect(chunks).toHaveLength(3);
    expect(chunks[0].toString()).toBe("line1\n");
    expect(chunks[1].toString()).toBe("warn\n");
    expect(chunks[2].toString()).toBe("line2\n");
  });

  it("returns exit code", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 42 }));
    const ops = createGondolinBashOps(vm, localCwd);
    const result = await ops.exec("false", localCwd, { onData: () => {} });
    expect(result.exitCode).toBe(42);
  });

  it("forwards only allowlisted Pi session metadata", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess();
    });

    const ops = createGondolinBashOps(vm, localCwd);
    await ops.exec("env", localCwd, {
      onData: () => {},
      env: {
        PI_PROVIDER: "anthropic",
        PI_MODEL: "claude-sonnet-4-5",
        PI_REASONING_LEVEL: "high",
        PI_SESSION_ID: "session-123",
        PI_SESSION_FILE: "/tmp/session.jsonl",
        FOO: "bar",
        ANTHROPIC_API_KEY: "secret",
        EMPTY: "",
      } as NodeJS.ProcessEnv,
    });

    expect(calls[0].options.env).toEqual({
      PI_PROVIDER: "anthropic",
      PI_MODEL: "claude-sonnet-4-5",
      PI_REASONING_LEVEL: "high",
      PI_SESSION_ID: "session-123",
    });
  });

  it("does not forward host environment variables when no Pi metadata is present", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess();
    });

    const ops = createGondolinBashOps(vm, localCwd);
    await ops.exec("env", localCwd, {
      onData: () => {},
      env: { FOO: "bar", ANTHROPIC_API_KEY: "secret", BAZ: undefined } as NodeJS.ProcessEnv,
    });

    expect(calls[0].options.env).toBeUndefined();
  });
});

// ─── ReadOperations ───

describe("createGondolinReadOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("reads file via Gondolin fs and returns buffer", async () => {
    const readFile = vi.fn(async () => Buffer.from("const x = 1;"));
    const vm = createMockVm(undefined, { readFile });

    const ops = createGondolinReadOps(vm, localCwd);
    const buf = await ops.readFile(`${localCwd}/src/index.ts`);
    expect(readFile).toHaveBeenCalledWith("/workspace/src/index.ts");
    expect(buf.toString()).toBe("const x = 1;");
  });

  it("rejects file reads outside the workspace", async () => {
    const vm = createMockVm();
    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.readFile("/etc/passwd")).rejects.toThrow(/outside the sandbox workspace/);
  });

  it("throws on read failure", async () => {
    const vm = createMockVm(undefined, {
      readFile: vi.fn(async () => {
        throw new Error("No such file");
      }),
    });
    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.readFile(`${localCwd}/nope.txt`)).rejects.toThrow(/Failed to read/);
  });

  it("checks access via Gondolin fs", async () => {
    const access = vi.fn(async () => undefined);
    const vm = createMockVm(undefined, { access });

    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/file.txt`)).resolves.toBeUndefined();
    expect(access).toHaveBeenCalledWith("/workspace/file.txt");
  });

  it("throws on access failure", async () => {
    const vm = createMockVm(undefined, {
      access: vi.fn(async () => {
        throw new Error("missing");
      }),
    });
    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/nope`)).rejects.toThrow(/ENOENT/);
  });

  it("detects image mime types from extension", async () => {
    const vm = createMockVm();
    const ops = createGondolinReadOps(vm, localCwd);
    const mime = await ops.detectImageMimeType!(`${localCwd}/photo.png`);
    expect(mime).toBe("image/png");
  });

  it("returns null for non-image mime types", async () => {
    const vm = createMockVm();
    const ops = createGondolinReadOps(vm, localCwd);
    const mime = await ops.detectImageMimeType!(`${localCwd}/file.txt`);
    expect(mime).toBeNull();
  });
});

// ─── WriteOperations ───

describe("createGondolinWriteOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("writes file via Gondolin fs", async () => {
    const mkdir = vi.fn(async () => undefined);
    const writeFile = vi.fn(async () => undefined);
    const vm = createMockVm(undefined, { mkdir, writeFile });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/out.txt`, "hello world");

    expect(mkdir).toHaveBeenCalledWith("/workspace", { recursive: true });
    expect(writeFile).toHaveBeenCalledWith("/workspace/out.txt", "hello world", {
      encoding: "utf8",
    });
  });

  it("creates parent directories", async () => {
    const mkdir = vi.fn(async () => undefined);
    const vm = createMockVm(undefined, { mkdir });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/deep/nested/file.txt`, "x");

    expect(mkdir).toHaveBeenCalledWith("/workspace/deep/nested", { recursive: true });
  });

  it("throws on write failure", async () => {
    const vm = createMockVm(undefined, {
      writeFile: vi.fn(async () => {
        throw new Error("disk full");
      }),
    });
    const ops = createGondolinWriteOps(vm, localCwd);
    await expect(ops.writeFile(`${localCwd}/out.txt`, "data")).rejects.toThrow(/Failed to write/);
  });

  it("creates directory via Gondolin fs", async () => {
    const mkdir = vi.fn(async () => undefined);
    const vm = createMockVm(undefined, { mkdir });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.mkdir(`${localCwd}/new/dir`);

    expect(mkdir).toHaveBeenCalledWith("/workspace/new/dir", { recursive: true });
  });

  it("throws on mkdir failure", async () => {
    const vm = createMockVm(undefined, {
      mkdir: vi.fn(async () => {
        throw new Error("permission denied");
      }),
    });
    const ops = createGondolinWriteOps(vm, localCwd);
    await expect(ops.mkdir(`${localCwd}/nope`)).rejects.toThrow(/Failed to mkdir/);
  });
});

// ─── EditOperations ───

describe("createGondolinEditOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("composes readFile from read ops", async () => {
    const vm = createMockVm(undefined, {
      readFile: vi.fn(async () => Buffer.from("original content")),
    });
    const ops = createGondolinEditOps(vm, localCwd);
    const buf = await ops.readFile(`${localCwd}/file.ts`);
    expect(buf.toString()).toBe("original content");
  });

  it("composes writeFile from write ops", async () => {
    const writeFile = vi.fn(async () => undefined);
    const vm = createMockVm(undefined, { writeFile });

    const ops = createGondolinEditOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/file.ts`, "new content");

    expect(writeFile).toHaveBeenCalledWith("/workspace/file.ts", "new content", {
      encoding: "utf8",
    });
  });

  it("composes access from read ops", async () => {
    const vm = createMockVm();

    const ops = createGondolinEditOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/file.ts`)).resolves.toBeUndefined();
  });
});

// ─── FindOperations ───

describe("createGondolinFindOps", () => {
  const guestCwd = "/workspace/myproject";

  it("runs Alpine find through vm.exec, not host fd", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess({ stdout: "/workspace/myproject/notes.md\n" });
    });
    const ops = createGondolinFindOps(vm, guestCwd, guestCwd);
    expect(await ops.exists(guestCwd)).toBe(true);
    const results = await ops.glob("*.md", guestCwd, {
      ignore: ["**/node_modules/**", "**/.git/**"],
      limit: 100,
    });
    expect(results).toEqual(["/workspace/myproject/notes.md"]);
    expect(calls).toHaveLength(1);
    expect(calls[0].args[0]).toBe("/usr/bin/find");
    expect(calls[0].args[0]).toMatch(/^\//);
    expect(calls[0].args).toContain("-name");
    expect(calls[0].args).toContain("*.md");
    expect(calls[0].args).not.toContain("fd");
  });

  it("rejects find paths outside the workspace mount", async () => {
    const vm = createMockVm();
    const ops = createGondolinFindOps(vm, guestCwd, guestCwd);
    expect(await ops.exists("/etc/passwd")).toBe(false);
    expect(await ops.exists("~/.pi/agent/auth.json")).toBe(false);
    await expect(
      ops.glob("*", "/Users/alice/.pi/agent", { ignore: [], limit: 10 }),
    ).rejects.toThrow(/outside the sandbox workspace/);
    expect(vm.exec).not.toHaveBeenCalled();
  });
});

// ─── Guest grep ───

describe("createSandboxGrepToolDefinition", () => {
  const guestCwd = "/workspace/myproject";

  function toolText(result: { content: Array<{ type?: string; text?: string }> }): string {
    return result.content.map((part) => ("text" in part ? (part.text ?? "") : "")).join("\n");
  }

  it("prefers guest rg when command -v rg succeeds", async () => {
    const calls: string[][] = [];
    const vm = createMockVm((args) => {
      const argv = Array.isArray(args) ? args : [args];
      calls.push(argv);
      if (argv.join(" ").includes("command -v rg")) {
        return createMockProcess({ stdout: "/usr/bin/rg\n" });
      }
      return createMockProcess({ stdout: "notes.md:1: guest-workspace-hit\n" });
    });
    const grep = createSandboxGrepToolDefinition(vm, guestCwd, guestCwd);
    expect(grep.name).toBe("grep");
    const result = await grep.execute(
      "g1",
      { pattern: "guest-workspace-hit", path: guestCwd },
      undefined,
      undefined,
      {} as never,
    );
    expect(toolText(result)).toContain("guest-workspace-hit");
    expect(calls[0]?.join(" ")).toContain("command -v rg");
    expect(calls[1]?.[0]).toBe("/usr/bin/rg");
    expect(calls.some((argv) => argv[0] === "grep")).toBe(false);
  });

  it("falls back to guest grep when rg is missing", async () => {
    const calls: string[][] = [];
    const vm = createMockVm((args) => {
      const argv = Array.isArray(args) ? args : [args];
      calls.push(argv);
      if (argv.join(" ").includes("command -v rg")) {
        return createMockProcess({ exitCode: 1 });
      }
      return createMockProcess({ stdout: "notes.md:1: guest-workspace-hit\n" });
    });
    const grep = createSandboxGrepToolDefinition(vm, guestCwd, guestCwd);
    const result = await grep.execute(
      "g1",
      { pattern: "guest-workspace-hit" },
      undefined,
      undefined,
      {} as never,
    );
    expect(toolText(result)).toContain("guest-workspace-hit");
    expect(calls[1]?.[0]).toBe("/bin/grep");
    expect(calls[1]?.[0]).toMatch(/^\//);
  });

  it("uses absolute guest binaries for find and grep argv[0]", async () => {
    const findCalls: string[][] = [];
    const findVm = createMockVm((args) => {
      findCalls.push(Array.isArray(args) ? args : [args]);
      return createMockProcess({ stdout: "notes.md\n" });
    });
    await createGondolinFindOps(findVm, guestCwd, guestCwd).glob("*.md", guestCwd, {
      ignore: [],
      limit: 10,
    });
    expect(findCalls[0]?.[0]).toMatch(/^\//);
    expect(findCalls[0]?.[0]).toBe("/usr/bin/find");

    const grepCalls: string[][] = [];
    const grepVm = createMockVm((args) => {
      const argv = Array.isArray(args) ? args : [args];
      grepCalls.push(argv);
      if (argv.join(" ").includes("command -v rg")) {
        return createMockProcess({ exitCode: 1 });
      }
      return createMockProcess({ stdout: "notes.md:1: hit\n" });
    });
    await createSandboxGrepToolDefinition(grepVm, guestCwd, guestCwd).execute(
      "g1",
      { pattern: "hit" },
      undefined,
      undefined,
      {} as never,
    );
    const grepArgv = grepCalls.find((argv) => argv[0] !== "/bin/sh");
    expect(grepArgv?.[0]).toMatch(/^\//);
    expect(grepArgv?.[0]).toBe("/bin/grep");
  });

  it("rejects ~ and .. paths that would escape to the host", async () => {
    const vm = createMockVm();
    const grep = createSandboxGrepToolDefinition(vm, guestCwd, guestCwd);
    await expect(
      grep.execute(
        "g1",
        { pattern: ".", path: "~/.pi/agent/auth.json" },
        undefined,
        undefined,
        {} as never,
      ),
    ).rejects.toThrow(/outside the sandbox workspace/);
    await expect(
      grep.execute(
        "g1",
        { pattern: ".", path: "/Users/alice/secret.txt" },
        undefined,
        undefined,
        {} as never,
      ),
    ).rejects.toThrow(/outside the sandbox workspace/);
    await expect(
      grep.execute(
        "g1",
        { pattern: ".", path: "../../../../etc/passwd" },
        undefined,
        undefined,
        {} as never,
      ),
    ).rejects.toThrow(/outside the sandbox workspace/);
    expect(vm.exec).not.toHaveBeenCalled();
  });
});
