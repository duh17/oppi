import { describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context, withAbortSignal } from "@earendil-works/chord/context";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import type { GondolinVm } from "../src/gondolin-ops.js";

function fixture() {
  const files = new Map<string, Buffer>();
  const vm: GondolinVm = {
    fs: {
      access: vi.fn(async (path) => {
        if (!files.has(path)) throw new Error("ENOENT");
      }),
      mkdir: vi.fn(async () => {}),
      readFile: vi.fn(async (path) => {
        const bytes = files.get(path);
        if (!bytes) throw new Error("ENOENT");
        return bytes;
      }),
      writeFile: vi.fn(async (path, content) => {
        files.set(path, Buffer.from(content));
      }),
      rename: vi.fn(async (source, destination) => {
        files.set(destination, files.get(source)!);
        files.delete(source);
      }),
      deleteFile: vi.fn(async (path) => {
        files.delete(path);
      }),
      stat: vi.fn(async (path) => {
        if (!files.has(path)) throw new Error("ENOENT");
        return {
          isFile: () => true,
          isDirectory: () => false,
          size: files.get(path)!.length,
          mtimeMs: 42,
        };
      }),
    },
    exec: vi.fn(() => {
      throw new Error("Unexpected exec");
    }),
  };
  return { vm, env: new GondolinExecutionEnv(vm, "w1", "/workspace/project"), files };
}

describe("Durable sandbox file capability", () => {
  it.each([
    "../outside",
    "/etc/passwd",
    "/workspace/other/secret",
    "/Users/owner/project/file",
    "~/secret",
    "/workspace/project/../../etc/passwd",
  ])("rejects %s without VM filesystem access", async (path) => {
    const { vm, env } = fixture();
    for (const result of [
      await env.absolutePath(path, context),
      await env.readBinaryFile(path, context),
      await env.writeFile(path, "secret", context),
      await env.fileInfo(path, context),
      await env.createDir(path, undefined, context),
      await env.remove(path, undefined, context),
    ]) {
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.error.code).toBe("permission_denied");
    }
    expect(vm.fs.readFile).not.toHaveBeenCalled();
    expect(vm.fs.writeFile).not.toHaveBeenCalled();
    expect(vm.fs.mkdir).not.toHaveBeenCalled();
    expect(vm.fs.stat).not.toHaveBeenCalled();
    expect(vm.fs.deleteFile).not.toHaveBeenCalled();
  });

  it("preserves bytes, line terminators, typed missing errors and jailed rename destinations", async () => {
    const { env, files, vm } = fixture();
    expect(await env.writeFile("note.txt", "one\r\ntwo\nthree", context)).toEqual({
      ok: true,
      value: undefined,
    });
    expect(files.get("/workspace/project/note.txt")?.toString()).toBe("one\r\ntwo\nthree");
    const opened = await env.openTextLineReader("note.txt", context);
    expect(opened.ok).toBe(true);
    if (!opened.ok) throw opened.error;
    expect(await opened.value.readLine(context)).toEqual({
      ok: true,
      value: { text: "one\r", terminated: true },
    });
    expect(await opened.value.readLine(context)).toEqual({
      ok: true,
      value: { text: "two", terminated: true },
    });
    expect(await opened.value.readLine(context)).toEqual({
      ok: true,
      value: { text: "three", terminated: false },
    });
    expect(await opened.value.readLine(context)).toEqual({ ok: true, value: undefined });
    const missing = await env.readTextFile("missing", context);
    expect(missing.ok).toBe(false);
    if (!missing.ok) expect(missing.error.code).toBe("not_found");
    expect(await env.exists("missing", context)).toEqual({ ok: true, value: false });
    expect((await env.renameFile("note.txt", "../escape", context)).ok).toBe(false);
    expect(vm.fs.rename).not.toHaveBeenCalled();
    await env.appendFile("note.txt", "!", context);
    await env.truncateFile("note.txt", 3, context);
    expect(await env.readTextFile("note.txt", context)).toEqual({ ok: true, value: "one" });
  });

  it("rejects already-cancelled file and shell calls without guest work", async () => {
    const { env, vm } = fixture();
    const abort = new AbortController();
    abort.abort();
    const cancelled = withAbortSignal(abort.signal, context);
    const file = await env.writeFile("file", "x", cancelled);
    const exec = await env.exec("touch late", undefined, cancelled);
    expect(file.ok).toBe(false);
    expect(exec.ok).toBe(false);
    if (!file.ok) expect(file.error.code).toBe("aborted");
    if (!exec.ok) expect(exec.error.code).toBe("aborted");
    expect(vm.fs.writeFile).not.toHaveBeenCalled();
    expect(vm.exec).not.toHaveBeenCalled();
    await env.cleanup(context);
  });

  it("retains a failed guest kill so cleanup cannot falsely confirm Stop", async () => {
    const { env, vm } = fixture();
    const abort = new AbortController();
    vm.exec = vi.fn((args) => {
      if (Array.isArray(args) && args[0] === "/bin/sh")
        throw new Error("Guest control connection lost");
      return Object.assign(
        Promise.resolve({ ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) }),
        {
          async *output() {
            yield { stream: "stdout" as const, data: Buffer.from("42 12345\n") };
            yield { stream: "stdout" as const, data: Buffer.from("STARTED") };
          },
          write() {},
          end() {},
        },
      );
    });
    await expect(
      env.exec(
        "sleep 30",
        { onOutput: () => abort.abort() },
        withAbortSignal(abort.signal, context),
      ),
    ).rejects.toThrow("Failed to kill durable sandbox guest work");
    await expect(env.cleanup(context)).rejects.toThrow("Failed to kill durable sandbox guest work");
  });

  it.each(["1 123", "01 123", "-42 123", "42 0123", "42 nope", "99999999999999999999 123"])(
    "never ACKs an invalid identity %s",
    async (header) => {
      const { env, vm } = fixture();
      const write = vi.fn();
      vm.exec = vi.fn(() =>
        Object.assign(
          Promise.resolve({ ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) }),
          {
            async *output() {
              yield { stream: "stdout" as const, data: Buffer.from(`${header}\n`) };
            },
            write,
            end() {},
          },
        ),
      );
      const result = await env.exec("touch late", undefined, context);
      expect(result.ok).toBe(false);
      if (!result.ok) expect(result.error.message).toContain("Invalid guest process identity");
      expect(write).not.toHaveBeenCalled();
      expect(vm.exec).toHaveBeenCalledOnce();
    },
  );

  it("withholds ACK on abort during a fragmented handshake and kills only the host-held identity", async () => {
    const { env, vm } = fixture();
    const abort = new AbortController();
    const write = vi.fn();
    const calls: Array<string[] | string> = [];
    vm.exec = vi.fn((args) => {
      calls.push(args);
      return Object.assign(
        Promise.resolve({ ok: true, exitCode: 0, stdout: "", stdoutBuffer: Buffer.alloc(0) }),
        {
          async *output() {
            yield { stream: "stdout" as const, data: Buffer.from("42 ") };
            abort.abort();
            yield { stream: "stdout" as const, data: Buffer.from("12345\n") };
          },
          write,
          end() {},
        },
      );
    });
    const result = await env.exec("touch late", undefined, withAbortSignal(abort.signal, context));
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error.code).toBe("aborted");
    expect(write).not.toHaveBeenCalled();
    expect(calls).toHaveLength(2);
    expect((calls[1] as string[]).slice(-2)).toEqual(["42", "12345"]);
    expect(vm.fs.readFile).not.toHaveBeenCalled();
  });

  it("retains a non-zero kill result so Stop cannot turn guest signaling errors into success", async () => {
    const { env, vm } = fixture();
    const abort = new AbortController();
    vm.exec = vi.fn((args) => {
      const killing = args.includes("oppi-kill");
      return Object.assign(
        Promise.resolve({
          ok: !killing,
          exitCode: killing ? 1 : 0,
          stdout: "",
          stdoutBuffer: Buffer.alloc(0),
        }),
        {
          async *output() {
            yield { stream: "stdout" as const, data: Buffer.from("42 12345\n") };
            abort.abort();
          },
          write() {},
          end() {},
        },
      );
    });
    await expect(
      env.exec("sleep 30", undefined, withAbortSignal(abort.signal, context)),
    ).rejects.toThrow("Failed to kill");
    await expect(env.cleanup(context)).rejects.toThrow("Failed to kill");
  });

  it("shares a file namespace across sessions of the same workspace, not other workspaces", () => {
    const { env, vm } = fixture();
    expect(new GondolinExecutionEnv(vm, "w1", "/workspace/project").id).toBe(env.id);
    expect(new GondolinExecutionEnv(vm, "w2", "/workspace/project").id).not.toBe(env.id);
  });
});
