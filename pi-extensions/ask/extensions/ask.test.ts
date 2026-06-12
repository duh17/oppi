import { describe, expect, it } from "vitest";

import { createAskFactory } from "./ask.js";

type TurnStartHandler = () => Promise<void> | void;

type RegisteredTool = {
  name: string;
  execute: (
    toolCallId: string,
    params: {
      questions: Array<{
        id: string;
        question: string;
        options: Array<{ value: string; label: string; description?: string }>;
        multiSelect?: boolean;
      }>;
      allowCustom?: boolean;
    },
    signal?: AbortSignal,
    onUpdate?: unknown,
    ctx?: {
      hasUI: boolean;
      mode?: "tui" | "rpc" | "json" | "print";
      ui: {
        ask?: (
          questions: Array<{
            id: string;
            question: string;
            options: Array<{
              value: string;
              label: string;
              description?: string;
            }>;
            multiSelect?: boolean;
          }>,
          allowCustom?: boolean,
          opts?: { signal?: AbortSignal },
        ) => Promise<{
          answers: Record<string, string | string[]>;
          allIgnored: boolean;
        }>;
        custom: (...args: unknown[]) => Promise<unknown>;
        select: (
          question: string,
          options: string[],
        ) => Promise<string | undefined>;
        input: (
          question: string,
          placeholder?: string,
        ) => Promise<string | undefined>;
      };
    },
  ) => Promise<{
    content: Array<{ type: string; text: string }>;
    details?: unknown;
  }>;
  executionMode?: string;
  renderCall?: (
    args: Record<string, unknown>,
    theme: {
      fg: (token: string, text: string) => string;
      bold: (text: string) => string;
    },
  ) => { render: (width: number) => string[] };
  renderResult?: (
    result: { details?: unknown },
    options: unknown,
    theme: {
      fg: (token: string, text: string) => string;
      bold: (text: string) => string;
    },
  ) => { render: (width: number) => string[] };
};

function createMockAPI(): {
  tools: Map<string, RegisteredTool>;
  on(event: string, handler: TurnStartHandler): void;
  registerTool(tool: RegisteredTool): void;
  resetTurn(): Promise<void>;
} {
  const tools = new Map<string, RegisteredTool>();
  let turnStart: TurnStartHandler | undefined;

  return {
    tools,
    on(event: string, handler: TurnStartHandler) {
      if (event === "turn_start") {
        turnStart = handler;
      }
    },
    registerTool(tool: RegisteredTool) {
      tools.set(tool.name, tool);
    },
    async resetTurn() {
      await turnStart?.();
    },
  };
}

describe("createAskFactory", () => {
  it("registers the ask tool as sequential", () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask");
    expect(tool).toBeDefined();
    expect(tool?.executionMode).toBe("sequential");
  });

  it("enforces one ask call per turn and resets on turn_start", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask");
    expect(tool).toBeDefined();

    const ctx = {
      hasUI: false,
      ui: {
        custom: async () => undefined,
        select: async () => undefined,
        input: async () => undefined,
      },
    };

    const params = {
      questions: [
        {
          id: "scope",
          question: "Which scope?",
          options: [
            { value: "small", label: "Small" },
            { value: "large", label: "Large" },
          ],
        },
      ],
    };

    const first = await tool!.execute(
      "tc-1",
      params,
      undefined,
      undefined,
      ctx,
    );
    expect(first.content[0]?.text).toContain("Defaults");

    await expect(
      tool!.execute("tc-2", params, undefined, undefined, ctx),
    ).rejects.toThrow(/Only one ask call per turn/);

    await api.resetTurn();
    const second = await tool!.execute(
      "tc-3",
      params,
      undefined,
      undefined,
      ctx,
    );
    expect(second.content[0]?.text).toContain("Defaults");
  });

  it("prefers direct ui.ask when available", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;

    let askCalls = 0;
    let customCalls = 0;
    let selectCalls = 0;

    const ctx = {
      hasUI: true,
      ui: {
        ask: async () => {
          askCalls++;
          return {
            answers: { tools: ["ruff", "mypy"] },
            allIgnored: false,
          };
        },
        custom: async () => {
          customCalls++;
          return undefined;
        },
        select: async () => {
          selectCalls++;
          return undefined;
        },
        input: async () => undefined,
      },
    };

    const params = {
      questions: [
        {
          id: "tools",
          question: "Which linting tools?",
          options: [
            { value: "ruff", label: "Ruff" },
            { value: "mypy", label: "Mypy" },
            { value: "pylint", label: "Pylint" },
          ],
          multiSelect: true,
        },
      ],
    };

    const result = await tool.execute(
      "tc-multi",
      params,
      undefined,
      undefined,
      ctx,
    );
    const details = result.details as {
      answers: Record<string, string | string[]>;
    };
    expect(details.answers["tools"]).toEqual(["ruff", "mypy"]);
    expect(askCalls).toBe(1);
    expect(customCalls).toBe(0);
    expect(selectCalls).toBe(0);
  });

  it("uses the terminal custom dialog in TUI mode when direct ask is missing", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;

    let customCalls = 0;
    let selectCalls = 0;
    const ctx = {
      hasUI: true,
      mode: "tui" as const,
      ui: {
        custom: async () => {
          customCalls++;
          return {
            answers: { tools: ["ruff", "mypy"] },
            allIgnored: false,
          };
        },
        select: async () => {
          selectCalls++;
          return undefined;
        },
        input: async () => undefined,
      },
    };

    const params = {
      questions: [
        {
          id: "tools",
          question: "Which linting tools?",
          options: [
            { value: "ruff", label: "Ruff" },
            { value: "mypy", label: "Mypy" },
          ],
          multiSelect: true,
        },
      ],
    };

    const result = await tool.execute(
      "tc-tui",
      params,
      undefined,
      undefined,
      ctx,
    );
    expect(result.details).toMatchObject({
      answers: { tools: ["ruff", "mypy"] },
      allIgnored: false,
    });
    expect(customCalls).toBe(1);
    expect(selectCalls).toBe(0);
  });

  it("falls back to standard Pi UI when direct ask is missing outside TUI", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;

    let customCalls = 0;
    const ctx = {
      hasUI: true,
      mode: "rpc" as const,
      ui: {
        custom: async () => {
          customCalls++;
          return undefined;
        },
        select: async (_title: string, options: string[]) => options[0],
        input: async () => undefined,
      },
    };

    const params = {
      questions: [
        {
          id: "approach",
          question: "Testing approach?",
          options: [
            { value: "unit", label: "Unit tests" },
            { value: "integration", label: "Integration tests" },
          ],
        },
      ],
    };

    const result = await tool.execute(
      "tc-missing-ask",
      params,
      undefined,
      undefined,
      ctx,
    );
    expect(result.details).toMatchObject({
      answers: { approach: "unit" },
      allIgnored: false,
    });
    expect(customCalls).toBe(0);
  });

  it("supports multi-select through standard Pi select fallback", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;

    let selectCalls = 0;
    const seenOptions: string[][] = [];
    const ctx = {
      hasUI: true,
      mode: "rpc" as const,
      ui: {
        custom: async () => undefined,
        select: async (_title: string, options: string[]) => {
          seenOptions.push(options);
          selectCalls++;
          if (selectCalls === 1) return options[0];
          if (selectCalls === 2) return options[1];
          return options.find((option) => option.startsWith("✓ Done"));
        },
        input: async () => undefined,
      },
    };

    const result = await tool.execute(
      "tc-standard-multi",
      {
        questions: [
          {
            id: "targets",
            question: "Which targets?",
            options: [
              { value: "server", label: "Server" },
              { value: "ios", label: "iOS" },
            ],
            multiSelect: true,
          },
        ],
        allowCustom: false,
      },
      undefined,
      undefined,
      ctx,
    );

    expect(result.details).toMatchObject({
      answers: { targets: ["server", "ios"] },
      allIgnored: false,
    });
    expect(seenOptions[0][0]).toContain("[ ] 1. Server");
    expect(seenOptions[1][0]).toContain("[x] 1. Server");
    expect(seenOptions[2]).toContain("✓ Done (2 selected)");
  });

  it("rejects empty question lists without consuming the turn", async () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;

    let askCalls = 0;
    const ctx = {
      hasUI: true,
      ui: {
        ask: async () => {
          askCalls++;
          return {
            answers: { scope: "small" },
            allIgnored: false,
          };
        },
        custom: async () => undefined,
        select: async () => undefined,
        input: async () => undefined,
      },
    };

    await expect(
      tool.execute("tc-empty", { questions: [] }, undefined, undefined, ctx),
    ).rejects.toThrow(/ask requires at least one question/);

    const validResult = await tool.execute(
      "tc-valid",
      {
        questions: [
          {
            id: "scope",
            question: "Which scope?",
            options: [
              { value: "small", label: "Small" },
              { value: "large", label: "Large" },
            ],
          },
        ],
      },
      undefined,
      undefined,
      ctx,
    );

    expect(validResult.details).toMatchObject({
      answers: { scope: "small" },
      allIgnored: false,
    });
    expect(askCalls).toBe(1);
  });

  it("renders human-friendly question modes and answer labels in the TUI", () => {
    const api = createMockAPI();
    createAskFactory()(api as never);
    const tool = api.tools.get("ask")!;
    const theme = {
      fg: (_token: string, text: string) => text,
      bold: (text: string) => text,
    };

    const callText = tool
      .renderCall?.(
        {
          questions: [
            {
              id: "ups_rule",
              question: "How should I handle UPS mail?",
              options: [
                { value: "ups_split_recommended", label: "Split recommended" },
                { value: "ups_archive_all", label: "Archive all" },
              ],
            },
            {
              id: "mail_tags",
              question: "Which tags should I apply?",
              options: [
                { value: "bills", label: "Bills" },
                { value: "receipts", label: "Receipts" },
              ],
              multiSelect: true,
            },
          ],
          allowCustom: true,
        },
        theme,
      )
      .render(160)
      .join("\n");

    expect(callText).toContain("single-select + custom");
    expect(callText).toContain("multi-select + custom");
    expect(callText).toContain("Split recommended · Archive all");

    const resultText = tool
      .renderResult?.(
        {
          details: {
            questions: [
              {
                id: "ups_rule",
                question: "How should I handle UPS mail?",
                options: [
                  {
                    value: "ups_split_recommended",
                    label: "Split recommended",
                  },
                  { value: "ups_archive_all", label: "Archive all" },
                ],
              },
              {
                id: "mail_tags",
                question: "Which tags should I apply?",
                options: [
                  { value: "bills", label: "Bills" },
                  { value: "receipts", label: "Receipts" },
                ],
                multiSelect: true,
              },
              {
                id: "notes",
                question: "Anything else?",
                options: [{ value: "none", label: "Nothing else" }],
              },
            ],
            answers: {
              ups_rule: "ups_split_recommended",
              mail_tags: ["bills", "receipts"],
              notes: "Keep tax paperwork only",
            },
          },
        },
        undefined,
        theme,
      )
      .render(160)
      .join("\n");

    expect(resultText).toContain("Split recommended");
    expect(resultText).toContain("Bills, Receipts");
    expect(resultText).toContain('"Keep tax paperwork only"');
    expect(resultText).not.toContain("ups_split_recommended");
  });
});
