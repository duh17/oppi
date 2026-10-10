import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { PushClient, SessionEventPushPayload } from "./push.js";
import type { ProgramStatusSync } from "./program-status.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });
const GENERIC_SESSION_ERROR_REASON = "Open Oppi to review the session error.";

/** Shortest gap between two pushes of the same kind for one session. */
const PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS = 60_000;

const BLOCKED_REASON = {
  permission: "Waiting for your approval.",
  question: "Waiting for your answer.",
  auth: "Waiting for you to sign in.",
} as const;
const DONE_REASON = "The run finished.";

export interface SessionPushNotifierOptions {
  /** True while this paired device holds a live app-event or focused session stream. */
  isDevicePresent: (deviceId: string) => boolean;
  now?: () => number;
}

/**
 * Sends regular APNs alerts for session events.
 *
 * `ended` and `error` fire on their lifecycle events. `blocked` and `done` fire on program
 * status transitions, at most once a minute per session and kind, and skip each device that
 * is present (holds a live stream, so the app already shows the change or posts its own
 * banner). An open Mac or iPad never silences the phone. `done` is for top-level sessions
 * only; delegated sessions report to their parent, but their `blocked` still pushes.
 * The body is fixed text: a lock-screen push never carries a dialog title, a question, an
 * error, or the session name (the subtitle is the only session text).
 */
export class SessionPushNotifier {
  private readonly lastProgramPushAt = new Map<string, number>();
  private readonly now: () => number;

  constructor(
    private readonly push: PushClient,
    private readonly storage: Storage,
    private readonly options: SessionPushNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  handleSessionEvent(payload: SessionBroadcastEvent): void {
    const notification = this.notificationForEvent(payload);
    if (!notification) {
      return;
    }
    this.deliver(notification, { skipPresent: false });
  }

  /** Push on entering `blocked` or `done`. Same-state updates (message, kind) never push. */
  handleProgramStatusChange(session: Session, change: ProgramStatusSync): void {
    const { previous, current } = change;
    if (!previous || previous.state === current.state) return;
    if (current.state !== "blocked" && current.state !== "done") return;
    if (current.state === "done" && session.launch?.parentSessionId) return;

    const throttleKey = `${session.id}:${current.state}`;
    const now = this.now();
    const last = this.lastProgramPushAt.get(throttleKey);
    if (last !== undefined && now - last < PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) return;

    if (this.deliver(this.programStatusNotification(session.id, current), { skipPresent: true })) {
      // Entries older than the interval no longer throttle anything; keep the map bounded.
      for (const [key, at] of this.lastProgramPushAt) {
        if (now - at >= PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) this.lastProgramPushAt.delete(key);
      }
      this.lastProgramPushAt.set(throttleKey, now);
    }
  }

  private programStatusNotification(
    sessionId: string,
    current: ProgramStatusSync["current"],
  ): SessionEventPushPayload {
    if (current.state === "blocked") {
      const kind = current.kind ?? "question";
      return { sessionId, event: "blocked", kind, reason: BLOCKED_REASON[kind] };
    }
    return { sessionId, event: "done", reason: DONE_REASON };
  }

  /** Returns whether a push was attempted (some device had a token and was not skipped). */
  private deliver(
    notification: SessionEventPushPayload,
    options: { skipPresent: boolean },
  ): boolean {
    const tokens = this.storage
      .getPushDeviceTokens("apns")
      .filter((entry) => !options.skipPresent || !this.options.isDevicePresent(entry.deviceId));
    if (tokens.length === 0) {
      return false;
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
    return true;
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
