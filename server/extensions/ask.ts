import type { ExtensionFactory } from "@mariozechner/pi-coding-agent";
import { Text } from "@mariozechner/pi-tui";
import { Type } from "@sinclair/typebox";

import {
  buildAskToolResult,
  buildFallbackAnswers,
  singleLine,
  type AskAnswer,
  type AskDialogResult,
  type AskQuestion,
} from "./ask-shared.js";

const AskOptionSchema = Type.Object({
  value: Type.String({ description: "Return value when selected" }),
  label: Type.String({ description: "Display label" }),
  description: Type.Optional(Type.String({ description: "Short description below label" })),
});

const AskQuestionSchema = Type.Object({
  id: Type.String({ description: "Stable key for the answer map" }),
  question: Type.String({ description: "Full question text" }),
  options: Type.Array(AskOptionSchema, {
    description: "Options for the user to choose from (2-6 recommended)",
  }),
  multiSelect: Type.Optional(
    Type.Boolean({ description: "Allow selecting multiple options. Default: false" }),
  ),
});

const AskParams = Type.Object({
  questions: Type.Array(AskQuestionSchema, {
    minItems: 1,
    description: "One or more questions to ask. Presented as a horizontal pager on mobile.",
  }),
  allowCustom: Type.Optional(
    Type.Boolean({ description: "Allow typing a custom answer per question. Default: true" }),
  ),
});

function questionModeLabel(question: AskQuestion, allowCustom: boolean): string {
  const parts = [question.multiSelect ? "multi-select" : "single-select"];
  if (allowCustom) {
    parts.push("custom");
  }
  return parts.join(" + ");
}

function displayAnswerValue(question: AskQuestion | undefined, value: string): string {
  if (!question) {
    return value;
  }

  const matched = question.options.find((option) => option.value === value);
  if (matched) {
    return matched.label;
  }

  return `"${singleLine(value)}"`;
}

function displayAnswer(question: AskQuestion | undefined, answer: AskAnswer): string {
  if (Array.isArray(answer)) {
    return answer.map((value) => displayAnswerValue(question, value)).join(", ");
  }
  return displayAnswerValue(question, answer);
}

/**
 * First-party ask extension.
 *
 * Oppi intercepts ask tool execution and renders it as a native AskCard on iOS.
 * Keeping the tool definition server-owned ensures the mobile UI contract and
 * prompt guidance stay in sync even if the host's ~/.pi/agent/extensions changes.
 *
 * The flow now has a clean split:
 * - ask.ts: shared tool contract + Oppi/iOS path
 * - ask-terminal.ts: terminal-only custom dialog
 */
export function createAskFactory(): ExtensionFactory {
  return (pi) => {
    let askedThisTurn = false;

    pi.on("turn_start", async () => {
      askedThisTurn = false;
    });

    pi.registerTool({
      name: "ask",
      label: "Ask",
      description:
        "Ask the user one or more clarifying questions with predefined options. " +
        "Call ONCE per turn — bundle all questions into a single call. " +
        "The user sees a rich card UI where they can tap options, select multiple, " +
        "type a custom answer, or ignore any question. " +
        "Use this whenever the user's intent is ambiguous, there are multiple valid " +
        "approaches, or you are about to make an assumption that could be wrong. " +
        "Prefer asking over guessing.",
      promptSnippet:
        "Ask the user clarifying questions — prefer asking over guessing when intent is ambiguous",
      promptGuidelines: [
        "Call ask at most ONCE per turn. Bundle all your questions into that one call.",
        "Two kinds of unknowns — treat them differently:" +
          "\n  - Discoverable facts (file locations, existing patterns, API shapes): explore first via read/bash/grep. Never ask what you can look up." +
          "\n  - Preferences and tradeoffs (approaches, scope, naming, conventions): ask early. These can't be discovered from the codebase.",
        "Use ask proactively when you face genuine ambiguity. The user has a rich card UI " +
          "that makes answering quick — asking is cheap, guessing wrong is expensive. " +
          "Prefer asking over guessing when the decision materially changes the implementation.",
        "Provide 2-6 clear options per question. Put your recommended option first. " +
          "Include a description when the label alone is ambiguous.",
        "Set multiSelect: true when more than one option can apply (e.g. 'which of these should I include?').",
        "The user can always type a custom answer or ignore any question — your options don't need to cover every possibility.",
        "If the user ignores a question, proceed using your best judgment — don't re-ask the same question.",
        "Good triggers for ask: file organization choices, naming conventions, test strategy, error handling approach, " +
          "scope of a refactor, which features to include, API design tradeoffs, dependency choices.",
      ],
      parameters: AskParams,

      async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
        if (!Array.isArray(params.questions) || params.questions.length === 0) {
          throw new Error("ask requires at least one question");
        }

        if (askedThisTurn) {
          throw new Error("Only one ask call per turn. Bundle all questions into a single call.");
        }
        askedThisTurn = true;

        if (!ctx.hasUI) {
          const fallback = buildFallbackAnswers(params.questions);
          return {
            content: [
              {
                type: "text",
                text: `No UI available. Defaults: ${JSON.stringify(fallback)}`,
              },
            ],
            details: { questions: params.questions, answers: fallback, allIgnored: false },
          };
        }

        const ui = ctx.ui as typeof ctx.ui & {
          ask?: (questions: AskQuestion[], allowCustom?: boolean) => Promise<AskDialogResult>;
        };

        if (typeof ui.ask !== "function") {
          throw new Error("ask UI primitive unavailable");
        }

        const askResult = await ui.ask(params.questions, params.allowCustom ?? true);
        return buildAskToolResult(params.questions, askResult.answers);
      },

      renderCall(args, theme) {
        const questions = Array.isArray(args.questions) ? (args.questions as AskQuestion[]) : [];
        const allowCustom = args.allowCustom !== false;
        let text = theme.fg("toolTitle", theme.bold("ask "));

        if (questions.length === 1) {
          const question = questions[0];
          text += theme.fg("muted", singleLine(question.question || question.id));
          text += `\n${theme.fg("dim", `  ${questionModeLabel(question, allowCustom)}`)}`;
          const labels = question.options.map((option) => option.label);
          if (labels.length > 0) {
            text += `\n${theme.fg("dim", `  ${labels.join(" · ")}`)}`;
          }
        } else if (questions.length > 1) {
          text += theme.fg("muted", `${questions.length} questions`);
          for (const question of questions) {
            text += `\n${theme.fg("dim", `  ${question.id} · ${questionModeLabel(question, allowCustom)}`)}`;
            text += `\n${theme.fg("muted", `    ${singleLine(question.question || question.id)}`)}`;
            const labels = question.options.map((option) => option.label);
            if (labels.length > 0) {
              text += `\n${theme.fg("dim", `    ${labels.join(" · ")}`)}`;
            }
          }
        }

        return new Text(text, 0, 0);
      },

      renderResult(result, _options, theme) {
        const details = result.details as
          | {
              allIgnored?: boolean;
              answers?: Record<string, AskAnswer>;
              questions?: AskQuestion[];
            }
          | undefined;

        if (details?.allIgnored) {
          return new Text(
            theme.fg("dim", "All skipped — agent proceeds using best judgment"),
            0,
            0,
          );
        }

        const answers = details?.answers ?? {};
        const questions = details?.questions ?? [];
        const questionById = new Map(questions.map((question) => [question.id, question]));
        const orderedKeys =
          questions.length > 0 ? questions.map((question) => question.id) : Object.keys(answers);
        if (orderedKeys.length === 0) {
          return new Text(theme.fg("warning", "No answers"), 0, 0);
        }

        const extraKeys = Object.keys(answers).filter((key) => !orderedKeys.includes(key));
        const lines = [...orderedKeys, ...extraKeys].map((key) => {
          const question = questionById.get(key);
          const label = singleLine(question?.question ?? key);
          const answer = answers[key];
          if (answer === undefined) {
            return `${theme.fg("dim", "– ")}${theme.fg("muted", `${label}: `)}${theme.fg("dim", "(skipped)")}`;
          }

          return `${theme.fg("success", "✓ ")}${theme.fg("muted", `${label}: `)}${theme.fg("accent", displayAnswer(question, answer))}`;
        });

        return new Text(lines.join("\n"), 0, 0);
      },
    });
  };
}
