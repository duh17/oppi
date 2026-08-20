import { beforeEach, describe, expect, it, vi } from "vitest";

import type { CliRunResult } from "../src/cli/runner.js";
import {
  applyOppiToolPolicy,
  buildOppiToolAudit,
  prepareOppiCommand,
  type PreparedOppiCommand,
} from "../src/oppi-tool-extension.js";

const { records } = vi.hoisted(() => {
  const records: Array<{
    level: string;
    event: string;
    context?: Record<string, unknown>;
  }> = [];
  return { records };
});

vi.mock("../src/logger.js", () => ({
  createLogger: () => ({
    debug: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "debug", event, context });
    },
    info: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "info", event, context });
    },
    warn: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "warn", event, context });
    },
    error: (event: string, context?: Record<string, unknown>) => {
      records.push({ level: "error", event, context });
    },
    child() {
      return this;
    },
    isEnabled: () => true,
  }),
}));

function prepared(args: string[]): PreparedOppiCommand {
  const result = prepareOppiCommand(args);
  expect(result, args.join(" ")).toMatchObject({ ok: true });
  if (!result.ok) throw new Error(result.reason);
  return result.command;
}

function cliError(message: string, code?: string): CliRunResult {
  return {
    ok: false,
    exitCode: 1,
    stdout: `${JSON.stringify({ ok: false, error: { message, ...(code ? { code } : {}) } }, null, 2)}\n`,
    humanOutput: message,
    json: { ok: false, error: { message, ...(code ? { code } : {}) } },
    error: { message },
  };
}

function auditRecords() {
  return records.filter((entry) => entry.event === "oppi_tool.audit");
}

describe("buildOppiToolAudit", () => {
  it("keeps session wait timeout at info with code=timeout", () => {
    const record = buildOppiToolAudit({
      identity: "ordinary",
      access: "read",
      policy: "confirmDestructiveOnly",
      action: "session wait",
      outcome: "not-required",
      result: "error",
      startedAt: 1_000,
      now: 1_250,
      code: "timeout",
      error: "Timed out waiting for session s1 to reach idle",
    });

    expect(record).toMatchObject({
      level: "info",
      result: "error",
      code: "timeout",
      error: "Timed out waiting for session s1 to reach idle",
      duration: 250,
    });
  });

  it("promotes unexpected failures to warn and never omits a cause", () => {
    const record = buildOppiToolAudit({
      identity: "ordinary",
      access: "read",
      policy: "confirmDestructiveOnly",
      action: "session get",
      outcome: "not-required",
      result: "error",
      startedAt: 1_000,
      now: 1_010,
    });

    expect(record.level).toBe("warn");
    expect(record.result).toBe("error");
    expect(record.code ?? record.error).toBeTruthy();
  });

  it("keeps successful audits at info", () => {
    const record = buildOppiToolAudit({
      identity: "ordinary",
      access: "read",
      policy: "confirmDestructiveOnly",
      action: "session list",
      outcome: "not-required",
      result: "success",
      startedAt: 1_000,
      now: 1_005,
    });

    expect(record.level).toBe("info");
    expect(record.result).toBe("success");
    expect(record.code).toBeUndefined();
  });
});

describe("oppi_tool.audit", () => {
  beforeEach(() => {
    records.length = 0;
  });

  it("logs session wait timeout at info with code=timeout and an error", async () => {
    const timeoutMessage = "Timed out waiting for session sess-1 to reach idle";
    const result = await applyOppiToolPolicy({
      prepared: prepared(["session", "wait", "sess-1", "--timeout", "1s"]),
      policy: "confirmDestructiveOnly",
      identity: "ordinary",
      execute: async () => cliError(timeoutMessage),
    });

    expect(result).toMatchObject({ kind: "executed", result: { ok: false } });
    expect(auditRecords()).toEqual([
      expect.objectContaining({
        level: "info",
        event: "oppi_tool.audit",
        context: expect.objectContaining({
          action: "session wait",
          result: "error",
          code: "timeout",
          error: timeoutMessage,
        }),
      }),
    ]);
  });

  it("logs unexpected command failures at warn with a diagnosable cause", async () => {
    const result = await applyOppiToolPolicy({
      prepared: prepared(["session", "get", "sess-missing"]),
      policy: "confirmDestructiveOnly",
      identity: "ordinary",
      execute: async () => cliError("Session not found"),
    });

    expect(result).toMatchObject({ kind: "executed", result: { ok: false } });
    const [entry] = auditRecords();
    expect(entry?.level).toBe("warn");
    expect(entry?.context).toMatchObject({
      action: "session get",
      result: "error",
      error: "Session not found",
    });
    expect(entry?.context?.code ?? entry?.context?.error).toBeTruthy();
  });

  it("logs thrown execute failures at warn with the exception message", async () => {
    await expect(
      applyOppiToolPolicy({
        prepared: prepared(["session", "list"]),
        policy: "confirmDestructiveOnly",
        identity: "ordinary",
        execute: async () => {
          throw new Error("socket closed");
        },
      }),
    ).rejects.toThrow("socket closed");

    expect(auditRecords()).toEqual([
      expect.objectContaining({
        level: "warn",
        event: "oppi_tool.audit",
        context: expect.objectContaining({
          action: "session list",
          result: "error",
          error: "socket closed",
        }),
      }),
    ]);
  });
});
