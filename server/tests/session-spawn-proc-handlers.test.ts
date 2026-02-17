import type { ChildProcess } from "node:child_process";
import { describe, expect, it, vi } from "vitest";
import { setupProcHandlers } from "../src/session-spawn.js";
import { awaitProcessReady, makeDeps, makeSession, StubProcess } from "./session-spawn.helpers.js";

describe("session-spawn setupProcHandlers", () => {
  it("routes stdout lines to onRpcLine and resolves readiness", async () => {
    const proc = new StubProcess();
    const deps = makeDeps();
    const session = makeSession();

    await awaitProcessReady(
      setupProcHandlers("s1", session, proc as unknown as ChildProcess, deps),
      proc,
    );

    expect(deps.onRpcLine).toHaveBeenCalledWith("s1", '{"type":"agent_start"}');
  });

  it("forwards exit to onSessionEnd as completed", async () => {
    const proc = new StubProcess();
    const deps = makeDeps();
    const session = makeSession();

    await awaitProcessReady(
      setupProcHandlers("s1", session, proc as unknown as ChildProcess, deps),
      proc,
    );

    proc.emit("exit", 0);
    expect(deps.onSessionEnd).toHaveBeenCalledWith("s1", "completed");
  });

  it("forwards process errors to onSessionEnd as error", async () => {
    const proc = new StubProcess();
    const deps = makeDeps();
    const session = makeSession();

    await awaitProcessReady(
      setupProcHandlers("s1", session, proc as unknown as ChildProcess, deps),
      proc,
    );

    proc.emit("error", new Error("boom"));
    expect(deps.onSessionEnd).toHaveBeenCalledWith("s1", "error");
  });

  it("fails fast when process stdout is unavailable", async () => {
    const deps = makeDeps();
    const session = makeSession();
    const proc = {
      stdout: null,
      stderr: null,
      stdin: { write: vi.fn(), writable: true, on: vi.fn() },
      killed: false,
      on: vi.fn(),
    } as unknown as ChildProcess;

    await expect(setupProcHandlers("s1", session, proc, deps)).rejects.toThrow("has no stdout");
  });
});
