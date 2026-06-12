import type {
  ExtensionContext,
  ExtensionFactory,
  ExtensionUIDialogOptions,
} from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

import {
  buildAskToolResult,
  buildFallbackAnswers,
  singleLine,
  type AskAnswer,
  type AskDialogResult,
  type AskQuestion,
} from "./ask-shared.js";
import { runTerminalAskDialog } from "./ask-terminal.js";

const AskOptionSchema = Type.Object({
  value: Type.String({ description: "Return value when selected" }),
  label: Type.String({ description: "Display label" }),
  description: Type.Optional(
    Type.String({ description: "Short description below label" }),
  ),
});

const AskQuestionSchema = Type.Object({
  id: Type.String({ description: "Stable key for the answer map" }),
  question: Type.String({ description: "Full question text" }),
  options: Type.Array(AskOptionSchema, {
    description: "Options for the user to choose from (2-6 recommended)",
  }),
  multiSelect: Type.Optional(
    Type.Boolean({
      description: "Allow selecting multiple options. Default: false",
    }),
  ),
});

const AskParams = Type.Object({
  questions: Type.Array(AskQuestionSchema, {
    minItems: 1,
    description:
      "One or more questions to ask. Presented as a horizontal pager on mobile.",
  }),
  allowCustom: Type.Optional(
    Type.Boolean({
      description: "Allow typing a custom answer per question. Default: true",
    }),
  ),
});

function questionModeLabel(
  question: AskQuestion,
  allowCustom: boolean,
): string {
  const parts = [question.multiSelect ? "multi-select" : "single-select"];
  if (allowCustom) {
    parts.push("custom");
  }
  return parts.join(" + ");
}

function displayAnswerValue(
  question: AskQuestion | undefined,
  value: string,
): string {
  if (!question) {
    return value;
  }

  const matched = question.options.find((option) => option.value === value);
  if (matched) {
    return matched.label;
  }

  return `"${singleLine(value)}"`;
}

function displayAnswer(
  question: AskQuestion | undefined,
  answer: AskAnswer,
): string {
  if (Array.isArray(answer)) {
    return answer
      .map((value) => displayAnswerValue(question, value))
      .join(", ");
  }
  return displayAnswerValue(question, answer);
}

type AskUIContext = ExtensionContext["ui"] & {
  ask?: (
    questions: AskQuestion[],
    allowCustom?: boolean,
    opts?: ExtensionUIDialogOptions,
  ) => Promise<AskDialogResult>;
};

const CUSTOM_CHOICE = "✎ Custom answer…";
const SKIP_CHOICE = "↷ Skip";

function optionChoiceLabel(
  option: { label: string; description?: string },
  index: number,
): string {
  const label = `${index + 1}. ${singleLine(option.label)}`;
  return option.description
    ? `${label} — ${singleLine(option.description)}`
    : label;
}

function multiOptionChoiceLabel(
  question: AskQuestion,
  index: number,
  selected: Set<string>,
): string {
  const option = question.options[index];
  const mark = selected.has(option.value) ? "[x]" : "[ ]";
  return `${mark} ${optionChoiceLabel(option, index)}`;
}

async function promptForCustomAnswer(
  ctx: ExtensionContext,
  title: string,
  opts: ExtensionUIDialogOptions | undefined,
): Promise<string | undefined> {
  const answer = await ctx.ui.input(title, "Type a custom answer", opts);
  const trimmed = answer?.trim();
  return trimmed ? trimmed : undefined;
}

async function runPortableSingleSelectFallback(
  ctx: ExtensionContext,
  question: AskQuestion,
  allowCustom: boolean,
  opts: ExtensionUIDialogOptions | undefined,
): Promise<AskAnswer | undefined> {
  const title = question.question || question.id;
  const optionChoices = question.options.map(optionChoiceLabel);

  if (optionChoices.length === 0) {
    return allowCustom ? promptForCustomAnswer(ctx, title, opts) : undefined;
  }

  const choices = allowCustom
    ? [...optionChoices, CUSTOM_CHOICE, SKIP_CHOICE]
    : [...optionChoices, SKIP_CHOICE];
  const selected = await ctx.ui.select(title, choices, opts);
  if (!selected || selected === SKIP_CHOICE) return undefined;
  if (selected === CUSTOM_CHOICE)
    return promptForCustomAnswer(ctx, title, opts);

  const optionIndex = optionChoices.indexOf(selected);
  return optionIndex >= 0 ? question.options[optionIndex].value : selected;
}

async function runPortableMultiSelectFallback(
  ctx: ExtensionContext,
  question: AskQuestion,
  allowCustom: boolean,
  opts: ExtensionUIDialogOptions | undefined,
): Promise<AskAnswer | undefined> {
  const title = question.question || question.id;
  const selected = new Set<string>();
  const customAnswers: string[] = [];

  if (question.options.length === 0) {
    const custom = allowCustom
      ? await promptForCustomAnswer(ctx, title, opts)
      : undefined;
    return custom ? [custom] : undefined;
  }

  while (!opts?.signal?.aborted) {
    const optionChoices = question.options.map((_, index) =>
      multiOptionChoiceLabel(question, index, selected),
    );
    const selectedCount = selected.size + customAnswers.length;
    const doneChoice =
      selectedCount > 0 ? `✓ Done (${selectedCount} selected)` : "✓ Done";
    const choices = allowCustom
      ? [...optionChoices, CUSTOM_CHOICE, doneChoice, SKIP_CHOICE]
      : [...optionChoices, doneChoice, SKIP_CHOICE];

    const choice = await ctx.ui.select(title, choices, opts);
    if (!choice || choice === SKIP_CHOICE) return undefined;

    if (choice === doneChoice) {
      const selectedValues = question.options
        .filter((option) => selected.has(option.value))
        .map((option) => option.value);
      const answers = [...selectedValues, ...customAnswers];
      return answers.length > 0 ? answers : undefined;
    }

    if (choice === CUSTOM_CHOICE) {
      const custom = await promptForCustomAnswer(ctx, title, opts);
      if (custom) customAnswers.push(custom);
      continue;
    }

    const optionIndex = optionChoices.indexOf(choice);
    const option = optionIndex >= 0 ? question.options[optionIndex] : undefined;
    if (!option) continue;

    if (selected.has(option.value)) {
      selected.delete(option.value);
    } else {
      selected.add(option.value);
    }
  }

  return undefined;
}

async function runPortableAskFallback(
  ctx: ExtensionContext,
  questions: AskQuestion[],
  allowCustom: boolean,
  opts: ExtensionUIDialogOptions | undefined,
): Promise<AskDialogResult> {
  const answers: Record<string, AskAnswer> = {};

  for (const question of questions) {
    if (opts?.signal?.aborted) break;

    const answer = question.multiSelect
      ? await runPortableMultiSelectFallback(ctx, question, allowCustom, opts)
      : await runPortableSingleSelectFallback(ctx, question, allowCustom, opts);
    if (answer !== undefined) {
      answers[question.id] = answer;
    }
  }

  return { answers, allIgnored: Object.keys(answers).length === 0 };
}

async function runAskDialog(
  ctx: ExtensionContext,
  questions: AskQuestion[],
  allowCustom: boolean,
  opts: ExtensionUIDialogOptions | undefined,
): Promise<AskDialogResult> {
  const ui = ctx.ui as AskUIContext;

  if (typeof ui.ask === "function") {
    return ui.ask(questions, allowCustom, opts);
  }

  if (ctx.mode === "tui") {
    const custom = ctx.ui.custom.bind(ctx.ui) as Parameters<
      typeof runTerminalAskDialog
    >[0];
    const result = await runTerminalAskDialog(
      custom,
      questions,
      allowCustom,
      opts,
    );
    return result ?? { answers: {}, allIgnored: true };
  }

  return runPortableAskFallback(ctx, questions, allowCustom, opts);
}

/**
 * Ask extension example.
 *
 * The tool supports multiple questions, multi-select options, custom answers,
 * and native AskCard rendering on Oppi clients that expose `ctx.ui.ask()`.
 * TUI sessions use the terminal custom dialog, and other Pi UI contexts fall
 * back to standard select/input prompts.
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
      executionMode: "sequential",

      async execute(_toolCallId, params, signal, _onUpdate, ctx) {
        if (!Array.isArray(params.questions) || params.questions.length === 0) {
          throw new Error("ask requires at least one question");
        }

        if (askedThisTurn) {
          throw new Error(
            "Only one ask call per turn. Bundle all questions into a single call.",
          );
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
            details: {
              questions: params.questions,
              answers: fallback,
              allIgnored: false,
            },
          };
        }

        const allowCustom = params.allowCustom ?? true;
        const dialogOptions = signal ? { signal } : undefined;
        const askResult = await runAskDialog(
          ctx,
          params.questions,
          allowCustom,
          dialogOptions,
        );
        return buildAskToolResult(params.questions, askResult.answers);
      },

      renderCall(args, theme) {
        const questions = Array.isArray(args.questions)
          ? (args.questions as AskQuestion[])
          : [];
        const allowCustom = args.allowCustom !== false;
        let text = theme.fg("toolTitle", theme.bold("ask "));

        if (questions.length === 1) {
          const question = questions[0];
          text += theme.fg(
            "muted",
            singleLine(question.question || question.id),
          );
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
        const questionById = new Map(
          questions.map((question) => [question.id, question]),
        );
        const orderedKeys =
          questions.length > 0
            ? questions.map((question) => question.id)
            : Object.keys(answers);
        if (orderedKeys.length === 0) {
          return new Text(theme.fg("warning", "No answers"), 0, 0);
        }

        const extraKeys = Object.keys(answers).filter(
          (key) => !orderedKeys.includes(key),
        );
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

export default createAskFactory();
