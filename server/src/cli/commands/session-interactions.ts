import type { LocalApiRequestOptions } from "../local-api-client.js";
import { writeHumanLine } from "../output.js";

type SessionListApiCall = <T>(path: string, options?: LocalApiRequestOptions) => Promise<T>;

// ─── Steering (send / abort) ───

type SessionSendKind = "prompt" | "steer" | "follow_up";

export function resolveSendStreamingKind(
  flags: Record<string, string>,
): "steer" | "follow_up" | undefined {
  const steer = flags.steer === "true";
  const followUp = flags["follow-up"] === "true";
  if (steer && followUp) {
    throw new Error("--steer and --follow-up cannot be used together");
  }
  if (steer) return "steer";
  if (followUp) return "follow_up";
  return undefined;
}

// Compact, single-line session output. Agents parse --json; humans get the fact without framing.
export function printSessionNotice(message: string): void {
  writeHumanLine(message);
}

export async function sendSessionInput(
  id: string,
  commandType: SessionSendKind,
  text: string,
  call: SessionListApiCall,
): Promise<Record<string, unknown>> {
  try {
    return await call<Record<string, unknown>>(`/sessions/${encodeURIComponent(id)}/command`, {
      method: "POST",
      body: {
        type: commandType,
        message: text,
        ...(commandType === "prompt" ? { streamingBehavior: "steer" } : {}),
      },
    });
  } catch (err) {
    // Keep older or incompatible runtimes actionable if they reject the prompt-or-steer form.
    if (commandType === "prompt" && err instanceof Error && /idle session/i.test(err.message)) {
      err.message = `${err.message}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
    }
    throw err;
  }
}

// ─── Extension UI dialogs (dialogs / respond) ───

type DialogOptionSummary = { value?: string; label?: string; description?: string };

type DialogQuestionSummary = {
  id?: string;
  question?: string;
  options?: DialogOptionSummary[];
  multiSelect?: boolean;
};

type DialogResponseMode = "answers" | "cancel" | "confirm" | "decline" | "option" | "text";

export type DialogSnapshot = {
  id?: string;
  sessionId?: string;
  method?: string;
  title?: string;
  message?: string;
  placeholder?: string;
  prefill?: string;
  options?: string[];
  questions?: DialogQuestionSummary[];
  allowCustom?: boolean;
  timeout?: number;
  timeoutAt?: number;
};

export function dialogPromptText(dialog: DialogSnapshot): string {
  const questions = dialog.questions ?? [];
  if (questions.length === 1) {
    return questions[0]?.question?.trim() || dialog.title?.trim() || "(dialog)";
  }
  if (questions.length > 1) {
    return `${questions.length} questions`;
  }
  return dialog.title?.trim() || dialog.message?.trim() || `(${dialog.method ?? "dialog"})`;
}

export function dialogMetaLabels(dialog: DialogSnapshot): string[] {
  const labels: string[] = [];
  if (dialog.allowCustom === true) labels.push("free text allowed");
  if (dialog.allowCustom === false) labels.push("options only");
  if (typeof dialog.timeout === "number") {
    labels.push(`timeout ${Math.round(dialog.timeout / 1000)}s`);
  }
  return labels;
}

function dialogOptionLabel(option: DialogOptionSummary): string {
  const value = option.value ?? "";
  const label = option.label ?? "";
  if (value && label && value !== label) return `${value} — ${label}`;
  return value || label || "(option)";
}

export function dialogOptionDetails(dialog: DialogSnapshot): string[] {
  const details: string[] = [];
  for (const question of dialog.questions ?? []) {
    if (question.id || question.question) {
      details.push(`${question.id ?? "?"}: ${question.question ?? ""}`.trim());
    }
    for (const option of question.options ?? []) {
      details.push(`  - ${dialogOptionLabel(option)}`);
    }
  }
  if ((dialog.options?.length ?? 0) > 0) {
    details.push(`options: ${(dialog.options ?? []).join(", ")}`);
  }
  if (dialog.placeholder) details.push(`placeholder: ${dialog.placeholder}`);
  return details;
}

export function resolveDialogTarget(
  dialogs: DialogSnapshot[],
  requestedId: string | undefined,
): DialogSnapshot {
  if (requestedId) {
    const match = dialogs.find((dialog) => dialog.id === requestedId);
    if (!match) {
      throw new Error(
        `No pending dialog "${requestedId}"; run 'oppi session dialogs <id>' to list pending dialogs`,
      );
    }
    return match;
  }
  if (dialogs.length > 1) {
    throw new Error(`Multiple pending dialogs (${dialogs.length}); pass --dialog <requestId>`);
  }
  const only = dialogs[0];
  if (!only) {
    throw new Error("No pending dialogs to respond to");
  }
  return only;
}

function dialogResponseMode(flags: Record<string, string>): DialogResponseMode | undefined {
  const modes: DialogResponseMode[] = [];
  if (flags.answers !== undefined) modes.push("answers");
  if (flags.cancel === "true") modes.push("cancel");
  if (flags.confirm === "true") modes.push("confirm");
  if (flags.decline === "true") modes.push("decline");
  if (flags.option !== undefined) modes.push("option");
  if (flags.text !== undefined) modes.push("text");
  if (modes.length > 1) {
    throw new Error(
      `Choose one dialog response flag; received ${modes.map((mode) => `--${mode}`).join(", ")}`,
    );
  }
  return modes[0];
}

// Map operator flags onto the generic extension_ui_response payload {value, confirmed, cancelled}.
// Selection here is driven by the semantic protocol method (ask/select/confirm/input), never by
// concrete tool, extension, or widget names.
export function buildDialogResponse(
  target: DialogSnapshot,
  flags: Record<string, string>,
): Record<string, unknown> {
  const id = target.id?.trim();
  if (!id) throw new Error("Pending dialog is missing a request id");

  const mode = dialogResponseMode(flags);
  const payload: Record<string, unknown> = { type: "extension_ui_response", id };
  if (mode === "cancel") {
    payload.cancelled = true;
    return payload;
  }

  if (target.method === "confirm") {
    if (mode !== "confirm" && mode !== "decline") {
      throw new Error("Confirm dialog requires --confirm, --decline, or --cancel");
    }
    payload.confirmed = mode === "confirm";
    return payload;
  }

  if (target.method === "ask") {
    payload.value = buildAskResponseValue(target, flags, mode);
    return payload;
  }

  if (target.method === "select") {
    if (mode !== "option") throw new Error("Select dialog requires --option or --cancel");
    const value = flags.option ?? "";
    if (!(target.options ?? []).includes(value)) {
      throw new Error(`Unknown option "${value}" for dialog ${id}`);
    }
    payload.value = value;
    return payload;
  }

  if (target.method === "input") {
    if (mode !== "text") throw new Error("Input dialog requires --text or --cancel");
    payload.value = flags.text ?? "";
    return payload;
  }

  throw new Error(`Unsupported pending dialog method: ${target.method ?? "unknown"}`);
}

function buildAskResponseValue(
  target: DialogSnapshot,
  flags: Record<string, string>,
  mode: DialogResponseMode | undefined,
): string {
  const questions = target.questions ?? [];
  if (mode === "answers") {
    const rawAnswers = flags.answers?.trim();
    let parsed: unknown;
    try {
      parsed = JSON.parse(rawAnswers ?? "");
    } catch {
      throw new Error("--answers must be a JSON object mapping question id to answer");
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("--answers must be a JSON object mapping question id to answer");
    }
    validateAskAnswers(target, parsed as Record<string, unknown>);
    return JSON.stringify(parsed);
  }

  if (mode !== "option" && mode !== "text") {
    throw new Error(
      "Answering an ask dialog requires --text/--option, --answers <json>, or --cancel",
    );
  }
  if (questions.length !== 1) {
    throw new Error(
      `Ask dialog has ${questions.length} questions; pass --answers '{"questionId":"answer"}'`,
    );
  }
  const question = questions[0];
  const questionId = question?.id;
  if (!questionId) {
    throw new Error("Ask dialog question is missing an id; pass --answers <json>");
  }
  const value = mode === "option" ? (flags.option ?? "") : (flags.text ?? "");
  if (mode === "option" && !(question.options ?? []).some((option) => option.value === value)) {
    throw new Error(`Unknown option "${value}" for question ${questionId}`);
  }
  if (mode === "text" && target.allowCustom === false) {
    throw new Error(`Question ${questionId} only accepts listed options; use --option`);
  }
  return JSON.stringify({ [questionId]: question.multiSelect ? [value] : value });
}

function validateAskAnswers(target: DialogSnapshot, answers: Record<string, unknown>): void {
  const questions = new Map((target.questions ?? []).map((question) => [question.id, question]));
  for (const [questionId, answer] of Object.entries(answers)) {
    const question = questions.get(questionId);
    if (!question) throw new Error(`Unknown question id in --answers: ${questionId}`);
    const values = Array.isArray(answer) ? answer : [answer];
    if (values.some((value) => typeof value !== "string")) {
      throw new Error(`Answer for ${questionId} must be a string or string array`);
    }
    if (question.multiSelect !== true && Array.isArray(answer)) {
      throw new Error(`Answer for ${questionId} must be a single string`);
    }
    if (question.multiSelect === true && !Array.isArray(answer)) {
      throw new Error(`Answer for ${questionId} must be a string array`);
    }
    if (target.allowCustom === false) {
      const allowed = new Set((question.options ?? []).map((option) => option.value));
      const invalid = (values as string[]).find((value) => !allowed.has(value));
      if (invalid !== undefined) {
        throw new Error(`Unknown option "${invalid}" for question ${questionId}`);
      }
    }
  }
}

export function assertNoCommandError(result: Record<string, unknown>, hintSteering = false): void {
  const messages = Array.isArray(result.messages) ? result.messages : [];
  for (const message of messages) {
    if (
      message &&
      typeof message === "object" &&
      (message as { type?: unknown }).type === "error"
    ) {
      const errorText = (message as { error?: unknown }).error;
      let detail = typeof errorText === "string" ? errorText : "Session command was rejected";
      if (hintSteering && /idle session/i.test(detail)) {
        detail = `${detail}. Retry with --steer to interrupt the current turn or --follow-up to queue after it.`;
      }
      throw new Error(detail);
    }
  }
}
