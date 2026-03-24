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

  it("passes through paths outside workspace as absolute", () => {
    expect(toGuestPath(cwd, "/etc/passwd")).toBe("/etc/passwd");
  });

  it("passes through parent-escaping paths as absolute", () => {
    expect(toGuestPath(cwd, "/Users/alice/other/file.txt")).toBe("/Users/alice/other/file.txt");
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
});

describe("GUEST_WORKSPACE", () => {
  it("is /workspace", () => {
    expect(GUEST_WORKSPACE).toBe("/workspace");
  });
});

// ─── Mock VM ───

function createMockProcess(overrides: {
  exitCode?: number;
  stdout?: string;
  stderr?: string;
  chunks?: Array<{ stream: "stdout" | "stderr"; data: string }>;
} = {}): GondolinProcess {
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
): GondolinVm {
  return {
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

  it("forwards environment variables", async () => {
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

    // Undefined env values are filtered out (not forwarded to the VM)
    expect(calls[0].options).toMatchObject({
      env: { FOO: "bar" },
    });
    expect(calls[0].options.env).not.toHaveProperty("BAZ");
  });
});

// ─── ReadOperations ───

describe("createGondolinReadOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("reads file via cat and returns buffer", async () => {
    const vm = createMockVm((args) => {
      expect(args).toEqual(["/bin/cat", "/workspace/src/index.ts"]);
      return createMockProcess({ stdout: "const x = 1;" });
    });

    const ops = createGondolinReadOps(vm, localCwd);
    const buf = await ops.readFile(`${localCwd}/src/index.ts`);
    expect(buf.toString()).toBe("const x = 1;");
  });

  it("throws on read failure", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 1, stderr: "No such file" }));
    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.readFile(`${localCwd}/nope.txt`)).rejects.toThrow(/Failed to read/);
  });

  it("checks access via ls -d", async () => {
    const vm = createMockVm((args) => {
      expect(args).toEqual(["/bin/ls", "-d", "/workspace/file.txt"]);
      return createMockProcess({ exitCode: 0 });
    });

    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/file.txt`)).resolves.toBeUndefined();
  });

  it("throws on access failure", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 1 }));
    const ops = createGondolinReadOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/nope`)).rejects.toThrow(/ENOENT/);
  });

  it("detects image mime types", async () => {
    const vm = createMockVm(() => createMockProcess({ stdout: "image/png\n" }));
    const ops = createGondolinReadOps(vm, localCwd);
    const mime = await ops.detectImageMimeType!(`${localCwd}/photo.png`);
    expect(mime).toBe("image/png");
  });

  it("returns null for non-image mime types", async () => {
    const vm = createMockVm(() => createMockProcess({ stdout: "text/plain\n" }));
    const ops = createGondolinReadOps(vm, localCwd);
    const mime = await ops.detectImageMimeType!(`${localCwd}/file.txt`);
    expect(mime).toBeNull();
  });

  it("returns null when file command fails", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 1 }));
    const ops = createGondolinReadOps(vm, localCwd);
    const mime = await ops.detectImageMimeType!(`${localCwd}/missing`);
    expect(mime).toBeNull();
  });
});

// ─── WriteOperations ───

describe("createGondolinWriteOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("writes file via base64 encoding", async () => {
    const calls: Array<{ args: string[] | string }> = [];
    const vm = createMockVm((args) => {
      calls.push({ args });
      return createMockProcess();
    });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/out.txt`, "hello world");

    expect(calls).toHaveLength(1);
    expect(calls[0].args).toEqual(["/bin/bash", "-c", expect.stringContaining("base64")]);
    // Verify the base64 content round-trips correctly
    const cmd = calls[0].args[2] as string;
    const b64Match = cmd.match(/echo '([^']+)'/);
    expect(b64Match).not.toBeNull();
    expect(Buffer.from(b64Match![1], "base64").toString()).toBe("hello world");
  });

  it("creates parent directories", async () => {
    const calls: Array<{ args: string[] | string }> = [];
    const vm = createMockVm((args) => {
      calls.push({ args });
      return createMockProcess();
    });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/deep/nested/file.txt`, "x");

    const cmd = calls[0].args[2] as string;
    expect(cmd).toContain("mkdir -p '/workspace/deep/nested'");
  });

  it("throws on write failure", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 1, stderr: "disk full" }));
    const ops = createGondolinWriteOps(vm, localCwd);
    await expect(ops.writeFile(`${localCwd}/out.txt`, "data")).rejects.toThrow(/Failed to write/);
  });

  it("creates directory via mkdir -p", async () => {
    const calls: Array<{ args: string[] | string }> = [];
    const vm = createMockVm((args) => {
      calls.push({ args });
      return createMockProcess();
    });

    const ops = createGondolinWriteOps(vm, localCwd);
    await ops.mkdir(`${localCwd}/new/dir`);

    expect(calls[0].args).toEqual(["/bin/mkdir", "-p", "/workspace/new/dir"]);
  });

  it("throws on mkdir failure", async () => {
    const vm = createMockVm(() => createMockProcess({ exitCode: 1, stderr: "permission denied" }));
    const ops = createGondolinWriteOps(vm, localCwd);
    await expect(ops.mkdir(`${localCwd}/nope`)).rejects.toThrow(/Failed to mkdir/);
  });
});

// ─── EditOperations ───

describe("createGondolinEditOps", () => {
  const localCwd = "/Users/alice/workspace/myproject";

  it("composes readFile from read ops", async () => {
    const vm = createMockVm(() => createMockProcess({ stdout: "original content" }));
    const ops = createGondolinEditOps(vm, localCwd);
    const buf = await ops.readFile(`${localCwd}/file.ts`);
    expect(buf.toString()).toBe("original content");
  });

  it("composes writeFile from write ops", async () => {
    const calls: Array<{ args: string[] | string }> = [];
    const vm = createMockVm((args) => {
      calls.push({ args });
      return createMockProcess();
    });

    const ops = createGondolinEditOps(vm, localCwd);
    await ops.writeFile(`${localCwd}/file.ts`, "new content");

    expect(calls).toHaveLength(1);
    const cmd = calls[0].args[2] as string;
    expect(cmd).toContain("base64");
  });

  it("composes access from read ops", async () => {
    const vm = createMockVm((args) => {
      if (Array.isArray(args) && args[0] === "/bin/test") {
        return createMockProcess({ exitCode: 0 });
      }
      return createMockProcess();
    });

    const ops = createGondolinEditOps(vm, localCwd);
    await expect(ops.access(`${localCwd}/file.ts`)).resolves.toBeUndefined();
  });
});
