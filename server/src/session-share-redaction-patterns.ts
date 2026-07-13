import type {
  ShareRedactionFinding,
  ShareSecretFinding,
  ShareSessionRedactionPolicy,
} from "./session-share-redaction.js";

interface ShareSecretPattern {
  kind: string;
  regex: RegExp;
  replacement: string;
}

type ShareRedactionCategory =
  | "secrets"
  | "emails"
  | "phones"
  | "userPaths"
  | "ipAddresses"
  | "jwtAndBearer"
  | "namesHeuristic";

type ShareSampleKind = "secret" | "email" | "path" | "name" | "generic";

export interface ShareRedactionPattern {
  kind: string;
  category: ShareRedactionCategory;
  regex: RegExp;
  replacementLabel: string;
  replaceWith: string | ((match: string, ...captures: string[]) => string | null | undefined);
  sampleKind: ShareSampleKind;
}

const SENSITIVE_ENV_KEY_HINTS = [
  "KEY",
  "TOKEN",
  "SECRET",
  "PASSWORD",
  "PASSWD",
  "COOKIE",
  "AUTH",
  "CREDENTIAL",
];

const ENV_KEY_EXCLUDE_HINTS = [
  "PATH",
  "DIR",
  "HOME",
  "PWD",
  "SHELL",
  "LANG",
  "TERM",
  "USER",
  "USERNAME",
  "HOST",
  "PORT",
  "EDITOR",
  "DISPLAY",
];

const SECRET_PATTERNS: ReadonlyArray<ShareSecretPattern> = [
  {
    kind: "openai_api_key",
    regex: /\bsk-[A-Za-z0-9]{20,}\b/g,
    replacement: "[REDACTED_OPENAI_API_KEY]",
  },
  {
    kind: "anthropic_api_key",
    regex: /\bsk-ant-[A-Za-z0-9-]{20,}\b/g,
    replacement: "[REDACTED_ANTHROPIC_API_KEY]",
  },
  {
    kind: "github_pat",
    regex: /\bgh[pousr]_[A-Za-z0-9]{36}\b/g,
    replacement: "[REDACTED_GITHUB_TOKEN]",
  },
  {
    kind: "aws_access_key",
    regex: /\bAKIA[0-9A-Z]{16}\b/g,
    replacement: "[REDACTED_AWS_ACCESS_KEY]",
  },
  {
    kind: "private_key_header",
    regex: /-----BEGIN (?:RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY-----/g,
    replacement: "[REDACTED_PRIVATE_KEY_HEADER]",
  },
  {
    kind: "bearer_token",
    regex: /\bBearer\s+[A-Za-z0-9_.-]{20,}\b/gi,
    replacement: "Bearer [REDACTED_BEARER_TOKEN]",
  },
  {
    kind: "slack_token",
    regex: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g,
    replacement: "[REDACTED_SLACK_TOKEN]",
  },
  {
    kind: "stripe_live_key",
    regex: /\b[spr]k_live_[A-Za-z0-9]{20,}\b/g,
    replacement: "[REDACTED_STRIPE_KEY]",
  },
];

const EMAIL_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "email_address",
    category: "emails",
    regex: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g,
    replacementLabel: "[REDACTED_EMAIL]",
    replaceWith: "[REDACTED_EMAIL]",
    sampleKind: "email",
  },
];

const PHONE_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "phone_number",
    category: "phones",
    regex: /\b(?:\+?\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.-]?\d{3}[\s.-]?\d{4}\b/g,
    replacementLabel: "[REDACTED_PHONE]",
    replaceWith: "[REDACTED_PHONE]",
    sampleKind: "generic",
  },
];

const USER_PATH_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "unix_user_path",
    category: "userPaths",
    regex: /(\/Users\/|\/home\/)[A-Za-z0-9._-]+/g,
    replacementLabel: "<path>/[REDACTED_USER]",
    replaceWith: (_match, prefix) => `${prefix}[REDACTED_USER]`,
    sampleKind: "path",
  },
  {
    kind: "windows_user_path",
    category: "userPaths",
    regex: /(\\\\Users\\\\)[^\\/\s]+/g,
    replacementLabel: "\\\\Users\\\\[REDACTED_USER]",
    replaceWith: (_match, prefix) => `${prefix}[REDACTED_USER]`,
    sampleKind: "path",
  },
];

const IP_ADDRESS_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "ipv4_address",
    category: "ipAddresses",
    regex: /\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b/g,
    replacementLabel: "[REDACTED_IPV4]",
    replaceWith: "[REDACTED_IPV4]",
    sampleKind: "generic",
  },
  {
    kind: "ipv6_address",
    category: "ipAddresses",
    regex: /\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b/g,
    replacementLabel: "[REDACTED_IPV6]",
    replaceWith: "[REDACTED_IPV6]",
    sampleKind: "generic",
  },
];

const JWT_BEARER_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "jwt_token",
    category: "jwtAndBearer",
    regex: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g,
    replacementLabel: "[REDACTED_JWT]",
    replaceWith: "[REDACTED_JWT]",
    sampleKind: "secret",
  },
];

const NAME_HEURISTIC_STOP_WORDS = new Set([
  "Agent",
  "Anthropic",
  "Apple",
  "AppStore",
  "App",
  "Assistant",
  "Chat",
  "Client",
  "Code",
  "GitHub",
  "OpenAI",
  "Oppi",
  "Project",
  "Prompt",
  "Quick",
  "Server",
  "Session",
  "Share",
  "Skill",
  "SwiftUI",
  "Timeline",
  "Tool",
  "User",
  "Workspace",
  "Xcode",
]);

function looksLikeHeuristicPersonName(match: string): boolean {
  const words = match
    .trim()
    .split(/\s+/)
    .filter((word) => word.length > 0);
  if (words.length < 2 || words.length > 3) {
    return false;
  }

  for (const word of words) {
    if (!/^[A-Z][a-z'-]{1,24}$/.test(word)) {
      return false;
    }

    if (NAME_HEURISTIC_STOP_WORDS.has(word)) {
      return false;
    }
  }

  return true;
}

const NAME_HEURISTIC_PATTERNS: ReadonlyArray<ShareRedactionPattern> = [
  {
    kind: "person_name_heuristic",
    category: "namesHeuristic",
    regex: /\b(?:[A-Z][a-z'-]{1,24}\s+){1,2}[A-Z][a-z'-]{1,24}\b/g,
    replacementLabel: "[REDACTED_PERSON]",
    replaceWith: (match) => (looksLikeHeuristicPersonName(match) ? "[REDACTED_PERSON]" : match),
    sampleKind: "name",
  },
];

const SECRET_REDACTION_PATTERNS: ReadonlyArray<ShareRedactionPattern> = SECRET_PATTERNS.map(
  (pattern) => ({
    kind: pattern.kind,
    category: "secrets",
    regex: pattern.regex,
    replacementLabel: pattern.replacement,
    replaceWith: pattern.replacement,
    sampleKind: "secret",
  }),
);

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeEnvReplacementName(name: string): string {
  const sanitized = name
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
  if (!sanitized) {
    return "SECRET";
  }
  return sanitized.slice(0, 40);
}

function looksSensitiveEnvKey(name: string): boolean {
  const upper = name.toUpperCase();
  if (!SENSITIVE_ENV_KEY_HINTS.some((hint) => upper.includes(hint))) {
    return false;
  }
  if (ENV_KEY_EXCLUDE_HINTS.some((hint) => upper.includes(hint))) {
    return false;
  }
  return true;
}

function shouldTreatEnvValueAsSecret(value: string): boolean {
  if (value.length < 8 || value.length > 4096) {
    return false;
  }

  if (/\s/.test(value)) {
    return false;
  }

  // Avoid replacing obvious path-like values.
  if ((value.includes("/") || value.includes("\\")) && !/[A-Za-z0-9]{12,}/.test(value)) {
    return false;
  }

  return true;
}

function envLiteralRedactionPatterns(): ShareRedactionPattern[] {
  const byValue = new Map<string, { key: string; replacementName: string }>();

  for (const [name, rawValue] of Object.entries(process.env)) {
    if (!looksSensitiveEnvKey(name)) continue;
    if (typeof rawValue !== "string") continue;
    const value = rawValue.trim();
    if (!shouldTreatEnvValueAsSecret(value)) continue;
    if (byValue.has(value)) continue;

    const replacementName = normalizeEnvReplacementName(name);
    byValue.set(value, { key: name, replacementName });
  }

  const entries = [...byValue.entries()].sort((lhs, rhs) => rhs[0].length - lhs[0].length);

  return entries.map(([value, meta]) => ({
    kind: `literal_secret_${meta.replacementName.toLowerCase()}`,
    category: "secrets" as const,
    regex: new RegExp(escapeRegex(value), "g"),
    replacementLabel: `[REDACTED_${meta.replacementName}]`,
    replaceWith: `[REDACTED_${meta.replacementName}]`,
    sampleKind: "secret",
  }));
}

function maskShareSample(kind: ShareSampleKind, match: string): string {
  if (match.length === 0) {
    return match;
  }

  if (kind === "email") {
    const atIndex = match.indexOf("@");
    if (atIndex > 0) {
      return `${match[0]}***${match.slice(atIndex)}`;
    }
  }

  if (kind === "path") {
    return match
      .replace(/(\/Users\/|\/home\/)[^/]+/g, "$1…")
      .replace(/(\\\\Users\\\\)[^\\]+/g, "$1…");
  }

  if (kind === "secret") {
    if (match.length <= 6) {
      return "***";
    }
    if (match.length <= 12) {
      return `${match.slice(0, 2)}…${match.slice(-2)}`;
    }
    return `${match.slice(0, 4)}…${match.slice(-4)}`;
  }

  if (kind === "name") {
    const parts = match
      .trim()
      .split(/\s+/)
      .filter((part) => part.length > 0);
    const masked = parts.map((part) => `${part[0] ?? ""}***`).join(" ");
    return masked.length > 0 ? masked : "[name]";
  }

  if (match.length <= 20) {
    return match;
  }
  return `${match.slice(0, 8)}…${match.slice(-4)}`;
}

export function applyRedactionPattern(
  html: string,
  pattern: ShareRedactionPattern,
): { html: string; finding?: ShareRedactionFinding } {
  let count = 0;
  const samples = new Set<string>();

  const redactedHtml = html.replace(pattern.regex, (match: string, ...rest: unknown[]) => {
    let replacement: string;

    if (typeof pattern.replaceWith === "function") {
      const captureCount = Math.max(0, rest.length - 2);
      const captures = rest
        .slice(0, captureCount)
        .map((value) => (typeof value === "string" ? value : ""));
      const candidate = pattern.replaceWith(match, ...captures);
      if (typeof candidate !== "string" || candidate === match) {
        return match;
      }
      replacement = candidate;
    } else {
      replacement = pattern.replaceWith;
      if (replacement === match) {
        return match;
      }
    }

    count += 1;
    if (samples.size < 3) {
      samples.add(maskShareSample(pattern.sampleKind, match));
    }

    return replacement;
  });

  if (count <= 0) {
    return { html };
  }

  return {
    html: redactedHtml,
    finding: {
      kind: pattern.kind,
      count,
      replacement: pattern.replacementLabel,
      samples: [...samples],
    },
  };
}

export function mergeRedactionFinding(
  aggregate: Map<string, ShareRedactionFinding>,
  finding: ShareRedactionFinding,
): void {
  const existing = aggregate.get(finding.kind);
  if (!existing) {
    aggregate.set(finding.kind, {
      kind: finding.kind,
      count: finding.count,
      replacement: finding.replacement,
      samples: finding.samples.slice(0, 3),
    });
    return;
  }

  existing.count += finding.count;
  for (const sample of finding.samples) {
    if (existing.samples.includes(sample)) continue;
    if (existing.samples.length >= 3) break;
    existing.samples.push(sample);
  }
}

export function mergeSecretFinding(
  aggregate: Map<string, ShareSecretFinding>,
  finding: ShareSecretFinding,
): void {
  const existing = aggregate.get(finding.kind);
  if (!existing) {
    aggregate.set(finding.kind, {
      kind: finding.kind,
      count: finding.count,
    });
    return;
  }

  existing.count += finding.count;
}

export function scanTextForSecrets(text: string): ShareSecretFinding[] {
  const findings: ShareSecretFinding[] = [];

  for (const pattern of SECRET_PATTERNS) {
    const matches = text.match(pattern.regex);
    const count = matches?.length ?? 0;
    if (count <= 0) continue;
    findings.push({ kind: pattern.kind, count });
  }

  return findings;
}

export function redactionPatternsForPolicy(
  policy: ShareSessionRedactionPolicy,
): ShareRedactionPattern[] {
  const patterns: ShareRedactionPattern[] = [
    ...SECRET_REDACTION_PATTERNS,
    ...envLiteralRedactionPatterns(),
  ];

  if (policy.emails) {
    patterns.push(...EMAIL_REDACTION_PATTERNS);
  }

  if (policy.phones) {
    patterns.push(...PHONE_REDACTION_PATTERNS);
  }

  if (policy.userPaths) {
    patterns.push(...USER_PATH_REDACTION_PATTERNS);
  }

  if (policy.ipAddresses) {
    patterns.push(...IP_ADDRESS_REDACTION_PATTERNS);
  }

  if (policy.jwtAndBearer) {
    patterns.push(...JWT_BEARER_REDACTION_PATTERNS);
  }

  if (policy.namesHeuristic) {
    patterns.push(...NAME_HEURISTIC_PATTERNS);
  }

  return patterns;
}
