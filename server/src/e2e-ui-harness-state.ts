import type { ClientMessage } from "./types.js";

const MAX_RECORDED_RESPONSES_PER_SESSION = 50;

export interface RecordedE2EUIResponse {
  type: "extension_ui_response";
  sessionId: string;
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
  requestId?: string;
  receivedAt: number;
}

const responsesBySession = new Map<string, RecordedE2EUIResponse[]>();
const syntheticRequestsBySession = new Map<string, Set<string>>();

export function e2eUIHarnessEnabled(): boolean {
  return process.env.OPPI_E2E_UI_HARNESS === "1";
}

export function recordSyntheticE2EUIRequest(sessionId: string, id: string): void {
  if (!e2eUIHarnessEnabled()) {
    return;
  }
  const ids = syntheticRequestsBySession.get(sessionId) ?? new Set<string>();
  ids.add(id);
  syntheticRequestsBySession.set(sessionId, ids);
}

export function consumeSyntheticE2EUIRequest(sessionId: string, id: string): boolean {
  if (!e2eUIHarnessEnabled()) {
    return false;
  }
  const ids = syntheticRequestsBySession.get(sessionId);
  if (!ids?.has(id)) {
    return false;
  }
  ids.delete(id);
  if (ids.size === 0) {
    syntheticRequestsBySession.delete(sessionId);
  }
  return true;
}

export function recordE2EUIResponse(sessionId: string, msg: ClientMessage): void {
  if (!e2eUIHarnessEnabled() || msg.type !== "extension_ui_response") {
    return;
  }

  const recorded: RecordedE2EUIResponse = {
    type: "extension_ui_response",
    sessionId,
    id: msg.id,
    receivedAt: Date.now(),
  };
  if (msg.value !== undefined) recorded.value = msg.value;
  if (msg.confirmed !== undefined) recorded.confirmed = msg.confirmed;
  if (msg.cancelled !== undefined) recorded.cancelled = msg.cancelled;
  if (msg.requestId !== undefined) recorded.requestId = msg.requestId;

  const responses = responsesBySession.get(sessionId) ?? [];
  responses.push(recorded);
  if (responses.length > MAX_RECORDED_RESPONSES_PER_SESSION) {
    responses.splice(0, responses.length - MAX_RECORDED_RESPONSES_PER_SESSION);
  }
  responsesBySession.set(sessionId, responses);
}

export function getRecordedE2EUIResponses(sessionId: string): RecordedE2EUIResponse[] {
  if (!e2eUIHarnessEnabled()) {
    return [];
  }
  return [...(responsesBySession.get(sessionId) ?? [])];
}

export function clearRecordedE2EUIResponses(sessionId: string): void {
  responsesBySession.delete(sessionId);
  syntheticRequestsBySession.delete(sessionId);
}
