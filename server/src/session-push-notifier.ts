import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { PushNotification, PushSender } from "./push/push-sender.js";
import type { ProgramStatusSync } from "./program-status.js";
import type { SessionBroadcastEvent } from "./session-broadcast.js";
import type { Storage } from "./storage.js";
import type { Session } from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });
const GENERIC_SESSION_ERROR_REASON = "Open Oppi to review the session error.";

/** Shortest gap between two pushes of the same kind for one session. */
const PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS = 60_000;

const BLOCKED_PRESENTATION = {
  permission: { title: "Needs Approval", body: "Waiting for your approval." },
  question: { title: "Question", body: "Waiting for your answer." },
  auth: { title: "Sign-in Needed", body: "Waiting for you to sign in." },
} as const;

type PushEventContent = Pick<PushNotification, "event" | "kind" | "title" | "body">;

export interface SessionPushNotifierOptions {
  /** True while this paired device holds a live app-event or focused session stream. */
  isDevicePresent: (deviceId: string) => boolean;
  now?: () => number;
}

/**
 * Sends end-to-end-encrypted session alerts through the push relay (protocol/push/spec.md).
 *
 * `ended` and `error` fire on their lifecycle events. `blocked` and `done` fire on program
 * status transitions, at most once a minute per session and kind, and skip each device that
 * is present (holds a live stream, so the app already shows the change or posts its own
 * banner). An open Mac or iPad never silences the phone. `done` is for top-level sessions
 * only; delegated sessions report to their parent, but their `blocked` still pushes.
 * Each device gets its own sealed envelope; a device without a push key gets nothing.
 */
export class SessionPushNotifier {
  private readonly lastProgramPushAt = new Map<string, number>();
  private readonly now: () => number;

  constructor(
    private readonly push: PushSender,
    private readonly storage: Storage,
    private readonly options: SessionPushNotifierOptions,
  ) {
    this.now = options.now ?? Date.now;
  }

  handleSessionEvent(payload: SessionBroadcastEvent): void {
    const content = this.contentForEvent(payload);
    if (!content) {
      return;
    }
    this.deliver(payload.sessionId, content, { skipPresent: false });
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

    if (this.deliver(session.id, this.programStatusContent(current), { skipPresent: true })) {
      // Entries older than the interval no longer throttle anything; keep the map bounded.
      for (const [key, at] of this.lastProgramPushAt) {
        if (now - at >= PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) this.lastProgramPushAt.delete(key);
      }
      this.lastProgramPushAt.set(throttleKey, now);
    }
  }

  private programStatusContent(current: ProgramStatusSync["current"]): PushEventContent {
    if (current.state === "blocked") {
      const kind = current.kind ?? "question";
      return { event: "blocked", kind, ...BLOCKED_PRESENTATION[kind] };
    }
    return { event: "done", title: "Session Done", body: "The run finished." };
  }

  /** Returns whether a push was attempted (some registered device was not skipped). */
  private deliver(
    sessionId: string,
    content: PushEventContent,
    options: { skipPresent: boolean },
  ): boolean {
    const registrations = this.push
      .registrations()
      .filter((entry) => !options.skipPresent || !this.options.isDevicePresent(entry.deviceId));
    if (registrations.length === 0) {
      return false;
    }

    const session = this.storage.getSession(sessionId);
    const notification: PushNotification = {
      ...content,
      sessionId,
      ...(session?.workspaceId ? { workspaceId: session.workspaceId } : {}),
      ...(session?.name ? { subtitle: session.name } : {}),
    };

    for (const registration of registrations) {
      void this.push.send(registration, notification).catch((err: unknown) => {
        log.warn("session_push.send_failed", {
          sessionId,
          event: content.event,
          error: safeErrorMessage(err),
        });
      });
    }
    return true;
  }

  private contentForEvent(payload: SessionBroadcastEvent): PushEventContent | null {
    const { event } = payload;

    switch (event.type) {
      case "session_ended":
        return {
          event: "ended",
          title: "Session Ended",
          body: event.reason || "The session ended.",
        };
      case "error":
        if (event.error.startsWith("Retrying (")) {
          return null;
        }
        return { event: "error", title: "Session Error", body: GENERIC_SESSION_ERROR_REASON };
      default:
        return null;
    }
  }
}
