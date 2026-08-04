import { describe, expect, it } from "vitest";

import {
  captureCliOutput,
  captureHumanCliOutput,
  printDetails,
  setCapturedCliExitCode,
  writeJsonEnvelope,
} from "../src/cli/output.js";

function deferred(): { promise: Promise<void>; resolve: () => void } {
  let resolve = () => {};
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("captured CLI output status", () => {
  it("captures ANSI human output for mobile terminal presentation", async () => {
    const captured = await captureCliOutput(
      async () => {
        captureHumanCliOutput(() => printDetails("✓ Done", [["Status", "ready"]]));
      },
      { includeHuman: true },
    );

    expect(captured.humanStdout).toContain("\x1b[");
    expect(captured.humanStdout).toContain("Done");
    expect(captured.humanStdout).toContain("ready");
  });
  it("keeps overlapping JSON statuses AsyncLocalStorage-local", async () => {
    const previousExitCode = process.exitCode;
    process.exitCode = 23;
    const failureGate = deferred();
    const successGate = deferred();

    try {
      const failure = captureCliOutput(async () => {
        await failureGate.promise;
        writeJsonEnvelope({ ok: false, error: { message: "failed" } });
        setCapturedCliExitCode(1);
      });
      const success = captureCliOutput(async () => {
        await successGate.promise;
        writeJsonEnvelope({ ok: true, data: { value: "ok" } });
      });

      successGate.resolve();
      await Promise.resolve();
      failureGate.resolve();

      const [failed, succeeded] = await Promise.all([failure, success]);
      expect(failed.exitCode).toBe(1);
      expect(JSON.parse(failed.stdout)).toEqual({ ok: false, error: { message: "failed" } });
      expect(succeeded.exitCode).toBe(0);
      expect(JSON.parse(succeeded.stdout)).toEqual({ ok: true, data: { value: "ok" } });
      expect(process.exitCode).toBe(23);
    } finally {
      process.exitCode = previousExitCode;
    }
  });

  it("preserves uncaptured CLI process exit behavior", () => {
    const previousExitCode = process.exitCode;
    try {
      process.exitCode = undefined;
      setCapturedCliExitCode(7);
      expect(process.exitCode).toBe(7);
    } finally {
      process.exitCode = previousExitCode;
    }
  });
});
