import {
  NOTIFY_BODY_MAX,
  NOTIFY_TITLE_MAX,
  type NotifyInput,
  type NotifyOutcome,
} from "../extensions/durable/notify/contract.js";
import { safeErrorMessage } from "./log-utils.js";
import { createLogger } from "./logger.js";
import { fitPushBody } from "./push/envelope.js";
import type { PushNotification, PushSender } from "./push/push-sender.js";
import type { ProgramStatusSync } from "./program-status.js";
import type { Storage } from "./storage.js";
import type { ProgramStatusKind, PushRegistration, Session, SessionPushEvent } from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });

/** Shortest gap between two pushes of the same alert for one session. */
const SESSION_PUSH_MIN_INTERVAL_MS = 60_000;

const BLOCKED_PRESENTATION = {
  permission: { title: "Needs Approval", body: "Waiting for your approval." },
  question: { title: "Question", body: "Waiting for your answer." },
  auth: { title: "Sign-in Needed", body: "Waiting for you to sign in." },
} as const;

/** Fixed text; never the error itself. */
const ERROR_PRESENTATION = { title: "Session Failed", body: "Stopped with an error." } as const;

type PushEventContent = {
  event: SessionPushEvent;
  kind?: ProgramStatusKind;
  title: string;
  body: string;
};

/** What a session runtime needs to offer the agent `notify` tool. */
export interface SessionNotifyPort {
  /** Whether `sessionId` is offered the tool now; runtimes ask when a session starts or reloads. */
  offersNotify(sessionId: string): boolean;
  notify(sessionId: string, input: NotifyInput): Promise<NotifyOutcome>;
}

export interface SessionPushNotifierOptions {
  /** True while this paired device holds a live app-event or focused session stream. */
  isDevicePresent: (deviceId: string) => boolean;
  now?: () => number;
}

/**
 * The one owner of session alerts sent through the push relay (protocol/push/spec.md §5).
 * Pairing alerts are security signals and stay with device pairing.
 *
 * Automatic, from program status (OSC 7501) transitions:
 * - **Needs you** (`blocked`): any session starts waiting on an approval, question, or sign-in.
 *   Skips each device that is present: the open app shows the dialog or posts its own banner.
 * - **Failed** (`error`): a top-level session's run stops with an error, after any automatic
 *   retries. A failed model call that a retry recovers never leaves `working`. Delegated
 *   sessions report to their parent.
 *
 * Deliberate, from the agent (`notify` tool): a top-level session tells the user there is
 * something to read. Offered only while some device can receive it.
 *
 * Failed and agent alerts go to every registered device, present or not: the app hides one
 * only while that session's chat is on screen. Each alert pushes at most once a minute per
 * session. Each device gets its own sealed envelope; a device without a push key gets nothing.
 */
export class SessionPushNotifier implements SessionNotifyPort {
  private readonly lastPushAt = new Map<string, number>();
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
    let content: PushEventContent;
    let registrations: PushRegistration[];
    if (current.state === "blocked") {
      const kind = current.kind ?? "question";
      content = { event: "blocked", kind, ...BLOCKED_PRESENTATION[kind] };
      registrations = this.push
        .registrations()
        .filter((entry) => !this.options.isDevicePresent(entry.deviceId));
    } else if (
      current.state === "error" &&
      (previous.state === "working" || previous.state === "blocked") &&
      !session.launch?.parentSessionId
    ) {
      content = { event: "error", ...ERROR_PRESENTATION };
      registrations = this.push.registrations();
    } else {
      return;
    }
    if (registrations.length === 0 || this.throttledFor(session.id, content.event) > 0) return;
    this.startThrottle(session.id, content.event);
    for (const registration of registrations) {
      void this.push.send(registration, this.notification(session.id, content)).catch((err) => {
        log.warn("session_push.send_failed", {
          sessionId: session.id,
          event: content.event,
          error: safeErrorMessage(err),
        });
      });
    }
  }

  /** Top-level sessions, while some device registered for pushes. */
  offersNotify(sessionId: string): boolean {
    return (
      this.push.registrations().length > 0 &&
      !this.storage.getSession(sessionId)?.launch?.parentSessionId
    );
  }

  async notify(sessionId: string, input: NotifyInput): Promise<NotifyOutcome> {
    if (!this.offersNotify(sessionId)) return { status: "off" };
    const wait = this.throttledFor(sessionId, "notify");
    if (wait > 0) return { status: "throttled", retryAfterSeconds: Math.ceil(wait / 1000) };
    const title = clip(oneLine(input.title), NOTIFY_TITLE_MAX, NOTIFY_TITLE_MAX_BYTES);
    const cleaned = input.body.replace(CONTROL_CHARACTERS, "").trim();
    const written = clip(cleaned, NOTIFY_BODY_MAX);
    if (!title || !written) throw new Error("notify needs a title and a body");
    // The alert always names its session, so the body gives way, never the name: fit it here
    // rather than let the envelope drop the subtitle first (spec §2.4).
    const session = this.storage.getSession(sessionId);
    const subtitle = session?.name
      ? clip(oneLine(session.name), NOTIFY_SUBTITLE_MAX, NOTIFY_SUBTITLE_MAX_BYTES)
      : undefined;
    const fields = {
      event: "notify" as const,
      sessionId,
      ...(session?.workspaceId ? { workspaceId: session.workspaceId } : {}),
      title,
      ...(subtitle ? { subtitle } : {}),
    };
    const body = fitPushBody(fields, written, "");
    const notification: PushNotification = { ...fields, body };
    // Held while sending so a parallel call waits its turn; given back when nothing went out.
    const started = this.startThrottle(sessionId, "notify");
    const results = await Promise.all(
      this.push.registrations().map((registration) =>
        this.push.send(registration, notification).catch((err: unknown) => {
          log.warn("session_push.send_failed", {
            sessionId,
            event: "notify",
            error: safeErrorMessage(err),
          });
          return null;
        }),
      ),
    );
    const devices = results.filter((result) => result?.status === "delivered").length;
    if (devices === 0) {
      // Only this call's hold: a later call may have taken a new one meanwhile.
      if (this.lastPushAt.get(`${sessionId}:notify`) === started)
        this.lastPushAt.delete(`${sessionId}:notify`);
      return { status: "not_delivered" };
    }
    return body === cleaned
      ? { status: "sent", devices }
      : { status: "sent", devices, shortened: true };
  }

  /** Milliseconds until `event` may push again for `sessionId`; 0 when it may now. */
  private throttledFor(sessionId: string, event: SessionPushEvent): number {
    const last = this.lastPushAt.get(`${sessionId}:${event}`);
    return last === undefined ? 0 : Math.max(0, last + SESSION_PUSH_MIN_INTERVAL_MS - this.now());
  }

  /** Returns the time it starts at. */
  private startThrottle(sessionId: string, event: SessionPushEvent): number {
    const now = this.now();
    // Entries older than the interval no longer throttle anything; keep the map bounded.
    for (const [key, at] of this.lastPushAt) {
      if (now - at >= SESSION_PUSH_MIN_INTERVAL_MS) this.lastPushAt.delete(key);
    }
    this.lastPushAt.set(`${sessionId}:${event}`, now);
    return now;
  }

  private notification(sessionId: string, content: PushEventContent): PushNotification {
    const session = this.storage.getSession(sessionId);
    return {
      ...content,
      sessionId,
      ...(session?.workspaceId ? { workspaceId: session.workspaceId } : {}),
      ...(session?.name ? { subtitle: session.name } : {}),
    };
  }
}

/** Control characters other than tab and newline; JSON would escape each into six bytes. */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b-\u001f\u007f]/g;

/** A notification title is one line. */
function oneLine(text: string): string {
  return text.replace(CONTROL_CHARACTERS, " ").replace(/\s+/g, " ").trim();
}

/**
 * Byte caps on the JSON-encoded title and session name. With the fixed fields of a `notify`
 * plaintext (about 170 bytes with UUID ids), they leave at least 80 bytes for the body, so the
 * title and name always fit and only the body is ever shortened.
 */
const NOTIFY_TITLE_MAX_BYTES = 160;
const NOTIFY_SUBTITLE_MAX = 40;
const NOTIFY_SUBTITLE_MAX_BYTES = 96;

/**
 * The longest prefix within `maxCodePoints` whose JSON string encoding is at most `maxBytes`.
 * The tool schema bounds the agent's fields too; this holds for any caller.
 */
function clip(text: string, maxCodePoints: number, maxBytes = Infinity): string {
  const points = Array.from(text).slice(0, maxCodePoints);
  const jsonBytes = (value: string) => Buffer.byteLength(JSON.stringify(value), "utf8") - 2;
  while (points.length > 0 && jsonBytes(points.join("")) > maxBytes) points.pop();
  return points.join("").trim();
}
