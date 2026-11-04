import { redactCredentialString } from "./credential-redaction.js";

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
