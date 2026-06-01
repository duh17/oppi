import type { ServerMessage, Session } from "./types.js";

export interface PendingUIRequestProvider {
  getActiveSessionIds(): Set<string>;
  getActiveSession(sessionId: string): Session | undefined;
  getPendingAskMessage(sessionId: string): ServerMessage | undefined;
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
  const askCount = isPendingAskMessage(provider.getPendingAskMessage(sessionId)) ? 1 : 0;
  const dialogCount = provider
    .getPendingUIRequestMessages(sessionId)
    .filter((message) => message.type === "extension_ui_request").length;
  return askCount + dialogCount;
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

    const message = provider.getPendingAskMessage(sessionId);
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

  return asks;
}
