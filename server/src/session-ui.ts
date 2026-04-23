import type {
  ExtensionUIRequest,
  PendingAskState,
  SessionEventProcessor,
} from "./session-events.js";
import type { SdkBackend } from "./sdk-backend.js";
import type { Session } from "./types.js";

/** Extension UI response sent to pi */
export interface ExtensionUIResponse {
  type: "extension_ui_response";
  id: string;
  value?: string;
  confirmed?: boolean;
  cancelled?: boolean;
}

export interface SessionUIState {
  session: Session;
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

    const req = active.pendingUIRequests.get(response.id);
    if (!req) {
      return false;
    }

    if (req.method === "ask") {
      this.deps.eventProcessor.completeAskRequest(active, !!response.cancelled);
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
