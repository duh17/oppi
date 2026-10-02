import { Type } from "typebox";
import {
  defineDoc,
  defineExtension,
  defineTool,
  section,
} from "@earendil-works/pi-durable";
import { requestUI } from "../durable-ui.js";
import { buildAskToolResult } from "./extensions/ask-shared.js";

const AskTurn = defineDoc<{ assistant?: number; task?: number }>({
  kind: "oppi.ask-turn",
  version: 1,
  scope: "conversation",
  history: "latest",
  fork: "initial",
  initial: () => ({}),
});
const ask = defineTool({
  name: "ask",
  description:
    "Ask the user one or more clarifying questions with predefined options. " +
    "Call ONCE per turn — bundle all questions into a single call. " +
    "The user can select multiple options, type a custom answer, or ignore any question. " +
    "Prefer asking over guessing when intent is ambiguous.",
  parameters: Type.Object({
    questions: Type.Array(
      Type.Object({
        id: Type.String({ description: "Stable key for the answer map" }),
        question: Type.String({ description: "Full question text" }),
        options: Type.Array(
          Type.Object({
            value: Type.String({ description: "Return value when selected" }),
            label: Type.String({ description: "Display label" }),
            description: Type.Optional(
              Type.String({ description: "Short description below label" }),
            ),
          }),
        ),
        multiSelect: Type.Optional(
          Type.Boolean({
            description: "Allow selecting multiple options. Default: false",
          }),
        ),
      }),
      { minItems: 1 },
    ),
    allowCustom: Type.Optional(
      Type.Boolean({
        description: "Allow typing a custom answer per question. Default: true",
      }),
    ),
  }),
  executionMode: "sequential",
  replay: "safe",
  async execute(args, api, context) {
    const own = await api.getTask(api.taskId, context);
    const assistant = (own?.input as { assistant: number }).assistant;
    await api.commit(async (tx) => {
      const turn = await tx.doc(AskTurn, api.conversationId);
      if (turn.assistant === assistant && turn.task !== api.taskId)
        throw new Error(
          "Only one ask call per turn. Bundle all questions into a single call.",
        );
      turn.assistant = assistant;
      turn.task = api.taskId;
    }, context);
    const response = await requestUI(
      api,
      {
        id: `durable-ui:${api.taskId}`,
        method: "ask",
        questions: args.questions,
        allowCustom: args.allowCustom ?? true,
        extensionScopeId: "repo:ask",
        extensionDisplayName: "Ask",
      },
      context,
    );
    const answers: Record<string, string | string[]> = {};
    if (!response.cancelled && response.value) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(response.value);
      } catch (error) {
        throw new Error(
          `Malformed ask response: ${error instanceof Error ? error.message : String(error)}`,
          { cause: error },
        );
      }
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        throw new Error("Malformed ask response: expected a JSON object");
      for (const [key, value] of Object.entries(parsed)) {
        if (
          typeof value === "string" ||
          (Array.isArray(value) && value.every((v) => typeof v === "string"))
        )
          answers[key] = value;
        else
          throw new Error(
            `Malformed ask response: expected string or string[] for "${key}"`,
          );
      }
    }
    return buildAskToolResult(args.questions, answers);
  },
});
export const DurableAsk = defineExtension({
  name: "ask",
  tools: [ask],
  sections: [
    section(
      "ask-guidelines",
      () =>
        "Call ask at most ONCE per turn. Bundle all questions. Explore discoverable facts with tools first; " +
        "ask early for preferences and tradeoffs. Provide 2-6 clear options, recommended first. " +
        "Use multiSelect when several options can apply. If ignored, use your best judgment; do not re-ask.",
    ),
  ],
});
