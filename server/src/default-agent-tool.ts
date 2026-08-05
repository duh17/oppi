import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { readPackagedOppiDoc } from "./default-agent-docs-read.js";
import { createOppiToolExtensionFactory } from "./oppi-tool-extension.js";
import type { OppiApprovalPolicy } from "./oppi-extension-settings.js";
import { getOppiDocsPath } from "./oppi-docs.js";

const DefaultAgentAskOptionSchema = Type.Object({
  value: Type.String({ description: "Return value when selected" }),
  label: Type.String({ description: "Display label" }),
  description: Type.Optional(Type.String({ description: "Short description below label" })),
});

const DefaultAgentAskQuestionSchema = Type.Object({
  id: Type.String({ description: "Stable key for the answer map" }),
  question: Type.String({ description: "Full question text" }),
  options: Type.Array(DefaultAgentAskOptionSchema, {
    description: "Options for the user to choose from (2-6 recommended)",
  }),
  multiSelect: Type.Optional(Type.Boolean({ description: "Allow selecting multiple options" })),
});

const DefaultAgentAskParams = Type.Object({
  questions: Type.Array(DefaultAgentAskQuestionSchema, { minItems: 1 }),
  allowCustom: Type.Optional(
    Type.Boolean({ description: "Allow typing a custom answer per question. Default: true" }),
  ),
});

type DefaultAgentAskQuestion = {
  id: string;
  question: string;
  options: Array<{ value: string; label: string; description?: string }>;
  multiSelect?: boolean;
};

type DefaultAgentAskAnswer = string | string[];
type DefaultAgentAskResult = {
  answers: Record<string, DefaultAgentAskAnswer>;
  allIgnored: boolean;
  usedDefaults?: boolean;
};

export function createDefaultAgentExtensionFactory(options: {
  dataDir?: string;
  callerSessionId: string;
  policySnapshot: Readonly<{ approvalPolicy: OppiApprovalPolicy }>;
}): ExtensionFactory {
  return (pi) => {
    createOppiToolExtensionFactory({
      ...(options.dataDir !== undefined ? { dataDir: options.dataDir } : {}),
      identity: "control",
      policySnapshot: options.policySnapshot,
      callerSessionId: options.callerSessionId,
    })(pi);

    let askedThisTurn = false;
    pi.on("turn_start", async () => {
      askedThisTurn = false;
    });

    // Replace Pi's host `read` with a docs-only reader. Built-ins are disabled
    // for the control identity, so this is the only `read` available.
    pi.registerTool({
      name: "read",
      label: "read",
      description:
        "Read a file from the packaged Oppi docs directory. Absolute paths outside that directory are rejected.",
      promptSnippet: "Read packaged Oppi docs",
      promptGuidelines: [
        "Use read only for shipped Oppi documentation paths from the system prompt.",
        "Do not use read for config, credentials, or arbitrary host files.",
      ],
      parameters: Type.Object({
        path: Type.String({ description: "Path under the packaged Oppi docs directory" }),
        offset: Type.Optional(
          Type.Number({ description: "Line number to start from (1-indexed)" }),
        ),
        limit: Type.Optional(Type.Number({ description: "Maximum number of lines to read" })),
      }),
      executionMode: "parallel",
      async execute(_toolCallId, params, signal) {
        if (signal?.aborted) throw new Error("Operation aborted");
        const docsRoot = getOppiDocsPath();
        if (!docsRoot) throw new Error("Packaged Oppi docs are unavailable");
        const result = await readPackagedOppiDoc(String(params.path ?? ""), {
          docsRoot,
          ...(typeof params.offset === "number" ? { offset: params.offset } : {}),
          ...(typeof params.limit === "number" ? { limit: params.limit } : {}),
        });
        if (signal?.aborted) throw new Error("Operation aborted");
        return {
          content: [{ type: "text" as const, text: result.text }],
          details: { path: result.path, truncated: result.truncated, docsRoot },
        };
      },
    });

    pi.registerTool({
      name: "ask",
      label: "Ask",
      description:
        "Ask the user one or more clarifying questions with predefined options. Call once per turn and bundle related questions into one request.",
      promptSnippet:
        "Ask the user structured clarifying questions when preferences or tradeoffs are ambiguous",
      promptGuidelines: [
        "Call ask at most once per turn.",
        "Use oppi help/docs for discoverable state before asking.",
        "Ask only about preferences or tradeoffs that change the result.",
      ],
      parameters: DefaultAgentAskParams,
      executionMode: "sequential",
      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        if (askedThisTurn) {
          throw new Error("Only one ask call per turn. Bundle all questions into a single call.");
        }
        askedThisTurn = true;

        const questions = params.questions as DefaultAgentAskQuestion[];
        if (signal?.aborted) {
          return {
            content: [{ type: "text" as const, text: "Ask request cancelled." }],
            details: { questions, answers: {}, allIgnored: true, cancelled: true },
          };
        }
        const askUI = ctx.ui as typeof ctx.ui & {
          ask?: (
            questions: DefaultAgentAskQuestion[],
            allowCustom?: boolean,
            options?: { signal?: AbortSignal },
          ) => Promise<DefaultAgentAskResult>;
        };
        const result =
          ctx.hasUI && typeof askUI.ask === "function"
            ? await askUI.ask(
                questions,
                params.allowCustom ?? true,
                signal ? { signal } : undefined,
              )
            : defaultAgentAskFallback(questions);

        return {
          content: [
            {
              type: "text" as const,
              text: result.allIgnored
                ? "All questions were skipped. Proceed using best judgment."
                : result.usedDefaults
                  ? `No ask UI available. Defaults: ${JSON.stringify(result.answers)}`
                  : `User answers: ${JSON.stringify(result.answers)}`,
            },
          ],
          details: { questions, ...result },
        };
      },
    });
  };
}

function defaultAgentAskFallback(questions: DefaultAgentAskQuestion[]): DefaultAgentAskResult {
  const answers = Object.fromEntries(
    questions.flatMap((question) => {
      const first = question.options[0]?.value;
      if (!first) return [];
      return [[question.id, question.multiSelect ? [first] : first] as const];
    }),
  );
  return { answers, allIgnored: Object.keys(answers).length === 0, usedDefaults: true };
}
