import { afterEach, describe, expect, it, vi } from "vitest";

import { runCli, type CliRunResult } from "../src/cli/runner.js";
import { createDefaultAgentExtensionFactory } from "../src/default-agent-tool.js";
import { OPPI_EXTENSION_READ_ONLY_ERROR } from "../src/oppi-tool-extension.js";

vi.mock("../src/cli/runner.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/runner.js")>();
  return { ...actual, runCli: vi.fn() };
});

const canonicalRun = vi.mocked(runCli);

function successfulRun(): CliRunResult {
  return {
    ok: true,
    exitCode: 0,
    stdout: '{\n  "ok": true,\n  "data": {"accepted": true}\n}\n',
    humanOutput: "\u001b[32mDone\u001b[0m\n",
    json: { ok: true, data: { accepted: true } },
  };
}

type RegisteredTool = {
  promptGuidelines?: string[];
  execute: (
    toolCallId: string,
    params: unknown,
    signal: AbortSignal | undefined,
    onUpdate: undefined,
    context: unknown,
  ) => Promise<{ content: Array<{ type: string; text?: string }>; details?: unknown }>;
};

function registeredTools(
  approvalPolicy:
    | "confirmDestructiveOnly"
    | "confirmAllChanges"
    | "readOnly" = "confirmDestructiveOnly",
): Map<string, RegisteredTool> {
  const tools = new Map<string, RegisteredTool>();
  createDefaultAgentExtensionFactory({
    callerSessionId: "control-test",
    policySnapshot: { approvalPolicy },
  })({
    on: () => undefined,
    registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
  } as never);
  return tools;
}

afterEach(() => {
  canonicalRun.mockReset();
});

describe("Oppi agent Oppi tool", () => {
  it("routes session questions by intent without forcing unnecessary disclosure calls", () => {
    const oppi = registeredTools().get("oppi");
    if (!oppi) throw new Error("Oppi tool was not registered");

    const guidance = oppi.promptGuidelines?.join(" ") ?? "";
    expect(guidance).toContain(
      "latest response uses session inspect <id> --view response directly",
    );
    expect(guidance).toContain("current progress uses session inspect <id> --view summary");
    expect(guidance).toContain("session inspect <id> --view outline");
    expect(guidance).toContain("bounded session messages or tools");
    expect(guidance).toContain("session wait for bounded monitoring");
    expect(guidance).toContain("session dialogs");
    expect(guidance).not.toContain("start with session inspect <id> --view summary");
  });

  it("always registers oppi and ask and uses the saved read-only policy", async () => {
    const tools = registeredTools("readOnly");
    // Control identity registers oppi, docs-only read, and ask (no host builtins).
    expect([...tools.keys()]).toEqual(["oppi", "read", "ask"]);

    const confirm = vi.fn(async () => true);
    const oppi = tools.get("oppi");
    if (!oppi) throw new Error("Oppi tool was not registered");

    await expect(
      oppi.execute(
        "read-only-control",
        { args: ["session", "stop", "sess-1"] },
        undefined,
        undefined,
        { hasUI: true, ui: { confirm } },
      ),
    ).rejects.toThrow(OPPI_EXTENSION_READ_ONLY_ERROR);

    expect(confirm).not.toHaveBeenCalled();
    expect(canonicalRun).not.toHaveBeenCalled();
  });

  it("uses the saved confirm-destructive-only policy instead of hard-coded confirm-all", async () => {
    canonicalRun.mockResolvedValueOnce(successfulRun());
    const tools = registeredTools("confirmDestructiveOnly");
    const confirm = vi.fn(async () => true);
    const oppi = tools.get("oppi");
    if (!oppi) throw new Error("Oppi tool was not registered");

    await oppi.execute(
      "control-read-write",
      { args: ["session", "stop", "sess-1"] },
      undefined,
      undefined,
      { hasUI: true, ui: { confirm } },
    );

    expect(confirm).not.toHaveBeenCalled();
    expect(canonicalRun).toHaveBeenCalledOnce();
  });
});

describe("Oppi agent managed ask tool", () => {
  it("uses native structured UI, resets once-per-turn state, and labels fallbacks", async () => {
    const tools = registeredTools();
    let turnStart: (() => Promise<void>) | undefined;
    createDefaultAgentExtensionFactory({
      callerSessionId: "control-test",
      policySnapshot: { approvalPolicy: "confirmDestructiveOnly" },
    })({
      on: (event: string, handler: () => Promise<void>) => {
        if (event === "turn_start") turnStart = handler;
      },
      registerTool: (tool: RegisteredTool & { name: string }) => tools.set(tool.name, tool),
    } as never);

    const params = {
      questions: [
        {
          id: "cadence",
          question: "When should this run?",
          options: [
            { value: "weekdays", label: "Weekdays" },
            { value: "daily", label: "Every day" },
          ],
        },
        {
          id: "recipients",
          question: "Who should receive it?",
          options: [
            { value: "team", label: "Team" },
            { value: "owner", label: "Owner" },
          ],
          multiSelect: true,
        },
      ],
      allowCustom: true,
    };
    const ask = vi.fn(async () => ({
      answers: { cadence: "weekdays", recipients: ["team", "owner"] },
      allIgnored: false,
    }));
    const tool = tools.get("ask");
    if (!tool) throw new Error("Ask tool was not registered");

    const result = await tool.execute("ask-1", params, undefined, undefined, {
      hasUI: true,
      ui: { ask },
    });

    expect(ask).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ id: "cadence" })]),
      true,
      undefined,
    );
    expect(result.details).toMatchObject({
      answers: { cadence: "weekdays", recipients: ["team", "owner"] },
      allIgnored: false,
    });
    await expect(
      tool.execute("ask-2", params, undefined, undefined, { hasUI: false, ui: {} }),
    ).rejects.toThrow(/Only one ask call per turn/);

    await turnStart?.();
    const fallback = await tool.execute("ask-3", params, undefined, undefined, {
      hasUI: false,
      ui: {},
    });
    expect(fallback.content[0]?.text).toContain("No ask UI available. Defaults:");
    expect(fallback.content[0]?.text).not.toContain("User answers:");

    await turnStart?.();
    const controller = new AbortController();
    controller.abort();
    const cancelled = await tool.execute("ask-4", params, controller.signal, undefined, {
      hasUI: true,
      ui: { ask },
    });
    expect(cancelled).toMatchObject({
      content: [{ text: "Ask request cancelled." }],
      details: { allIgnored: true, cancelled: true },
    });
    expect(ask).toHaveBeenCalledTimes(1);
  });
});
