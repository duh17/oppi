import { Editor, Key, matchesKey, truncateToWidth, type EditorTheme } from "@earendil-works/pi-tui";

import {
  singleLine,
  type AskAnswer,
  type AskDialogResult,
  type AskOption,
  type AskQuestion,
} from "./ask-shared.js";

type AskState = {
  value?: AskAnswer;
  display?: string;
  skipped?: boolean;
  wasCustom?: boolean;
};

type AskEntry =
  | { kind: "option"; option: AskOption }
  | { kind: "custom" }
  | { kind: "skip" }
  | { kind: "back" }
  | { kind: "continue" };

type AskDialogTheme = {
  fg: (token: string, text: string) => string;
  bg: (token: string, text: string) => string;
  bold: (text: string) => string;
};

type AskDialogComponent = {
  render: (width: number) => string[];
  invalidate?: () => void;
  handleInput: (data: string) => void;
};

export type AskCustomRunner = (
  factory: (
    tui: { requestRender: () => void },
    theme: AskDialogTheme,
    kb: unknown,
    done: (result: AskDialogResult) => void,
  ) => AskDialogComponent,
) => Promise<AskDialogResult | undefined>;

export async function runTerminalAskDialog(
  custom: AskCustomRunner,
  questions: AskQuestion[],
  allowCustom: boolean,
): Promise<AskDialogResult | undefined> {
  return custom((tui, theme, _kb, done) => {
    let currentPage = 0;
    let optionIndex = 0;
    let inputQuestionId: string | null = null;
    let cachedLines: string[] | undefined;

    const states = new Map<string, AskState>();
    const multiDrafts = new Map<string, Set<string>>();

    const editorTheme: EditorTheme = {
      borderColor: (text) => theme.fg("accent", text),
      selectList: {
        selectedPrefix: (text) => theme.fg("accent", text),
        selectedText: (text) => theme.fg("accent", text),
        description: (text) => theme.fg("muted", text),
        scrollInfo: (text) => theme.fg("dim", text),
        noMatch: (text) => theme.fg("warning", text),
      },
    };
    const editor = new Editor(tui as never, editorTheme);

    const pageCount = (): number => (questions.length > 1 ? questions.length + 1 : 1);
    const isReviewPage = (): boolean => questions.length > 1 && currentPage === questions.length;
    const currentQuestion = (): AskQuestion | undefined => questions[currentPage];
    const canGoBack = (): boolean => questions.length > 1 && currentPage > 0;

    const refresh = (): void => {
      cachedLines = undefined;
      tui.requestRender();
    };

    const buildEntries = (question: AskQuestion): AskEntry[] => {
      const entries: AskEntry[] = question.options.map((option) => ({ kind: "option", option }));
      if (allowCustom) {
        entries.push({ kind: "custom" });
      }
      entries.push({ kind: "skip" });
      if (canGoBack()) {
        entries.push({ kind: "back" });
      }
      if (question.multiSelect) {
        entries.push({ kind: "continue" });
      }
      return entries;
    };

    const getStatus = (questionId: string): "pending" | "answered" | "skipped" => {
      const state = states.get(questionId);
      if (!state) {
        return "pending";
      }
      return state.value === undefined ? "skipped" : "answered";
    };

    const getDraft = (question: AskQuestion): Set<string> => {
      let draft = multiDrafts.get(question.id);
      if (!draft) {
        draft = new Set<string>();
        const state = states.get(question.id);
        if (state?.value && Array.isArray(state.value) && !state.wasCustom) {
          for (const value of state.value) {
            if (question.options.some((option) => option.value === value)) {
              draft.add(value);
            }
          }
        }
        multiDrafts.set(question.id, draft);
      }
      return draft;
    };

    const answerSummary = (question: AskQuestion): string => {
      const state = states.get(question.id);
      if (state?.value !== undefined) {
        return state.display ?? "(answered)";
      }
      if (state?.skipped) {
        return "(skipped)";
      }
      return "(pending)";
    };

    const renderProgressSummary = (width: number, lines: string[]): void => {
      if (questions.length <= 1) {
        return;
      }

      lines.push("");
      lines.push(truncateToWidth(theme.fg("accent", theme.bold(" Answers so far")), width));
      for (let i = 0; i < questions.length; i++) {
        const question = questions[i];
        const status = getStatus(question.id);
        const badge = status === "answered" ? "✓" : status === "skipped" ? "–" : "○";
        const badgeColor =
          status === "answered" ? "success" : status === "skipped" ? "warning" : "dim";
        const summaryColor = status === "answered" ? "text" : "dim";
        lines.push(
          truncateToWidth(
            `${theme.fg(badgeColor, `${badge} `)}${theme.fg("muted", `${i + 1}. `)}${theme.fg(summaryColor, `${singleLine(question.question || question.id)}: ${answerSummary(question)}`)}`,
            width,
          ),
        );
      }
    };

    const buildDialogResult = (): AskDialogResult => {
      const answers: Record<string, AskAnswer> = {};
      for (const question of questions) {
        const state = states.get(question.id);
        if (state?.value !== undefined) {
          answers[question.id] = state.value;
        }
      }
      return {
        answers,
        allIgnored: Object.keys(answers).length === 0,
      };
    };

    const defaultIndexForQuestion = (question: AskQuestion): number => {
      const entries = buildEntries(question);
      const state = states.get(question.id);
      if (!state) {
        return 0;
      }

      if (state.skipped) {
        const skipIndex = entries.findIndex((entry) => entry.kind === "skip");
        return skipIndex >= 0 ? skipIndex : 0;
      }

      if (state.wasCustom && allowCustom) {
        const customIndex = entries.findIndex((entry) => entry.kind === "custom");
        if (customIndex >= 0) {
          return customIndex;
        }
      }

      if (!question.multiSelect && typeof state.value === "string" && !state.wasCustom) {
        const selectedIndex = question.options.findIndex((option) => option.value === state.value);
        if (selectedIndex >= 0) {
          return selectedIndex;
        }
      }

      if (question.multiSelect) {
        const continueIndex = entries.findIndex((entry) => entry.kind === "continue");
        if (continueIndex >= 0) {
          return continueIndex;
        }
      }

      return 0;
    };

    const resetPage = (): void => {
      if (isReviewPage()) {
        optionIndex = 0;
      } else {
        const question = currentQuestion();
        optionIndex = question ? defaultIndexForQuestion(question) : 0;
      }
      refresh();
    };

    const advance = (): void => {
      inputQuestionId = null;
      editor.setText("");

      if (questions.length === 1) {
        done(buildDialogResult());
        return;
      }

      if (currentPage < questions.length - 1) {
        currentPage += 1;
      } else {
        currentPage = questions.length;
      }
      resetPage();
    };

    const movePage = (delta: number): void => {
      const nextPage = Math.max(0, Math.min(pageCount() - 1, currentPage + delta));
      if (nextPage === currentPage) {
        refresh();
        return;
      }
      currentPage = nextPage;
      resetPage();
    };

    const setSingleAnswer = (question: AskQuestion, option: AskOption): void => {
      states.set(question.id, {
        value: option.value,
        display: option.label,
        wasCustom: false,
      });
      advance();
    };

    const setCustomAnswer = (question: AskQuestion, text: string): void => {
      const trimmed = text.trim();
      if (!trimmed) {
        inputQuestionId = null;
        editor.setText("");
        refresh();
        return;
      }

      states.set(question.id, {
        value: question.multiSelect ? [trimmed] : trimmed,
        display: trimmed,
        wasCustom: true,
      });
      multiDrafts.set(question.id, new Set());
      advance();
    };

    const skipQuestion = (question: AskQuestion): void => {
      states.set(question.id, { skipped: true });
      multiDrafts.set(question.id, new Set());
      advance();
    };

    const finalizeMultiSelection = (question: AskQuestion): void => {
      const draft = getDraft(question);
      if (draft.size === 0) {
        states.set(question.id, { skipped: true });
        advance();
        return;
      }

      const selectedOptions = question.options.filter((option) => draft.has(option.value));
      states.set(question.id, {
        value: selectedOptions.map((option) => option.value),
        display: selectedOptions.map((option) => option.label).join(", "),
        wasCustom: false,
      });
      advance();
    };

    const enterInputMode = (question: AskQuestion): void => {
      inputQuestionId = question.id;
      const state = states.get(question.id);
      editor.setText(state?.wasCustom ? (state.display ?? "") : "");
      refresh();
    };

    editor.onSubmit = (value) => {
      const question = questions.find((item) => item.id === inputQuestionId);
      if (!question) {
        return;
      }
      setCustomAnswer(question, value);
    };

    const renderTabs = (width: number, lines: string[]): void => {
      if (questions.length <= 1) {
        return;
      }

      const tabs: string[] = [];
      for (let i = 0; i < questions.length; i++) {
        const status = getStatus(questions[i].id);
        const symbol = status === "answered" ? "■" : status === "skipped" ? "–" : "□";
        const color =
          status === "answered" ? "success" : status === "skipped" ? "warning" : "muted";
        const pill = ` ${symbol} ${i + 1} `;
        tabs.push(
          i === currentPage
            ? theme.bg("selectedBg", theme.fg("text", pill))
            : theme.fg(color, pill),
        );
      }

      const review = " ✓ Review ";
      tabs.push(
        isReviewPage()
          ? theme.bg("selectedBg", theme.fg("text", review))
          : theme.fg("accent", review),
      );

      lines.push(truncateToWidth(` ${tabs.join(" ")}`, width));
      lines.push("");
    };

    const renderQuestion = (width: number, lines: string[], question: AskQuestion): void => {
      const state = states.get(question.id);
      const entries = buildEntries(question);
      const multiDraft = question.multiSelect ? getDraft(question) : undefined;

      lines.push(
        truncateToWidth(
          theme.fg("text", ` ${singleLine(question.question || question.id)}`),
          width,
        ),
      );
      const affordances = [question.multiSelect ? "multi-select" : "single-select"];
      if (allowCustom) {
        affordances.push("custom answer");
      }
      if (canGoBack()) {
        affordances.push("go back");
      }
      const instructions = question.multiSelect
        ? " Toggle options, then Continue when you're happy."
        : " Pick one option, type your own answer, or skip.";
      lines.push(
        truncateToWidth(theme.fg("muted", `${instructions} ${affordances.join(" • ")}`), width),
      );

      if (state?.display) {
        lines.push(
          truncateToWidth(
            theme.fg("dim", state.skipped ? " Current: (skipped)" : ` Current: ${state.display}`),
            width,
          ),
        );
      } else if (state?.skipped) {
        lines.push(truncateToWidth(theme.fg("dim", " Current: (skipped)"), width));
      }

      lines.push("");

      let actionHeaderRendered = false;
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const selected = i === optionIndex;
        const prefix = selected ? theme.fg("accent", " › ") : "   ";

        if (entry.kind !== "option" && !actionHeaderRendered) {
          lines.push(truncateToWidth(theme.fg("muted", " Actions"), width));
          actionHeaderRendered = true;
        }

        if (entry.kind === "option") {
          const chosen = question.multiSelect
            ? Boolean(multiDraft?.has(entry.option.value))
            : state?.value === entry.option.value && !state.wasCustom;
          const mark = question.multiSelect ? (chosen ? "[x]" : "[ ]") : chosen ? "◉" : "○";
          const color = selected ? "accent" : chosen ? "success" : "text";
          lines.push(
            truncateToWidth(
              `${prefix}${theme.fg(color, `${mark} ${singleLine(entry.option.label)}`)}`,
              width,
            ),
          );
          if (entry.option.description) {
            lines.push(
              truncateToWidth(
                `    ${theme.fg("muted", singleLine(entry.option.description))}`,
                width,
              ),
            );
          }
          continue;
        }

        if (entry.kind === "custom") {
          const color = selected ? "accent" : state?.wasCustom ? "success" : "text";
          lines.push(
            truncateToWidth(`${prefix}${theme.fg(color, "✎ Write custom answer…")}`, width),
          );
          if (state?.wasCustom && state.display) {
            lines.push(
              truncateToWidth(`    ${theme.fg("muted", `Current: ${state.display}`)}`, width),
            );
          }
          continue;
        }

        if (entry.kind === "skip") {
          const color = selected ? "accent" : state?.skipped ? "warning" : "text";
          lines.push(
            truncateToWidth(`${prefix}${theme.fg(color, "↷ Skip — decide for me")}`, width),
          );
          continue;
        }

        if (entry.kind === "back") {
          const color = selected ? "accent" : "text";
          lines.push(
            truncateToWidth(`${prefix}${theme.fg(color, "← Back to previous question")}`, width),
          );
          continue;
        }

        const selectedCount = multiDraft?.size ?? 0;
        const label =
          selectedCount > 0
            ? `→ Continue with ${selectedCount} selected`
            : "→ Continue without selecting anything";
        const color = selected ? "accent" : selectedCount > 0 ? "success" : "dim";
        lines.push(truncateToWidth(`${prefix}${theme.fg(color, label)}`, width));
      }

      renderProgressSummary(width, lines);
    };

    const renderInput = (width: number, lines: string[], question: AskQuestion): void => {
      lines.push(
        truncateToWidth(
          theme.fg("text", ` ${singleLine(question.question || question.id)}`),
          width,
        ),
      );
      lines.push(truncateToWidth(theme.fg("muted", " Write your answer below."), width));
      lines.push("");
      for (const line of editor.render(Math.max(20, width - 2))) {
        lines.push(truncateToWidth(` ${line}`, width));
      }
    };

    const renderReview = (width: number, lines: string[]): void => {
      lines.push(truncateToWidth(theme.fg("accent", theme.bold(" Review answers")), width));
      lines.push("");

      for (let i = 0; i < questions.length; i++) {
        const question = questions[i];
        const state = states.get(question.id);
        const status = getStatus(question.id);
        const badge = status === "answered" ? "✓" : status === "skipped" ? "–" : "○";
        const badgeColor =
          status === "answered" ? "success" : status === "skipped" ? "warning" : "dim";

        lines.push(
          truncateToWidth(
            `${theme.fg(badgeColor, `${badge} `)}${theme.fg("muted", `${i + 1}. `)}${theme.fg("text", singleLine(question.question || question.id))}`,
            width,
          ),
        );

        if (state?.value !== undefined) {
          lines.push(truncateToWidth(`   ${theme.fg("accent", state.display ?? "")}`, width));
        } else if (state?.skipped) {
          lines.push(truncateToWidth(`   ${theme.fg("dim", "(skipped)")}`, width));
        } else {
          lines.push(truncateToWidth(`   ${theme.fg("dim", "(unanswered)")}`, width));
        }

        lines.push("");
      }

      if (Object.keys(buildDialogResult().answers).length === 0) {
        lines.push(
          truncateToWidth(
            theme.fg("warning", " No answers yet — submit to let the agent use its best judgment."),
            width,
          ),
        );
      } else {
        lines.push(truncateToWidth(theme.fg("success", " Press Enter to submit."), width));
      }
    };

    const render = (width: number): string[] => {
      if (cachedLines) {
        return cachedLines;
      }

      const lines: string[] = [];
      const border = theme.fg("accent", "─".repeat(Math.max(10, width)));
      const title =
        questions.length > 1
          ? ` Clarify before I proceed • ${Math.min(currentPage + 1, questions.length)}/${questions.length}`
          : " Clarify before I proceed";

      lines.push(border);
      lines.push(truncateToWidth(theme.fg("accent", theme.bold(title)), width));
      lines.push("");
      renderTabs(width, lines);

      if (isReviewPage()) {
        renderReview(width, lines);
      } else {
        const question = currentQuestion();
        if (question) {
          if (inputQuestionId === question.id) {
            renderInput(width, lines, question);
          } else {
            renderQuestion(width, lines, question);
          }
        }
      }

      lines.push("");
      const help = inputQuestionId
        ? " Enter save custom answer • Esc cancel editing"
        : isReviewPage()
          ? " Enter submit • ←/Shift-Tab revisit • Esc cancel"
          : questions.length > 1
            ? " ↑↓ navigate • Enter select/toggle • ←/Shift-Tab back • →/Tab next • Esc cancel"
            : " ↑↓ navigate • Enter select/toggle • Esc cancel";
      lines.push(truncateToWidth(theme.fg("dim", help), width));
      lines.push(border);

      cachedLines = lines;
      return lines;
    };

    const handleInput = (data: string): void => {
      if (inputQuestionId) {
        if (matchesKey(data, Key.escape)) {
          inputQuestionId = null;
          editor.setText("");
          refresh();
          return;
        }
        editor.handleInput(data);
        refresh();
        return;
      }

      if (questions.length > 1) {
        if (matchesKey(data, Key.tab) || matchesKey(data, Key.right)) {
          movePage(1);
          return;
        }
        if (matchesKey(data, Key.shift("tab")) || matchesKey(data, Key.left)) {
          movePage(-1);
          return;
        }
      }

      if (isReviewPage()) {
        if (matchesKey(data, Key.enter)) {
          done(buildDialogResult());
          return;
        }
        if (matchesKey(data, Key.escape)) {
          done({ answers: {}, allIgnored: true });
        }
        return;
      }

      const question = currentQuestion();
      if (!question) {
        return;
      }

      const entries = buildEntries(question);
      if (entries.length === 0) {
        done(buildDialogResult());
        return;
      }

      if (matchesKey(data, Key.up)) {
        optionIndex = optionIndex === 0 ? entries.length - 1 : optionIndex - 1;
        refresh();
        return;
      }

      if (matchesKey(data, Key.down)) {
        optionIndex = optionIndex === entries.length - 1 ? 0 : optionIndex + 1;
        refresh();
        return;
      }

      if (matchesKey(data, Key.enter)) {
        const entry = entries[optionIndex];
        if (!entry) {
          return;
        }

        if (entry.kind === "option") {
          if (question.multiSelect) {
            const draft = getDraft(question);
            if (draft.has(entry.option.value)) {
              draft.delete(entry.option.value);
            } else {
              draft.add(entry.option.value);
            }
            states.delete(question.id);
            refresh();
            return;
          }

          setSingleAnswer(question, entry.option);
          return;
        }

        if (entry.kind === "custom") {
          enterInputMode(question);
          return;
        }

        if (entry.kind === "skip") {
          skipQuestion(question);
          return;
        }

        if (entry.kind === "back") {
          movePage(-1);
          return;
        }

        finalizeMultiSelection(question);
        return;
      }

      if (matchesKey(data, Key.escape)) {
        done({ answers: {}, allIgnored: true });
      }
    };

    return {
      render,
      invalidate: () => {
        cachedLines = undefined;
      },
      handleInput,
    };
  });
}
