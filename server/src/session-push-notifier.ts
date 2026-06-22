import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { PushClient, SessionEventPushPayload } from "./push.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import type { Storage } from "./storage.js";

const log = createLogger({ base: { component: "session_push_notifier" } });
const GENERIC_SESSION_ERROR_REASON = "Open Oppi to review the session error.";

/** Sends regular APNs alerts for terminal or error session events. */
export class SessionPushNotifier {
  constructor(
    private readonly push: PushClient,
    private readonly storage: Storage,
  ) {}

  handleSessionEvent(payload: SessionBroadcastEvent): void {
    const notification = this.notificationForEvent(payload);
    if (!notification) {
      return;
    }

    const tokens = this.storage.getPushDeviceTokens();
    if (tokens.length === 0) {
      return;
    }

    const sessionName = this.storage.getSession(notification.sessionId)?.name;
    const pushPayload = { ...notification, sessionName };

    for (const token of tokens) {
      void this.push.sendSessionEventPush(token, pushPayload).catch((err: unknown) => {
        log.warn("session_push.send_failed", {
          sessionId: notification.sessionId,
          event: notification.event,
          error: safeErrorMessage(err),
        });
      });
    }
  }

  private notificationForEvent(payload: SessionBroadcastEvent): SessionEventPushPayload | null {
    const { event, sessionId } = payload;

    switch (event.type) {
      case "session_ended":
        return {
          sessionId,
          event: "ended",
          reason: event.reason || "Session ended",
        };
      case "error":
        if (event.error.startsWith("Retrying (")) {
          return null;
        }
        return {
          sessionId,
          event: "error",
          reason: GENERIC_SESSION_ERROR_REASON,
        };
      default:
        return null;
    }
  }
}
