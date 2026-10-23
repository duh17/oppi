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
import type {
  ProgramStatus,
  ProgramStatusKind,
  PushRegistration,
  Session,
  SessionPushEvent,
} from "./types.js";

const log = createLogger({ base: { component: "session_push_notifier" } });

/** Shortest gap between two pushes of the same alert for one session. */
const SESSION_PUSH_MIN_INTERVAL_MS = 60_000;

/** A session blocked this recently still waits on the user: a device that just left is told. */
const BLOCKED_CATCH_UP_MS = 120_000;

/** A Needs you that no relay accepted is tried once more after this long. */
const BLOCKED_RETRY_DELAY_MS = 60_000;

/** Titles, and the body when the status names nothing to show. */
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
  /** Sessions with a live runtime; their `programStatus` is current. */
  liveSessions: () => Session[];
  /**
   * Whether the app posts its own local alert for what `sessionId` waits on while it runs in
   * the background: true for the dialogs it turns into an ask (`ask`, `select`, `confirm`,
   * `input`), false for an `editor` dialog or when nothing is pending.
   */
  appAlertsFor: (sessionId: string) => boolean;
  now?: () => number;
}

/**
 * The one owner of session alerts sent through the push relay (protocol/push/spec.md §5).
 * Pairing alerts are security signals and stay with device pairing.
 *
 * Automatic, from program status (OSC 7501) transitions:
 * - **Needs you** (`blocked`): any session starts waiting on an approval, question, or sign-in.
 *   The body is what it waits on (the status message: a dialog title or an `ask`'s first
 *   question), else fixed text. Skips each device that is present: the open app shows the
 *   dialog or posts its own banner.
 * - **Failed** (`error`): a top-level session's run stops with an error, after any automatic
 *   retries. A failed model call that a retry recovers never leaves `working`. Delegated
 *   sessions report to their parent.
 *
 * Deliberate, from the agent (`notify` tool): a top-level session tells the user there is
 * something to read. Offered only while some device can receive it.
 *
 * A device that stops being present (`deviceLeft`) gets the Needs you of each session that
 * became blocked in the last two minutes, unless it was already told: an app suspended with
 * its sockets still open stays present until the ping timeout, and a session that blocked in
 * that window would otherwise wait unannounced. A running, backgrounded app posts its own
 * local alert for the dialogs it shows as an ask (`appAlertsFor`), so for those the push goes
 * out only when the connection dropped and the session blocked after the last frame the
 * device sent; for any other dialog (an `editor`) it goes out on any leave. If no relay
 * accepted a Needs you, it is tried once more after a minute while the session is still
 * blocked in the same stretch.
 *
 * Failed and agent alerts go to every registered device, present or not: the app hides one
 * only while that session's chat is on screen. Each alert pushes at most once a minute per
 * session. Each device gets its own sealed envelope; a device without a push key, or that did
 * not list the event, gets nothing. Every session alert names its session (subtitle): the
 * name is capped and the body shortened to fit, never the other way round.
 */
export class SessionPushNotifier implements SessionNotifyPort {
  private readonly lastPushAt = new Map<string, number>();
  /**
   * The last Needs you sent to each device, per session (`sessionId:deviceId`), with the
   * `since` of the blocked stretch it announced. The per-session throttle cannot say which
   * devices it let through; this is what keeps `deviceLeft` from alerting twice.
   */
  private readonly blockedAlerts = new Map<string, { at: number; since: number }>();
  private readonly retryTimers = new Map<string, ReturnType<typeof setTimeout>>();
  private stopped = false;
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
      content = blockedContent(current);
      registrations = this.push
        .registrations("blocked")
        .filter(
          (entry) =>
            !this.options.isDevicePresent(entry.deviceId) &&
            !this.alertedRecently(session.id, entry.deviceId),
        );
    } else if (
      current.state === "error" &&
      (previous.state === "working" || previous.state === "blocked") &&
      !session.launch?.parentSessionId
    ) {
      content = { event: "error", ...ERROR_PRESENTATION };
      registrations = this.push.registrations("error");
    } else {
      return;
    }
    if (registrations.length === 0 || this.throttledFor(session.id, content.event) > 0) return;
    this.startThrottle(session.id, content.event);
    const notification = this.notification(session.id, content);
    if (content.event === "blocked") {
      void this.sendBlocked(session.id, current.since, notification, registrations, true);
    } else {
      void this.deliver(session.id, notification, registrations);
    }
  }

  /**
   * `deviceId`'s last stream ended. `dropped`: the connection broke or timed out, rather than
   * the app closing it. `heardAt` is when the device last sent a frame. Tell it about each
   * live session that became blocked within the last two minutes, unless it already got that
   * stretch's alert or any Needs you for the session in the last minute (the per-session
   * throttle's interval, kept per device). Where the app posts its own alert for what the
   * session waits on (`appAlertsFor`), the push goes out only if the stream dropped and the
   * session blocked after `heardAt`: otherwise the app already told the person.
   */
  deviceLeft(deviceId: string, leave: { heardAt: number; dropped: boolean }): void {
    if (this.stopped) return;
    const registration = this.push.registrations("blocked").find((r) => r.deviceId === deviceId);
    if (!registration) return;
    const now = this.now();
    for (const session of this.options.liveSessions()) {
      const status = session.programStatus;
      if (status?.state !== "blocked" || now - status.since > BLOCKED_CATCH_UP_MS) continue;
      if (
        this.options.appAlertsFor(session.id) &&
        (!leave.dropped || status.since <= leave.heardAt)
      ) {
        continue;
      }
      const alerted = this.blockedAlerts.get(`${session.id}:${deviceId}`);
      if (
        alerted &&
        (alerted.since === status.since || this.alertedRecently(session.id, deviceId))
      ) {
        continue;
      }
      const notification = this.notification(session.id, blockedContent(status));
      void this.sendBlocked(session.id, status.since, notification, [registration], true);
    }
  }

  /** True when a Needs you for this session reached the device in the last minute. */
  private alertedRecently(sessionId: string, deviceId: string): boolean {
    const alerted = this.blockedAlerts.get(`${sessionId}:${deviceId}`);
    return alerted !== undefined && this.now() - alerted.at < SESSION_PUSH_MIN_INTERVAL_MS;
  }

  /** Clears pending retries. After this, `deviceLeft` and retries send nothing. */
  stop(): void {
    this.stopped = true;
    for (const timer of this.retryTimers.values()) clearTimeout(timer);
    this.retryTimers.clear();
  }

  /** Never rejects: a failed send is logged and counts as no result. */
  private deliver(
    sessionId: string,
    notification: PushNotification,
    registrations: PushRegistration[],
  ): Promise<Awaited<ReturnType<PushSender["send"]>>[]> {
    return Promise.all(
      registrations.map((registration) =>
        this.push.send(registration, notification).catch((err: unknown) => {
          log.warn("session_push.send_failed", {
            sessionId,
            event: notification.event,
            error: safeErrorMessage(err),
          });
          return null;
        }),
      ),
    );
  }

  /** Sends Needs you and notes who got it. When no relay took any, retries once (`mayRetry`). */
  private async sendBlocked(
    sessionId: string,
    since: number,
    notification: PushNotification,
    registrations: PushRegistration[],
    mayRetry: boolean,
  ): Promise<void> {
    const at = this.now();
    for (const [key, entry] of this.blockedAlerts) {
      if (at - entry.at > BLOCKED_CATCH_UP_MS) this.blockedAlerts.delete(key);
    }
    for (const { deviceId } of registrations) {
      this.blockedAlerts.set(`${sessionId}:${deviceId}`, { at, since });
    }
    const results = await this.deliver(sessionId, notification, registrations);
    if (this.stopped || !mayRetry || !results.every((result) => result?.status === "unavailable"))
      return;
    for (const { deviceId } of registrations) this.scheduleBlockedRetry(sessionId, since, deviceId);
  }

  /** One retry per device and session; never keeps the process alive. */
  private scheduleBlockedRetry(sessionId: string, since: number, deviceId: string): void {
    const key = `${sessionId}:${deviceId}`;
    clearTimeout(this.retryTimers.get(key));
    const timer = setTimeout(() => {
      this.retryTimers.delete(key);
      if (this.stopped) return;
      const status = this.options.liveSessions().find((s) => s.id === sessionId)?.programStatus;
      if (status?.state !== "blocked" || status.since !== since) return;
      if (this.options.isDevicePresent(deviceId)) return;
      const registration = this.push.registrations("blocked").find((r) => r.deviceId === deviceId);
      if (!registration) return;
      const notification = this.notification(sessionId, blockedContent(status));
      void this.sendBlocked(sessionId, since, notification, [registration], false);
    }, BLOCKED_RETRY_DELAY_MS);
    timer.unref();
    this.retryTimers.set(key, timer);
  }

  /** Top-level sessions, while some device registered for agent messages. */
  offersNotify(sessionId: string): boolean {
    return (
      this.push.registrations("notify").length > 0 &&
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
    const notification = this.notification(sessionId, { event: "notify", title, body: written });
    // Held while sending so a parallel call waits its turn; given back when nothing went out.
    const started = this.startThrottle(sessionId, "notify");
    const results = await this.deliver(sessionId, notification, this.push.registrations("notify"));
    const devices = results.filter((result) => result?.status === "delivered").length;
    if (devices === 0) {
      // Only this call's hold: a later call may have taken a new one meanwhile.
      if (this.lastPushAt.get(`${sessionId}:notify`) === started)
        this.lastPushAt.delete(`${sessionId}:notify`);
      return { status: "not_delivered" };
    }
    return notification.body === cleaned
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

  /**
   * The alert always names its session, so the body gives way, never the name: fit it here
   * rather than let the envelope drop the subtitle first (spec section 2.4).
   */
  private notification(sessionId: string, content: PushEventContent): PushNotification {
    const session = this.storage.getSession(sessionId);
    const subtitle = session?.name
      ? clip(oneLine(session.name), SESSION_NAME_MAX, SESSION_NAME_MAX_BYTES)
      : undefined;
    const { body, ...rest } = content;
    const fields = {
      ...rest,
      sessionId,
      ...(session?.workspaceId ? { workspaceId: session.workspaceId } : {}),
      ...(subtitle ? { subtitle } : {}),
    };
    // A shortened body ends in an ellipsis, so a cut question or title never reads as whole.
    const whole = fitPushBody(fields, body, "");
    return { ...fields, body: whole === body ? body : fitPushBody(fields, body, "\u2026") };
  }
}

function blockedContent(status: ProgramStatus): PushEventContent {
  const kind = status.kind ?? "question";
  const fixed = BLOCKED_PRESENTATION[kind];
  return { event: "blocked", kind, title: fixed.title, body: status.message ?? fixed.body };
}

/** Control characters other than tab and newline; JSON would escape each into six bytes. */
// eslint-disable-next-line no-control-regex
const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b-\u001f\u007f]/g;

/** A notification title is one line. */
function oneLine(text: string): string {
  return text.replace(CONTROL_CHARACTERS, " ").replace(/\s+/g, " ").trim();
}

/**
 * Byte caps on the JSON-encoded agent title and session name. With the fixed fields of a
 * session plaintext (about 170 bytes with UUID ids), they leave at least 80 bytes for the body,
 * so the title and name always fit and only the body is ever shortened.
 */
const NOTIFY_TITLE_MAX_BYTES = 160;
const SESSION_NAME_MAX = 40;
const SESSION_NAME_MAX_BYTES = 96;

/**
 * The longest prefix within `maxCodePoints` whose JSON string encoding is at most `maxBytes`.
 * The tool schema bounds the agent's fields too; this holds for any caller.
 */
function clip(text: string, maxCodePoints: number, maxBytes = Infinity): string {
  const points = Array.from(text).slice(0, maxCodePoints);
  const jsonBytes = (value: string): number => Buffer.byteLength(JSON.stringify(value), "utf8") - 2;
  while (points.length > 0 && jsonBytes(points.join("")) > maxBytes) points.pop();
  return points.join("").trim();
}
