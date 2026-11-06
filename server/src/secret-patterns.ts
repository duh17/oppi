/**
 * The one catalog of vendor secret shapes. Free-text log redaction
 * (`log-redact.ts`, which also backs CLI output) and session-share export
 * (`session-share-redaction-patterns.ts`) both consume it, so a new key shape
 * is added here once.
 *
 * `label` is the share-export replacement; `logLabel` overrides the logger's
 * default `[REDACTED]`. Shapes that only make sense for one consumer (Oppi's own
 * `sk_`/`pt_` tokens, generic `Bearer`, JWTs, query-string tokens) stay with
 * that consumer.
 */
export interface SecretPattern {
  kind: string;
  regex: RegExp;
  label: string;
  logLabel?: string;
}

// Prefixed keys (`sk-ant-api03-…`, `sk-proj-…`, `sk-svcacct-…`, `sk-admin-…`).
// Standing alone they need only 8 tail characters. Glued to a word character
// (`token=…`, `keysk-proj-…`, `Bearersk-…`) the prefix alone is too weak:
// kebab-case names like `flask-admin-deployment-7d9f8c6b5-x2k4p` or
// `task-proj-1234-fix-login-redirect` contain it. So a glued tail must be 40+
// characters with an uppercase letter and a digit early on, as every real key
// has. The lookaheads are bounded so a long run of near-matches stays linear.
const KEY_TAIL = "[A-Za-z0-9_-]";
function prefixedKey(names: string): string {
  const prefix = `sk-(?:${names})-`;
  const glued = `${prefix}(?=[a-z0-9_-]{0,79}[A-Z])(?=[A-Za-z_-]{0,79}\\d)${KEY_TAIL}{40,}`;
  return `\\b${prefix}${KEY_TAIL}{8,}|${glued}`;
}

// Legacy OpenAI keys: `sk-` + 48 alphanumerics, even when glued to a word.
// Standing alone, 20+ is enough (older/shorter shapes).
const LEGACY_KEY = "\\bsk-[A-Za-z0-9]{20,}(?![A-Za-z0-9])|sk-[A-Za-z0-9]{48}(?![A-Za-z0-9])";

export const SECRET_PATTERNS: ReadonlyArray<SecretPattern> = [
  {
    kind: "anthropic_api_key",
    regex: new RegExp(prefixedKey("ant"), "g"),
    label: "[REDACTED_ANTHROPIC_API_KEY]",
  },
  {
    kind: "openai_api_key",
    regex: new RegExp(`${prefixedKey("proj|svcacct|admin")}|${LEGACY_KEY}`, "g"),
    label: "[REDACTED_OPENAI_API_KEY]",
  },
  {
    kind: "github_pat",
    regex: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/g,
    label: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    kind: "github_fine_grained_pat",
    regex: /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
    label: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    kind: "aws_access_key",
    regex: /\bAKIA[0-9A-Z]{16}\b/g,
    label: "[REDACTED_AWS_ACCESS_KEY]",
  },
  {
    kind: "private_key_block",
    // The body stops at the next `-----`, so a header without a footer costs one
    // short scan instead of a scan to the end of the input.
    regex:
      /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----(?:(?!-----)[\s\S])*-----END [A-Z0-9 ]*PRIVATE KEY-----/g,
    label: "[REDACTED_PRIVATE_KEY]",
    logLabel: "[REDACTED_PRIVATE_KEY]",
  },
  {
    kind: "private_key_header",
    regex: /-----BEGIN (?:RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----/g,
    label: "[REDACTED_PRIVATE_KEY_HEADER]",
    logLabel: "[REDACTED_PRIVATE_KEY]",
  },
  {
    kind: "slack_token",
    regex: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
    label: "[REDACTED_SLACK_TOKEN]",
  },
  {
    kind: "stripe_live_key",
    regex: /\b[spr]k_live_[A-Za-z0-9]{20,}\b/g,
    label: "[REDACTED_STRIPE_KEY]",
  },
];
