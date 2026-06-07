import { describe, it, expect, vi } from "vitest";
import {
  toGuestPath,
  GUEST_WORKSPACE,
  createGondolinBashOps,
  createGondolinReadOps,
  createGondolinWriteOps,
  createGondolinEditOps,
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

// ─── Mock VM ───

function createMockProcess(
  overrides: {
    exitCode?: number;
    stdout?: string;
    stderr?: string;
    chunks?: Array<{ stream: "stdout" | "stderr"; data: string }>;
  } = {},
): GondolinProcess {
  const { exitCode = 0, stdout = "", stderr = "", chunks } = overrides;
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
      readFile: vi.fn(async () => Buffer.from("")),
      writeFile: vi.fn(async () => undefined),
      ...fsOverrides,
    },
    exec: execImpl ?? (() => createMockProcess()),
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

  it("does not forward host environment variables", async () => {
    const calls: Array<{ args: string[] | string; options: Record<string, unknown> }> = [];
    const vm = createMockVm((args, options) => {
      calls.push({ args, options: options ?? {} });
      return createMockProcess();
    });

    const ops = createGondolinBashOps(vm, localCwd);
    await ops.exec("env", localCwd, {
      onData: () => {},
      env: { FOO: "bar", BAZ: undefined } as unknown as NodeJS.ProcessEnv,
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
