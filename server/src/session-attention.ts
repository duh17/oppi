import type { ServerMessage, Session } from "./types.js";

export interface PendingUIRequestProvider {
  getActiveSessionIds(): Set<string>;
  getActiveSession(sessionId: string): Session | undefined;
  getPendingUIRequestMessages(sessionId: string): ServerMessage[];
}

export function isPendingAskMessage(
  message: ServerMessage | undefined,
): message is Extract<ServerMessage, { type: "extension_ui_request" }> {
  return (
    message?.type === "extension_ui_request" &&
    message.method === "ask" &&
    Array.isArray(message.questions) &&
    message.questions.length > 0
  );
}

export function pendingBlockingUIRequestCount(
  provider: PendingUIRequestProvider,
  sessionId: string,
): number {
  return provider.getPendingUIRequestMessages(sessionId).filter(isPendingUserReplyRequest).length;
}

export function hasPendingBlockingUIRequest(
  provider: PendingUIRequestProvider,
  sessionId: string,
): boolean {
  return pendingBlockingUIRequestCount(provider, sessionId) > 0;
}

export function pendingAskSnapshots(
  provider: PendingUIRequestProvider,
  workspaceId: string,
): Array<Record<string, unknown>> {
  const asks: Array<Record<string, unknown>> = [];
  const seenRequestIds = new Set<string>();

  for (const sessionId of provider.getActiveSessionIds()) {
    const session = provider.getActiveSession(sessionId);
    if (!session || session.workspaceId !== workspaceId) {
      continue;
    }

    for (const message of provider.getPendingUIRequestMessages(sessionId)) {
      if (!isPendingAskMessage(message) || seenRequestIds.has(message.id)) {
        continue;
      }
      seenRequestIds.add(message.id);

      asks.push({
        id: message.id,
        sessionId: message.sessionId,
        workspaceId,
        questions: message.questions,
        allowCustom: message.allowCustom ?? true,
        ...(message.timeout !== undefined ? { timeout: message.timeout } : {}),
        ...(message.timeoutAt !== undefined ? { timeoutAt: message.timeoutAt } : {}),
      });
    }
  }

  return asks;
}

/**
 * Summarize pending, user-reply extension UI dialogs for a single session into
 * transport-neutral records. Kept deliberately extension-agnostic: it reads only
 * semantic protocol metadata carried by extension_ui_request and never branches on
 * concrete tool, extension, or widget names.
 */
export function pendingDialogSnapshots(messages: ServerMessage[]): Array<Record<string, unknown>> {
  const dialogs: Array<Record<string, unknown>> = [];
  const seenRequestIds = new Set<string>();

  for (const message of messages) {
    if (message.type !== "extension_ui_request" || !isPendingUserReplyRequest(message)) {
      continue;
    }
    if (seenRequestIds.has(message.id)) {
      continue;
    }
    seenRequestIds.add(message.id);
    dialogs.push(dialogSnapshotFromRequest(message));
  }

  return dialogs;
}

function dialogSnapshotFromRequest(
  message: Extract<ServerMessage, { type: "extension_ui_request" }>,
): Record<string, unknown> {
  return {
    id: message.id,
    method: message.method,
    ...(message.title !== undefined ? { title: message.title } : {}),
    ...(message.message !== undefined ? { message: message.message } : {}),
    ...(message.placeholder !== undefined ? { placeholder: message.placeholder } : {}),
    ...(message.prefill !== undefined ? { prefill: message.prefill } : {}),
    ...(message.options !== undefined ? { options: message.options } : {}),
    ...(message.questions !== undefined ? { questions: message.questions } : {}),
    ...(message.allowCustom !== undefined ? { allowCustom: message.allowCustom } : {}),
    ...(message.timeout !== undefined ? { timeout: message.timeout } : {}),
    ...(message.timeoutAt !== undefined ? { timeoutAt: message.timeoutAt } : {}),
    ...(message.extensionScopeId !== undefined
      ? { extensionScopeId: message.extensionScopeId }
      : {}),
    ...(message.extensionDisplayName !== undefined
      ? { extensionDisplayName: message.extensionDisplayName }
      : {}),
  };
}

export function isPendingUserReplyRequest(message: {
  type?: string;
  method?: string;
  questions?: unknown;
  options?: unknown;
}): boolean {
  if (message.type !== "extension_ui_request") {
    return false;
  }

  switch (message.method) {
    case "ask":
      return Array.isArray(message.questions) && message.questions.length > 0;
    case "select":
      return Array.isArray(message.options) && message.options.length > 0;
    case "confirm":
    case "input":
      return true;
    default:
      return false;
  }
}
