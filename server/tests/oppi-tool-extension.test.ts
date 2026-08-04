import { execFileSync } from "node:child_process";

import { afterEach, describe, expect, it, vi } from "vitest";

import { runCli, type CliRunResult } from "../src/cli/runner.js";
import {
  applyOppiToolPolicy,
  createOppiToolExtensionFactory,
  OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR,
  OPPI_EXTENSION_READ_ONLY_ERROR,
  prepareOppiCommand,
  type OppiApprovalPolicy,
  type OppiToolCommandResult,
  type PreparedOppiCommand,
} from "../src/oppi-tool-extension.js";

vi.mock("../src/cli/runner.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/runner.js")>();
  return { ...actual, runCli: vi.fn() };
});

const canonicalRun = vi.mocked(runCli);

const successfulRun = (humanOutput = "\u001b[32mDone\u001b[0m\n"): CliRunResult => ({
  ok: true,
  exitCode: 0,
  stdout: '{\n  "ok": true,\n  "data": {"accepted": true}\n}\n',
  humanOutput,
  json: { ok: true, data: { accepted: true } },
});

function prepared(args: string[], callerSessionId?: string): PreparedOppiCommand {
  const result = prepareOppiCommand(args, callerSessionId ? { callerSessionId } : undefined);
  expect(result, args.join(" ")).toMatchObject({ ok: true });
  if (!result.ok) throw new Error(result.reason);
  return result.command;
}

function registeredTool(
  policy: OppiApprovalPolicy = "confirmDestructiveOnly",
  callerSessionId = "caller-session",
) {
  type RegisteredTool = {
    execute: (...args: unknown[]) => Promise<unknown>;
  };
  const tools = new Map<string, RegisteredTool>();
  createOppiToolExtensionFactory({
    identity: "ordinary",
    callerSessionId,
    policySnapshot: { approvalPolicy: policy },
  })({
    on: () => undefined,
    registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
  } as never);
  const tool = tools.get("oppi");
  if (!tool) throw new Error("Oppi tool was not registered");
  return tool;
}

afterEach(() => {
  canonicalRun.mockReset();
});

describe("canonical Oppi command preparation", () => {
  it("keeps one immutable approved snapshot and bounds input before CLI parsing", () => {
    const raw = ["session", "send", "sess-1", "--text", "keep this body"];
    const result = prepareOppiCommand(raw, { callerSessionId: "caller" });

    expect(result).toMatchObject({ ok: true });
    if (!result.ok) return;

    raw[2] = "other-session";
    raw[4] = "changed body";
    raw.push("extra");

    expect(result.command.args).toEqual(["session", "send", "sess-1", "--text", "keep this body"]);
    expect(result.command.callerSessionId).toBe("caller");
    expect(Object.isFrozen(result.command)).toBe(true);
    expect(Object.isFrozen(result.command.args)).toBe(true);
  });

  it.each([
    ["session", "create", "--workspace", "ws-1", "--prompt", "@-"],
    ["session", "send", "sess-1", "--text", "@-"],
    ["agent", "update", "agent-1", "--definition", "agent.json"],
    ["schedule", "update", "sch-1", "--definition", "schedule.json"],
    ["skill", "update-file", "skill-1", "--content-json", "@-"],
  ])("rejects mutable mutation body input %s", (...args) => {
    expect(prepareOppiCommand(args)).toMatchObject({
      ok: false,
      reason: expect.stringMatching(/inline|stdin|file/i),
    });
  });

  it("rejects NUL characters that cannot exist in shell arguments", () => {
    expect(prepareOppiCommand(["session", "search", "before\0after"])).toMatchObject({
      ok: false,
      reason: expect.stringContaining("NUL"),
    });
  });

  it("rejects argument-count and aggregate-size overflow", () => {
    expect(
      prepareOppiCommand(["session", "search", ...Array.from({ length: 253 }, () => "x")]),
    ).toMatchObject({ ok: true });
    expect(
      prepareOppiCommand(["session", "search", ...Array.from({ length: 255 }, () => "x")]),
    ).toMatchObject({ ok: false, reason: expect.stringContaining("at most 256") });
    expect(prepareOppiCommand(["session", "search", "x".repeat(300_001)])).toMatchObject({
      ok: false,
      reason: expect.stringContaining("300000-character"),
    });
  });

  it("denies setup, credential, and unrestricted host commands", () => {
    for (const args of [
      ["config", "get", "token"],
      ["pair"],
      ["server", "restart"],
      ["update"],
      ["credentials", "list"],
      ["shell", "exec"],
    ]) {
      expect(prepareOppiCommand(args), args.join(" ")).toMatchObject({ ok: false });
    }
  });

  it("canonicalizes one-session watch to bounded wait", () => {
    expect(
      prepareOppiCommand([
        "session",
        "watch",
        "sess-1",
        "--until",
        "attention",
        "--interval",
        "500ms",
      ]),
    ).toMatchObject({
      ok: true,
      command: {
        args: ["session", "wait", "sess-1", "--for", "attention", "--poll", "500ms"],
        path: ["session", "wait"],
        access: "read",
      },
    });
  });
});

describe("Oppi approval policy", () => {
  const cases: Array<[string, OppiApprovalPolicy, boolean, boolean]> = [
    ["read", "confirmDestructiveOnly", false, true],
    ["read", "confirmAllChanges", false, true],
    ["read", "readOnly", false, true],
    ["mutation", "confirmDestructiveOnly", false, true],
    ["mutation", "confirmAllChanges", true, true],
    ["destructive", "confirmDestructiveOnly", true, true],
    ["destructive", "confirmAllChanges", true, true],
  ];

  it.each(cases)("applies %s under %s", async (kind, policy, shouldApprove, shouldExecute) => {
    const command = prepared(
      kind === "read"
        ? ["workspace", "list"]
        : kind === "mutation"
          ? ["session", "stop", "sess-1"]
          : ["session", "delete", "sess-1"],
    );
    const approve = vi.fn(async () => true);
    const execute = vi.fn(async () => ({ ok: true }) as OppiToolCommandResult);

    const result = await applyOppiToolPolicy({
      prepared: command,
      policy,
      identity: "ordinary",
      approve,
      execute,
    });

    expect(approve).toHaveBeenCalledTimes(shouldApprove ? 1 : 0);
    expect(execute).toHaveBeenCalledTimes(shouldExecute ? 1 : 0);
    expect(result).toMatchObject({ kind: "executed" });
  });

  it("requires approval for session respond under every mutation-capable policy", async () => {
    const command = prepared(["session", "respond", "sess-1", "--dialog", "dialog-1", "--confirm"]);
    const approve = vi.fn(async () => true);
    const execute = vi.fn(async () => ({ ok: true }) as OppiToolCommandResult);

    await applyOppiToolPolicy({
      prepared: command,
      policy: "confirmDestructiveOnly",
      identity: "ordinary",
      approve,
      execute,
    });

    expect(approve).toHaveBeenCalledOnce();
    expect(execute).toHaveBeenCalledOnce();
  });

  it("rejects read-only mutations without approval or execution", async () => {
    const command = prepared(["session", "stop", "sess-1"]);
    const approve = vi.fn(async () => true);
    const execute = vi.fn(async () => ({ ok: true }) as OppiToolCommandResult);

    await expect(
      applyOppiToolPolicy({
        prepared: command,
        policy: "readOnly",
        identity: "ordinary",
        approve,
        execute,
      }),
    ).rejects.toThrow(OPPI_EXTENSION_READ_ONLY_ERROR);
    expect(approve).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it("does not execute after decline, cancellation, or missing UI", async () => {
    const command = prepared(["session", "delete", "sess-1"]);
    const execute = vi.fn(async () => ({ ok: true }) as OppiToolCommandResult);

    await expect(
      applyOppiToolPolicy({
        prepared: command,
        policy: "confirmAllChanges",
        identity: "ordinary",
        approve: async () => false,
        execute,
      }),
    ).resolves.toMatchObject({ kind: "cancelled", reason: "declined" });
    expect(execute).not.toHaveBeenCalled();

    await expect(
      applyOppiToolPolicy({
        prepared: command,
        policy: "confirmAllChanges",
        identity: "ordinary",
        execute,
      }),
    ).rejects.toThrow(OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR);
  });
});

describe("thin Oppi extension", () => {
  it("shows a complete, display-safe, shell-replayable input before ANSI output", async () => {
    const humanOutput = "\u001b[1mSession created\u001b[0m\n";
    const prompt = "Review café.\nChen's full prompt stays visible.\u0085\u001B[31m\u2028\u202E";
    canonicalRun.mockResolvedValueOnce(successfulRun(humanOutput));
    const confirm = vi.fn(async () => true);
    const confirmWithReview = vi.fn(async () => true);
    const tool = registeredTool("confirmAllChanges");

    const result = (await tool.execute(
      "call-1",
      {
        args: [
          "session",
          "create",
          "--workspace",
          "oppi",
          "--prompt",
          prompt,
        ],
      },
      undefined,
      undefined,
      { hasUI: true, ui: { confirm, confirmWithReview } },
    )) as {
      content: Array<{ type: string; text: string }>;
      details: { expandedText: string };
    };

    expect(confirm).toHaveBeenCalledWith("Approve Oppi command", expect.any(String));
    expect(confirmWithReview).not.toHaveBeenCalled();
    expect(canonicalRun).toHaveBeenCalledOnce();
    expect(result).toEqual({
      content: [{ type: "text", text: successfulRun(humanOutput).stdout }],
      details: {
        args: ["session", "create", "--workspace", "oppi", "--prompt", prompt],
        outcome: "result",
        data: { accepted: true },
        expandedText:
          "$ oppi session create --workspace oppi --prompt $'Review café.\\nChen\\'s full prompt stays visible.\\xc2\\x85\\x1b[31m\\xe2\\x80\\xa8\\xe2\\x80\\xae'\n\n" +
          humanOutput,
        presentationFormat: "terminal",
        exitCode: 0,
      },
    });

    let commandLine = result.details.expandedText.split("\n", 1)[0] ?? "";
    const promptPrefix = "$ oppi session create --workspace oppi --prompt ";
    expect(commandLine.startsWith(promptPrefix)).toBe(true);
    commandLine = commandLine.slice(promptPrefix.length);
    const replayed = execFileSync("/bin/bash", ["-c", `printf %s ${commandLine}`], {
      encoding: "utf8",
    });
    expect(replayed).toBe(prompt);
  });

  it("bounds model-facing JSON while keeping the complete terminal transcript", async () => {
    const modelOutput = "x".repeat(60_000);
    const humanOutput = "y".repeat(60_000);
    canonicalRun.mockResolvedValueOnce({
      ...successfulRun(humanOutput),
      stdout: modelOutput,
    });
    const tool = registeredTool();

    const result = (await tool.execute(
      "call-large-output",
      { args: ["session", "read", "sess-1"] },
      undefined,
      undefined,
      { hasUI: false, ui: {} },
    )) as {
      content: Array<{ text: string }>;
      details: { expandedText: string };
    };

    expect(result.content[0]?.text).toContain("[Output truncated: omitted 10000 characters]");
    expect(result.content[0]?.text).not.toBe(modelOutput);
    expect(result.details.expandedText).toBe(`$ oppi session read sess-1\n\n${humanOutput}`);
  });

  it("preserves compact cancellation metadata without executing", async () => {
    const tool = registeredTool("confirmDestructiveOnly");

    const result = await tool.execute(
      "call-cancelled",
      { args: ["session", "delete", "sess-1"] },
      undefined,
      undefined,
      { hasUI: true, ui: { confirm: vi.fn(async () => false) } },
    );

    expect(result).toMatchObject({
      details: {
        args: ["session", "delete", "sess-1"],
        outcome: "cancelled",
        cancelled: true,
        reason: "declined",
      },
    });
    expect(canonicalRun).not.toHaveBeenCalled();
  });

  it("executes a read through the canonical runner under every policy", async () => {
    for (const policy of ["confirmDestructiveOnly", "confirmAllChanges", "readOnly"] as const) {
      canonicalRun.mockResolvedValueOnce(successfulRun());
      const confirm = vi.fn(async () => true);
      const tool = registeredTool(policy);

      await tool.execute(`call-${policy}`, { args: ["workspace", "list"] }, undefined, undefined, {
        hasUI: true,
        ui: { confirm },
      });

      expect(confirm).not.toHaveBeenCalled();
    }
    expect(canonicalRun).toHaveBeenCalledTimes(3);
  });

  it("rejects self-targeting session commands before approval or CLI execution", async () => {
    const confirm = vi.fn(async () => true);
    const tool = registeredTool("confirmAllChanges", "caller-session");

    await expect(
      tool.execute(
        "call-self",
        { args: ["session", "stop", "caller-session"] },
        undefined,
        undefined,
        { hasUI: true, ui: { confirm } },
      ),
    ).rejects.toThrow("Cannot target the calling Oppi session (caller-session)");

    expect(confirm).not.toHaveBeenCalled();
    expect(canonicalRun).not.toHaveBeenCalled();
  });

  it("returns canonical CLI errors as redacted error results", async () => {
    const humanOutput = "\u001b[31mNo owner bearer token configured\u001b[0m\n";
    canonicalRun.mockResolvedValueOnce({
      ...successfulRun(humanOutput),
      ok: false,
      exitCode: 1,
      stdout: '{\n  "ok": false,\n  "error": {"message":"No owner bearer token configured"}\n}\n',
      json: { ok: false, error: { message: "No owner bearer token configured" } },
    });
    const tool = registeredTool("confirmDestructiveOnly");

    const result = await tool.execute(
      "call-error",
      { args: ["workspace", "list"] },
      undefined,
      undefined,
      { hasUI: false, ui: {} },
    );

    expect(result).toMatchObject({
      content: [{ type: "text", text: expect.stringContaining('"ok": false') }],
      details: {
        expandedText: `$ oppi workspace list\n\n${humanOutput}`,
        presentationFormat: "terminal",
        exitCode: 1,
      },
      isError: true,
    });
  });

  it("fails closed when the tool has no confirmation UI for a required approval", async () => {
    const tool = registeredTool("confirmAllChanges");

    await expect(
      tool.execute("call-no-ui", { args: ["session", "delete", "sess-1"] }, undefined, undefined, {
        hasUI: false,
        ui: {},
      }),
    ).rejects.toThrow(OPPI_EXTENSION_APPROVAL_REQUIRED_ERROR);
    expect(canonicalRun).not.toHaveBeenCalled();
  });

  it("passes only bounded audit metadata", async () => {
    canonicalRun.mockResolvedValueOnce(successfulRun());
    const tool = registeredTool();
    const body = "secret-body";

    await tool.execute(
      "call-audit",
      { args: ["session", "send", "sess-secret", "--text", body] },
      undefined,
      undefined,
      { hasUI: false, ui: {} },
    );

    expect(canonicalRun).toHaveBeenCalledOnce();
  });
});
