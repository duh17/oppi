import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import type { PushNotification, PushSender } from "./push/push-sender.js";
import type { ProgramStatusSync } from "./program-status.js";
import type { Storage } from "./storage.js";
import type { ProgramStatusKind, Session, SessionPushEvent } from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });

/** Shortest gap between two pushes of the same kind for one session. */
const PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS = 60_000;

const BLOCKED_PRESENTATION = {
  permission: { title: "Needs Approval", body: "Waiting for your approval." },
  question: { title: "Question", body: "Waiting for your answer." },
  auth: { title: "Sign-in Needed", body: "Waiting for you to sign in." },
} as const;

/** Body of the Stopped alert by how the run ended. Fixed text; never the error itself. */
const STOPPED_BODY = {
  done: "Finished.",
  error: "Stopped with an error.",
  idle: "Stopped before finishing.",
} as const;

type PushEventContent = {
  event: SessionPushEvent;
  kind?: ProgramStatusKind;
  title: string;
  body: string;
};

export interface SessionPushNotifierOptions {
  /** True while this paired device holds a live app-event or focused session stream. */
  isDevicePresent: (deviceId: string) => boolean;
  /** True while a session this one launched is still starting or working. */
  hasWorkingChild: (sessionId: string) => boolean;
  now?: () => number;
}

/**
 * Sends end-to-end-encrypted session alerts through the push relay (protocol/push/spec.md).
 *
 * Two alerts, both program status transitions (OSC 7501 states):
 * - **Needs you** (`blocked`): any session starts waiting on an approval, question, or sign-in.
 * - **Stopped** (`done` push): a top-level session stops working, whether it finished
 *   (`done`), failed after any automatic retries (`error`), or was cancelled (`idle`), and none
 *   of its children still works. Delegated sessions report to their parent, and a lead's
 *   turns between child results are not the end of its work. A failed model call that a retry
 *   recovers never leaves `working`, so it pushes nothing.
 * Both skip each device that is present (holds a live stream, so the app already shows the
 * change or posts its own banner) and push at most once a minute per session and alert. An
 * open Mac or iPad never silences the phone. A session ending pushes nothing.
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

  /** Same-state updates (message, kind) and a first-seen status never push. */
  handleProgramStatusChange(session: Session, change: ProgramStatusSync): void {
    const { previous, current } = change;
    if (!previous || previous.state === current.state) return;
    const content = this.alertFor(session, previous.state, current);
    if (!content) return;

    const throttleKey = `${session.id}:${content.event}`;
    const now = this.now();
    const last = this.lastProgramPushAt.get(throttleKey);
    if (last !== undefined && now - last < PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) return;

    if (this.deliver(session.id, content)) {
      // Entries older than the interval no longer throttle anything; keep the map bounded.
      for (const [key, at] of this.lastProgramPushAt) {
        if (now - at >= PROGRAM_STATUS_PUSH_MIN_INTERVAL_MS) this.lastProgramPushAt.delete(key);
      }
      this.lastProgramPushAt.set(throttleKey, now);
    }
  }

  private alertFor(
    session: Session,
    previousState: ProgramStatusSync["current"]["state"],
    current: ProgramStatusSync["current"],
  ): PushEventContent | null {
    if (current.state === "blocked") {
      const kind = current.kind ?? "question";
      return { event: "blocked", kind, ...BLOCKED_PRESENTATION[kind] };
    }
    const body = STOPPED_BODY[current.state as keyof typeof STOPPED_BODY];
    if (
      !body ||
      (previousState !== "working" && previousState !== "blocked") ||
      session.launch?.parentSessionId ||
      this.options.hasWorkingChild(session.id)
    ) {
      return null;
    }
    return { event: "done", title: "Session Done", body };
  }

  /** Returns whether a push was attempted (some registered device was not skipped). */
  private deliver(sessionId: string, content: PushEventContent): boolean {
    const registrations = this.push
      .registrations()
      .filter((entry) => !this.options.isDevicePresent(entry.deviceId));
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
}
