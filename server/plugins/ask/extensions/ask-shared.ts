export type AskOption = {
  value: string;
  label: string;
  description?: string;
};

export type AskQuestion = {
  id: string;
  question: string;
  options: AskOption[];
  multiSelect?: boolean;
};

export type AskAnswer = string | string[];

export type AskDialogResult = {
  answers: Record<string, AskAnswer>;
  allIgnored: boolean;
};

export type AskToolResult = {
  content: Array<{ type: "text"; text: string }>;
  details: {
    questions: AskQuestion[];
    answers: Record<string, AskAnswer>;
    allIgnored: boolean;
  };
};

export function singleLine(text: string): string {
  return text
    .replace(/[\r\n]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function buildFallbackAnswers(questions: AskQuestion[]): Record<string, AskAnswer> {
  const fallback: Record<string, AskAnswer> = {};
  for (const question of questions) {
    if (question.options.length === 0) {
      continue;
    }

    fallback[question.id] = question.multiSelect
      ? [question.options[0].value]
      : question.options[0].value;
  }

  return fallback;
}

export function mapDeferredSelectResults(
  questions: AskQuestion[],
  results: Array<string | undefined>,
): Record<string, AskAnswer> {
  const answers: Record<string, AskAnswer> = {};

  for (let i = 0; i < questions.length; i++) {
    const question = questions[i];
    const selected = results[i];
    if (selected === undefined) {
      continue;
    }

    if (question.multiSelect) {
      let labels: string[];
      try {
        const parsed = JSON.parse(selected);
        labels = Array.isArray(parsed) ? parsed : [selected];
      } catch {
        labels = [selected];
      }

      answers[question.id] = labels.map((label) => {
        const matched = question.options.find((option) => option.label === label);
        return matched?.value ?? label;
      });
      continue;
    }

    const matched = question.options.find((option) => option.label === selected);
    answers[question.id] = matched?.value ?? selected;
  }

  return answers;
}

export function buildAskToolResult(
  questions: AskQuestion[],
  answers: Record<string, AskAnswer>,
): AskToolResult {
  const allIgnored = Object.keys(answers).length === 0;

  if (allIgnored) {
    return {
      content: [
        {
          type: "text",
          text: "The user chose not to answer any questions. Proceed using your best judgment.",
        },
      ],
      details: { questions, answers: {}, allIgnored: true },
    };
  }

  const lines: string[] = [];
  for (const question of questions) {
    const answer = answers[question.id];
    const label = question.question || question.id;
    if (answer === undefined) {
      lines.push(`${label}: (skipped)`);
    } else if (Array.isArray(answer)) {
      lines.push(`${label}: ${answer.join(", ")}`);
    } else {
      lines.push(`${label}: ${answer}`);
    }
  }

  return {
    content: [{ type: "text", text: lines.join("\n") }],
    details: { questions, answers, allIgnored: false },
  };
}
