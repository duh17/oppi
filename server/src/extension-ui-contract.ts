import type { AskQuestion, ServerMessage } from "./types.js";

export const EXTENSION_UI_DIALOG_METHODS = new Set(["ask", "select", "confirm", "input", "editor"]);

export const EXTENSION_UI_FIRE_AND_FORGET_METHODS = new Set([
  "notify",
  "setStatus",
  "setWidget",
  "setTitle",
  "set_editor_text",
]);

export interface ExtensionUIProtocolRequest {
  id: string;
  method: string;
  title?: string;
  options?: string[];
  message?: string;
  placeholder?: string;
  prefill?: string;
  notifyType?: "info" | "warning" | "error";
  statusKey?: string;
  statusText?: string;
  widgetKey?: string;
  widgetLines?: string[];
  widgetPlacement?: string;
  text?: string;
  timeout?: number;
  timeoutAt?: number;
  questions?: AskQuestion[];
  allowCustom?: boolean;
}

export function isExtensionUIFireAndForgetMethod(method: string): boolean {
  return EXTENSION_UI_FIRE_AND_FORGET_METHODS.has(method);
}

export function buildExtensionUINotificationMessage(
  req: ExtensionUIProtocolRequest,
  overrides: { statusText?: string } = {},
): ServerMessage {
  return {
    type: "extension_ui_notification",
    method: req.method,
    message: req.message,
    notifyType: req.notifyType,
    statusKey: req.statusKey,
    statusText: Object.hasOwn(overrides, "statusText") ? overrides.statusText : req.statusText,
    title: req.title,
    text: req.text,
    widgetKey: req.widgetKey,
    widgetLines: req.widgetLines,
    widgetPlacement: req.widgetPlacement,
  };
}

export function buildExtensionUIRequestMessage(
  sessionId: string,
  req: ExtensionUIProtocolRequest,
): ServerMessage {
  if (req.method === "ask") {
    return {
      type: "extension_ui_request",
      id: req.id,
      sessionId,
      method: req.method,
      questions: req.questions,
      allowCustom: req.allowCustom,
      timeout: req.timeout,
      timeoutAt: req.timeoutAt,
    };
  }

  return {
    type: "extension_ui_request",
    id: req.id,
    sessionId,
    method: req.method,
    title: req.title,
    options: req.options,
    message: req.message,
    placeholder: req.placeholder,
    prefill: req.prefill,
    timeout: req.timeout,
    timeoutAt: req.timeoutAt,
  };
}

export function buildExtensionUISettledMessage(sessionId: string, id: string): ServerMessage {
  return {
    type: "extension_ui_settled",
    id,
    sessionId,
  };
}
