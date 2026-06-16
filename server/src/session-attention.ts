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

function isPendingUserReplyRequest(message: ServerMessage): boolean {
  if (message.type !== "extension_ui_request") {
    return false;
  }

  switch (message.method) {
    case "ask":
      return isPendingAskMessage(message);
    case "select":
      return Array.isArray(message.options) && message.options.length > 0;
    case "confirm":
    case "input":
      return true;
    default:
      return false;
  }
}
