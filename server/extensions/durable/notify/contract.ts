import { Type, type Static } from "typebox";

// The agent-facing `notify` tool, shared by the classic inline extension (`server/src/
// session-notify-extension.ts`) and the durable built-in (`./durable.ts`), so both runtimes offer
// the same words and limits. Imports nothing from `oppi/durable`, which only the extension loader
// resolves. The server decides who is offered the tool and what a call sends
// (`SessionPushNotifier`).

export const NOTIFY_TOOL_NAME = "notify";

/**
 * Longest title and body the tool accepts, in code points. A plain-text title and body at these
 * limits fit the 510-byte push with the session name; long non-ASCII text can still shorten
 * the body, and the result says so.
 */
export const NOTIFY_TITLE_MAX = 80;
export const NOTIFY_BODY_MAX = 200;

export const NOTIFY_DESCRIPTION =
  "Send a push notification to the user's phone when there is a result they must read: " +
  "a report, a review, or a decision outside a question, or when the user asked to be " +
  "notified about something. Most turns do not need one. " +
  "Questions, approvals, and failed runs already notify the user on their own.";

export const NOTIFY_GUIDELINES = [
  "Call notify only when the work the user asked for is finished and there is something for " +
    "them to read: a result, a report, or a decision they must make outside a question. " +
    "Never for progress, for each step, or " +
    "for a turn that ends while you keep working (waiting on a background job or a subagent).",
  "Call it at most once per finished piece of work, as your last step before ending the turn.",
  "If the user asked to be notified about something, such as 'notify me when the tests " +
    "finish', call notify when it happens, even in the middle of longer work.",
  "Title: the outcome in a few words, such as 'Push relay fix landed'. Body: one or two " +
    "sentences that say what to read and where.",
  "Do not call notify before ask; ask already alerts the user.",
];

export const NotifyParams = Type.Object({
  title: Type.String({
    minLength: 1,
    maxLength: NOTIFY_TITLE_MAX,
    description: "The outcome in a few words; the notification's headline",
  }),
  body: Type.String({
    minLength: 1,
    maxLength: NOTIFY_BODY_MAX,
    description: "One or two sentences: what to read and where",
  }),
});

export type NotifyInput = Static<typeof NotifyParams>;

/** What a `notify` call did; also the tool result's details. */
export type NotifyOutcome =
  /**
   * Sealed and accepted by the push relay for this many devices. `shortened`: the body was cut
   * to fit the push.
   */
  | { status: "sent"; devices: number; shortened?: true }
  /** Push notifications are off on this server, or no device turned them on. */
  | { status: "off" }
  /** This session notified less than a minute ago. */
  | { status: "throttled"; retryAfterSeconds: number }
  /** Every device's send failed or its push budget is used up. */
  | { status: "not_delivered" };

/** The tool result the model reads. */
export function notifyOutcomeText(outcome: NotifyOutcome): string {
  switch (outcome.status) {
    case "sent": {
      const sent =
        outcome.devices === 1
          ? "Notification sent to 1 device."
          : `Notification sent to ${outcome.devices} devices.`;
      return outcome.shortened
        ? `${sent} Its body was cut to fit; keep notifications to one or two short sentences.`
        : sent;
    }
    case "off":
      return "Not sent: push notifications are off for this server.";
    case "throttled":
      return `Not sent: this session sent a notification less than a minute ago. Try again in ${outcome.retryAfterSeconds} s only if it is still needed.`;
    case "not_delivered":
      return "Not sent: the push relay did not accept the notification for any device.";
  }
}
