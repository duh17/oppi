import type { ExtensionUIRequest, PendingAskState, SessionEventProcessor } from "./session-events.js";
import type { SdkBackend } from "./sdk-backend.js";

/** Extension UI response sent to pi */
export interface ExtensionUIResponse {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

export interface SessionUIState {
  pendingUIRequests: Map<string, ExtensionUIRequest>;
  sdkBackend: SdkBackend;
  pendingAsk?: PendingAskState;
}

export interface SessionUICoordinatorDeps {
  getActiveSession: (key: string) => SessionUIState | undefined;
  eventProcessor: SessionEventProcessor;
}

export class SessionUICoordinator {
  constructor(private readonly deps: SessionUICoordinatorDeps) {}

  respondToUIRequest(key: string, response: ExtensionUIResponse): boolean {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      return false;
    }

    // Ask interception: iOS responded to the synthetic ask request.
    // Parse answers and resolve deferred extension select() calls.
    if (active.pendingAsk?.requestId === response.id) {
      active.pendingUIRequests.delete(response.id);

      const cancelled = !!response.cancelled;
      let answers: Record<string, string | string[]> = {};
      if (!cancelled && response.value) {
        try {
          answers = JSON.parse(response.value);
        } catch {
          // Invalid JSON — treat as empty
        }
      }

      this.deps.eventProcessor.resolveAskDeferred(
        key,
        active as any, // structural subset
        answers,
        cancelled,
      );
      return true;
    }

    const req = active.pendingUIRequests.get(response.id);
    if (!req) {
      return false;
    }

    active.pendingUIRequests.delete(response.id);
    active.sdkBackend.respondToExtensionUIRequest(response);
    return true;
  }

  hasPendingUIRequest(key: string, requestId: string): boolean {
    const active = this.deps.getActiveSession(key);
    return active?.pendingUIRequests.has(requestId) ?? false;
  }
}
