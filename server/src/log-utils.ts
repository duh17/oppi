import { redactCredentialString } from "./credential-redaction.js";

/** Compact HH:MM:SS.mmm timestamp for log lines. */
export function ts(): string {
  const d = new Date();
  const h = String(d.getHours()).padStart(2, "0");
  const m = String(d.getMinutes()).padStart(2, "0");
  const s = String(d.getSeconds()).padStart(2, "0");
  const ms = String(d.getMilliseconds()).padStart(3, "0");
  return `${h}:${m}:${s}.${ms}`;
}

/** Extract a safe log-friendly message from an unknown error.
 *  Never logs the full error object — only .message.
 *  This prevents leaking user content, auth tokens, or request bodies
 *  that may be attached as error properties or .cause chains.
 */
export function safeErrorMessage(err: unknown): string {
  if (err instanceof Error) {
    return redactCredentialString(err.message);
  }
  return redactCredentialString(String(err));
}
