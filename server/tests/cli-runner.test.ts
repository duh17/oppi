import { afterEach, describe, expect, it, vi } from "vitest";

import { localApiRequest } from "../src/cli/local-api-client.js";
import { runCli } from "../src/cli/runner.js";

vi.mock("../src/cli/local-api-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/local-api-client.js")>();
  return { ...actual, localApiRequest: vi.fn() };
});

const request = vi.mocked(localApiRequest);

afterEach(() => {
  request.mockReset();
});

describe("canonical CLI runner", () => {
  it("executes one canonical command and captures its JSON and complete ANSI human output", async () => {
    request.mockResolvedValueOnce({
      agent: { id: "agent-1", name: "Reviewer", status: "active", version: 3 },
    } as never);

    const originalArgv = [...process.argv];
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    let result: Awaited<ReturnType<typeof runCli>>;
    try {
      result = await runCli(["agent", "get", "agent-1"], {
        dataDir: "/tmp/oppi-runner-test",
        captureHuman: true,
        forceJson: true,
      });
    } finally {
      consoleLog.mockRestore();
    }

    expect(consoleLog).not.toHaveBeenCalled();
    expect(process.argv).toEqual(originalArgv);
    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { agent: { id: "agent-1", name: "Reviewer" } },
    });
    expect(result.humanOutput).toContain("Reviewer");
    expect(result.humanOutput).toContain("\u001b[");
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("uses the canonical help renderer for write-command help", async () => {
    const result = await runCli(["session", "delete", "--help"], {
      dataDir: "/tmp/oppi-runner-help-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: true, exitCode: 0 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { help: { title: "Delete session" } },
    });
    expect(result.humanOutput).toContain("Delete session");
    expect(result.humanOutput).toContain("\u001b[");
    expect(request).not.toHaveBeenCalled();
  });

  it("returns a redacted status envelope and the same command-owned human output", async () => {
    const result = await runCli(["status"], {
      dataDir: "/tmp/oppi-runner-status-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result.ok).toBe(true);
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: true,
      data: { status: { server: { transport: expect.any(String) } } },
    });
    expect(result.humanOutput).toContain("Server Configuration");
    expect(result.humanOutput).toContain("\u001b[");
  });

  it("does not terminate the process when a canonical command reports an error", async () => {
    request.mockRejectedValueOnce(new Error("No owner bearer token configured"));

    const result = await runCli(["agent", "list"], {
      dataDir: "/tmp/oppi-runner-error-test",
      captureHuman: true,
      forceJson: true,
    });

    expect(result).toMatchObject({ ok: false, exitCode: 1 });
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      error: { message: expect.stringContaining("No owner") },
    });
    expect(result.humanOutput).toContain("No owner");
    expect(result.humanOutput).toContain("[REDACTED]");
    expect(result.humanOutput).toContain("\u001b[");
  });

  it("forces JSON semantics when the invocation supplies a value-bearing JSON flag", async () => {
    request.mockRejectedValueOnce(new Error("No owner bearer token configured"));
    const exit = vi.spyOn(process, "exit").mockImplementation((() => undefined) as never);
    try {
      const result = await runCli(["agent", "list", "--json", "false"], {
        dataDir: "/tmp/oppi-runner-forced-json-test",
        captureHuman: true,
        forceJson: true,
      });

      expect(exit).not.toHaveBeenCalled();
      expect(result).toMatchObject({ ok: false, exitCode: 1 });
      expect(JSON.parse(result.stdout)).toMatchObject({
        ok: false,
        error: { message: expect.stringContaining("No owner") },
      });
      expect(result.humanOutput).toContain("\u001b[");
    } finally {
      exit.mockRestore();
    }
  });

  it("rejects an in-flight session wait promptly when its AbortSignal is triggered", async () => {
    const controller = new AbortController();
    let resolveInFlight!: (value: unknown) => void;
    let rejectInFlight!: (reason?: unknown) => void;
    const inFlight = new Promise<unknown>((resolve, reject) => {
      resolveInFlight = resolve;
      rejectInFlight = reject;
    });
    request.mockImplementation(async (_storage, _path, options) => {
      const onAbort = (): void => {
        rejectInFlight(Object.assign(new Error("Operation aborted"), { name: "AbortError" }));
      };
      options?.signal?.addEventListener("abort", onAbort, { once: true });
      try {
        return (await inFlight) as never;
      } finally {
        options?.signal?.removeEventListener("abort", onAbort);
      }
    });

    const cliPromise = runCli(
      ["session", "wait", "sess-1", "--for", "idle", "--poll", "1h", "--timeout", "1h"],
      {
        dataDir: "/tmp/oppi-runner-cancellation-test",
        captureHuman: true,
        forceJson: true,
        signal: controller.signal,
      },
    );

    await vi.waitFor(() => expect(request).toHaveBeenCalledOnce());
    controller.abort();

    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      // Red before the fix: the signal never reached the pending API call, so this race returned
      // "pending" instead of the single AbortError rejection asserted below.
      const settled = await Promise.race([
        cliPromise.then(
          () => ({ state: "resolved" as const }),
          (error: unknown) => ({ state: "rejected" as const, error }),
        ),
        new Promise<"pending">((resolve) => {
          timeout = setTimeout(() => resolve("pending"), 100);
        }),
      ]);
      expect(settled).toEqual({
        state: "rejected",
        error: expect.objectContaining({ name: "AbortError" }),
      });
    } finally {
      if (timeout !== undefined) clearTimeout(timeout);
      resolveInFlight({ session: { status: "ready" }, events: [], currentSeq: 1 });
      await cliPromise.catch(() => undefined);
    }
  });
});
