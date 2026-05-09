import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";

import type { AgentSession } from "@earendil-works/pi-coding-agent";

const DEFAULT_SHARE_VIEWER_URL = "https://pi.dev/session/";
const SHARE_ERROR_PREFIX = "[share:";

export type ShareSessionErrorCode =
  | "session_not_persisted"
  | "gh_not_installed"
  | "gh_not_authenticated"
  | "share_timeout"
  | "gist_create_failed"
  | "gist_parse_failed"
  | "share_secret_detected"
  | "share_export_failed"
  | "share_unknown";

export interface ShareSecretFinding {
  kind: string;
  count: number;
}

export interface ShareRedactionFinding extends ShareSecretFinding {
  replacement: string;
  samples: string[];
}

export interface ShareSessionRedactionPolicyInput {
  secrets?: boolean;
  emails?: boolean;
  phones?: boolean;
  userPaths?: boolean;
  ipAddresses?: boolean;
  jwtAndBearer?: boolean;
  namesHeuristic?: boolean;
  skills?: boolean;
}

export interface ShareSessionRedactionPolicy {
  secrets: true;
  emails: boolean;
  phones: boolean;
  userPaths: boolean;
  ipAddresses: boolean;
  jwtAndBearer: boolean;
  namesHeuristic: boolean;
  skills: boolean;
}

export interface ShareSessionRedactionSummary {
  enabled: boolean;
  policy: ShareSessionRedactionPolicy;
  totalReplacements: number;
  findings: ShareRedactionFinding[];
}

interface ShareHtmlRedactionResult {
  html: string;
  findings: ShareRedactionFinding[];
  totalReplacements: number;
}

interface GhCommandResult {
  stdout: string;
  stderr: string;
  code: number;
}

export type ShareSessionAction = "prepare" | "publish";

export interface ShareSessionArtifactSummary {
  format: "html";
  bytes: number;
}

export interface ShareSessionScanSummary {
  enabled: boolean;
  blocked: boolean;
  findings: ShareSecretFinding[];
  residualFindings: ShareSecretFinding[];
}

export interface ShareSessionResult {
  shareUrl: string;
  gistUrl: string;
  gistId: string;
  phase: "published";
  share: {
    id: string;
    url: string;
    provider: "github_gist";
    providerRef: {
      gistId: string;
      gistUrl: string;
    };
  };
  artifact: ShareSessionArtifactSummary;
  scan: ShareSessionScanSummary;
  redaction: ShareSessionRedactionSummary;
  warnings: string[];
}

export interface ShareSessionPrepareResult {
  phase: "prepared";
  canPublish: boolean;
  artifact: ShareSessionArtifactSummary;
  scan: ShareSessionScanSummary;
  redaction: ShareSessionRedactionSummary;
}

export type ShareSessionCommandResult = ShareSessionResult | ShareSessionPrepareResult;

export interface ShareSessionOptions {
  action?: ShareSessionAction;
  redactionPolicy?: ShareSessionRedactionPolicyInput;
}

interface ShareSessionDeps {
  ensureGhAuthenticated?: () => void;
  exportSessionToHtml?: (session: AgentSession, outputPath: string) => Promise<void>;
  createSecretGist?: (htmlPath: string) => Promise<GhCommandResult>;
  makeShareViewerUrl?: (gistId: string) => string;
  makeTempPath?: () => string;
  scanHtmlForSecrets?: (html: string) => ShareSecretFinding[];
  redactHtml?: (html: string, policy: ShareSessionRedactionPolicy) => ShareHtmlRedactionResult;
  isSecretScanEnabled?: () => boolean;
  isAutoRedactionEnabled?: () => boolean;
  shouldBlockOnSecrets?: () => boolean;
}

export class ShareSessionError extends Error {
  constructor(
    public readonly code: ShareSessionErrorCode,
    message: string,
    public readonly findings: ShareSecretFinding[] = [],
  ) {
    super(formatShareErrorMessage(code, message));
    this.name = "ShareSessionError";
  }
}

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

interface ShareRedactionPattern {
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

const DEFAULT_SHARE_REDACTION_POLICY: ShareSessionRedactionPolicy = {
  secrets: true,
  emails: true,
  phones: true,
  userPaths: true,
  ipAddresses: true,
  jwtAndBearer: true,
  namesHeuristic: false,
  skills: true,
};

function parseBoolEnv(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (!raw) return fallback;
  return !/^(0|false|off|no)$/i.test(raw.trim());
}

function secretScanEnabled(): boolean {
  return parseBoolEnv("OPPI_SHARE_SECRET_SCAN", true);
}

function autoRedactionEnabled(): boolean {
  return parseBoolEnv("OPPI_SHARE_AUTO_REDACT", true);
}

function blockOnSecretFindings(): boolean {
  return parseBoolEnv("OPPI_SHARE_BLOCK_ON_SECRETS", false);
}

function defaultRedactionPolicyFromEnv(): ShareSessionRedactionPolicy {
  return {
    secrets: true,
    emails: parseBoolEnv("OPPI_SHARE_REDACT_EMAILS", DEFAULT_SHARE_REDACTION_POLICY.emails),
    phones: parseBoolEnv("OPPI_SHARE_REDACT_PHONES", DEFAULT_SHARE_REDACTION_POLICY.phones),
    userPaths: parseBoolEnv(
      "OPPI_SHARE_REDACT_USER_PATHS",
      DEFAULT_SHARE_REDACTION_POLICY.userPaths,
    ),
    ipAddresses: parseBoolEnv(
      "OPPI_SHARE_REDACT_IP_ADDRESSES",
      DEFAULT_SHARE_REDACTION_POLICY.ipAddresses,
    ),
    jwtAndBearer: parseBoolEnv(
      "OPPI_SHARE_REDACT_JWT_AND_BEARER",
      DEFAULT_SHARE_REDACTION_POLICY.jwtAndBearer,
    ),
    namesHeuristic: parseBoolEnv(
      "OPPI_SHARE_REDACT_NAMES_HEURISTIC",
      DEFAULT_SHARE_REDACTION_POLICY.namesHeuristic,
    ),
    skills: parseBoolEnv("OPPI_SHARE_REDACT_SKILLS", DEFAULT_SHARE_REDACTION_POLICY.skills),
  };
}

function normalizeRedactionPolicy(
  input: ShareSessionRedactionPolicyInput | undefined,
): ShareSessionRedactionPolicy {
  const fallback = defaultRedactionPolicyFromEnv();

  return {
    secrets: true,
    emails: typeof input?.emails === "boolean" ? input.emails : fallback.emails,
    phones: typeof input?.phones === "boolean" ? input.phones : fallback.phones,
    userPaths: typeof input?.userPaths === "boolean" ? input.userPaths : fallback.userPaths,
    ipAddresses: typeof input?.ipAddresses === "boolean" ? input.ipAddresses : fallback.ipAddresses,
    jwtAndBearer:
      typeof input?.jwtAndBearer === "boolean" ? input.jwtAndBearer : fallback.jwtAndBearer,
    namesHeuristic:
      typeof input?.namesHeuristic === "boolean" ? input.namesHeuristic : fallback.namesHeuristic,
    skills: typeof input?.skills === "boolean" ? input.skills : fallback.skills,
  };
}

function formatShareErrorMessage(code: ShareSessionErrorCode, message: string): string {
  const cleaned = message.replace(/\s+/g, " ").trim();
  return `${SHARE_ERROR_PREFIX}${code}] ${cleaned}`;
}

function shareError(code: ShareSessionErrorCode, message: string): ShareSessionError {
  return new ShareSessionError(code, message);
}

function summarizeFindings(findings: ShareSecretFinding[]): string {
  return findings.map((finding) => `${finding.kind}×${finding.count}`).join(", ");
}

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

function applyRedactionPattern(
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

function mergeRedactionFinding(
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

function mergeSecretFinding(
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

function scanTextForSecrets(text: string): ShareSecretFinding[] {
  const findings: ShareSecretFinding[] = [];

  for (const pattern of SECRET_PATTERNS) {
    const matches = text.match(pattern.regex);
    const count = matches?.length ?? 0;
    if (count <= 0) continue;
    findings.push({ kind: pattern.kind, count });
  }

  return findings;
}

function visitStringValues(value: unknown, visitor: (text: string) => void): void {
  if (typeof value === "string") {
    visitor(value);
    return;
  }

  if (Array.isArray(value)) {
    for (const item of value) {
      visitStringValues(item, visitor);
    }
    return;
  }

  if (!value || typeof value !== "object") {
    return;
  }

  for (const item of Object.values(value)) {
    visitStringValues(item, visitor);
  }
}

const EMBEDDED_SESSION_DATA_SCRIPT_REGEX =
  /(<script id="session-data" type="application\/(?:json|octet-stream)">)([\s\S]*?)(<\/script>)/;

function embeddedSessionDataDecodeError(message: string): ShareSessionError {
  return shareError(
    "share_export_failed",
    `Failed to decode embedded session-data payload: ${message}`,
  );
}

function extractEmbeddedSessionData(html: string):
  | {
      sessionData: Record<string, unknown>;
      rewriteHtml: (sessionData: Record<string, unknown>) => string;
    }
  | undefined {
  const match = EMBEDDED_SESSION_DATA_SCRIPT_REGEX.exec(html);
  if (!match || typeof match.index !== "number") {
    return undefined;
  }

  const openTag = match[1];
  const encodedPayload = match[2].trim();
  const contentStart = match.index + openTag.length;
  const contentEnd = contentStart + match[2].length;

  let json = "";
  try {
    json = Buffer.from(encodedPayload, "base64").toString("utf-8");
  } catch (error) {
    throw embeddedSessionDataDecodeError(error instanceof Error ? error.message : String(error));
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch (error) {
    throw embeddedSessionDataDecodeError(error instanceof Error ? error.message : String(error));
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw embeddedSessionDataDecodeError("expected a base64-encoded JSON object");
  }

  return {
    sessionData: parsed as Record<string, unknown>,
    rewriteHtml: (sessionData) => {
      const nextPayload = Buffer.from(JSON.stringify(sessionData), "utf-8").toString("base64");
      return `${html.slice(0, contentStart)}${nextPayload}${html.slice(contentEnd)}`;
    },
  };
}

function redactTextWithPatterns(
  text: string,
  patterns: ReadonlyArray<ShareRedactionPattern>,
  findingsByKind: Map<string, ShareRedactionFinding>,
  policy: ShareSessionRedactionPolicy,
): string {
  let redacted = text;

  if (policy.skills) {
    redacted = redactSkillBlockText(redacted, findingsByKind);
  }

  for (const pattern of patterns) {
    const result = applyRedactionPattern(redacted, pattern);
    redacted = result.html;
    if (!result.finding) continue;
    mergeRedactionFinding(findingsByKind, result.finding);
  }

  return redacted;
}

function redactSessionDataStrings(
  value: unknown,
  patterns: ReadonlyArray<ShareRedactionPattern>,
  findingsByKind: Map<string, ShareRedactionFinding>,
  policy: ShareSessionRedactionPolicy,
): unknown {
  if (typeof value === "string") {
    return redactTextWithPatterns(value, patterns, findingsByKind, policy);
  }

  if (Array.isArray(value)) {
    return value.map((item) => redactSessionDataStrings(item, patterns, findingsByKind, policy));
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  const next: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    next[key] = redactSessionDataStrings(item, patterns, findingsByKind, policy);
  }
  return next;
}

function noteSystemPromptRemoval(
  findingsByKind: Map<string, ShareRedactionFinding>,
  systemPrompt: unknown,
): void {
  if (typeof systemPrompt !== "string" || systemPrompt.trim().length === 0) {
    return;
  }

  mergeRedactionFinding(findingsByKind, {
    kind: "system_prompt_removed",
    count: 1,
    replacement: "[REMOVED_SYSTEM_PROMPT]",
    samples: ["[system prompt omitted]"],
  });
}

function noteToolDefinitionsRemoval(
  findingsByKind: Map<string, ShareRedactionFinding>,
  tools: unknown,
): void {
  if (!Array.isArray(tools) || tools.length === 0) {
    return;
  }

  mergeRedactionFinding(findingsByKind, {
    kind: "tool_definitions_removed",
    count: tools.length,
    replacement: "[REMOVED_TOOL_DEFINITIONS]",
    samples: [`${tools.length} tool definitions omitted`],
  });
}

function notePreUserEntriesRemoval(
  findingsByKind: Map<string, ShareRedactionFinding>,
  removedCount: number,
): void {
  if (removedCount <= 0) {
    return;
  }

  mergeRedactionFinding(findingsByKind, {
    kind: "pre_user_entries_removed",
    count: removedCount,
    replacement: "[REMOVED_PRE_USER_ENTRIES]",
    samples: [`${removedCount} pre-user entries omitted`],
  });
}

function countRedactedSkills(value: unknown): number {
  if (Array.isArray(value)) {
    return value.length;
  }

  return value === undefined ? 0 : 1;
}

function noteSkillsRemoval(
  findingsByKind: Map<string, ShareRedactionFinding>,
  removedCount: number,
): void {
  if (removedCount <= 0) {
    return;
  }

  mergeRedactionFinding(findingsByKind, {
    kind: "skills_removed",
    count: removedCount,
    replacement: "[REMOVED_SKILLS]",
    samples: [`${removedCount} skills omitted`],
  });
}

function redactSkillBlockText(
  text: string,
  findingsByKind: Map<string, ShareRedactionFinding>,
): string {
  const match = text.match(
    /^<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n<\/skill>(?:\n\n([\s\S]+))?$/,
  );
  if (!match) {
    return text;
  }

  const trailingUserMessage = match[4]?.trim();
  mergeRedactionFinding(findingsByKind, {
    kind: "skill_block_removed",
    count: 1,
    replacement: "[REDACTED_SKILL]",
    samples: ["[skill block omitted]"],
  });

  return trailingUserMessage ? `[REDACTED_SKILL]\n\n${trailingUserMessage}` : "[REDACTED_SKILL]";
}

function isUserMessageEntry(entry: unknown): boolean {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    return false;
  }

  if ((entry as Record<string, unknown>).type !== "message") {
    return false;
  }

  const message = (entry as Record<string, unknown>).message;
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return false;
  }

  return (message as Record<string, unknown>).role === "user";
}

function trimSessionEntriesToFirstUser(entries: unknown): {
  entries: unknown;
  removedCount: number;
  changed: boolean;
} {
  if (!Array.isArray(entries)) {
    return { entries, removedCount: 0, changed: false };
  }

  const firstUserIndex = entries.findIndex((entry) => isUserMessageEntry(entry));
  if (firstUserIndex < 0) {
    return {
      entries: [],
      removedCount: entries.length,
      changed: entries.length > 0,
    };
  }

  if (firstUserIndex === 0) {
    return {
      entries,
      removedCount: 0,
      changed: false,
    };
  }

  const trimmedEntries = entries.slice(firstUserIndex).map((entry) => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      return entry;
    }
    return { ...(entry as Record<string, unknown>) };
  });

  const retainedIds = new Set(
    trimmedEntries.flatMap((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return [];
      }
      const id = (entry as Record<string, unknown>).id;
      return typeof id === "string" ? [id] : [];
    }),
  );

  for (const entry of trimmedEntries) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      continue;
    }

    const record = entry as Record<string, unknown>;
    const parentId = record.parentId;
    if (parentId === null || parentId === undefined) {
      continue;
    }

    if (typeof parentId !== "string" || !retainedIds.has(parentId)) {
      record.parentId = null;
    }
  }

  return {
    entries: trimmedEntries,
    removedCount: firstUserIndex,
    changed: true,
  };
}

function lastSessionEntryId(entries: unknown): string | null {
  if (!Array.isArray(entries)) {
    return null;
  }

  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      continue;
    }

    const id = (entry as Record<string, unknown>).id;
    if (typeof id === "string" && id.length > 0) {
      return id;
    }
  }

  return null;
}

function sanitizeSessionDataForShare(
  sessionData: Record<string, unknown>,
  policy: ShareSessionRedactionPolicy = normalizeRedactionPolicy(undefined),
  findingsByKind?: Map<string, ShareRedactionFinding>,
): { sessionData: Record<string, unknown>; changed: boolean } {
  const nextSessionData = { ...sessionData };
  let changed = false;

  if ("systemPrompt" in nextSessionData) {
    if (findingsByKind) {
      noteSystemPromptRemoval(findingsByKind, nextSessionData.systemPrompt);
    }
    delete nextSessionData.systemPrompt;
    changed = true;
  }

  if ("tools" in nextSessionData) {
    if (findingsByKind) {
      noteToolDefinitionsRemoval(findingsByKind, nextSessionData.tools);
    }
    delete nextSessionData.tools;
    changed = true;
  }

  if (policy.skills) {
    let removedSkills = 0;
    const skillKeys = ["skills", "availableSkills", "workspaceSkills", "skillCatalog"];
    for (const key of skillKeys) {
      if (!(key in nextSessionData)) {
        continue;
      }
      removedSkills += countRedactedSkills(nextSessionData[key]);
      delete nextSessionData[key];
      changed = true;
    }

    const workspace = nextSessionData.workspace;
    if (workspace && typeof workspace === "object" && !Array.isArray(workspace)) {
      const workspaceRecord = { ...(workspace as Record<string, unknown>) };
      if ("skills" in workspaceRecord) {
        removedSkills += countRedactedSkills(workspaceRecord.skills);
        delete workspaceRecord.skills;
        nextSessionData.workspace = workspaceRecord;
        changed = true;
      }
    }

    if (removedSkills > 0 && findingsByKind) {
      noteSkillsRemoval(findingsByKind, removedSkills);
    }
  }

  const trimmedEntries = trimSessionEntriesToFirstUser(nextSessionData.entries);
  if (trimmedEntries.changed) {
    nextSessionData.entries = trimmedEntries.entries;
    if (findingsByKind) {
      notePreUserEntriesRemoval(findingsByKind, trimmedEntries.removedCount);
    }
    changed = true;

    const leafId = nextSessionData.leafId;
    const lastEntryId = lastSessionEntryId(trimmedEntries.entries);
    if (typeof leafId !== "string" || !Array.isArray(trimmedEntries.entries)) {
      nextSessionData.leafId = lastEntryId;
      changed = true;
    } else {
      const retainedLeaf = trimmedEntries.entries.some((entry) => {
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
          return false;
        }
        return (entry as Record<string, unknown>).id === leafId;
      });

      if (!retainedLeaf) {
        nextSessionData.leafId = lastEntryId;
        changed = true;
      }
    }
  }

  return {
    sessionData: nextSessionData,
    changed,
  };
}

function defaultSanitizeHtmlForShare(
  html: string,
  policy: ShareSessionRedactionPolicy = normalizeRedactionPolicy(undefined),
): string {
  const embedded = extractEmbeddedSessionData(html);
  if (!embedded) {
    return html;
  }

  const sanitized = sanitizeSessionDataForShare(embedded.sessionData, policy);
  if (!sanitized.changed) {
    return html;
  }

  return embedded.rewriteHtml(sanitized.sessionData);
}

function defaultScanHtmlForSecrets(html: string): ShareSecretFinding[] {
  const findingsByKind = new Map<string, ShareSecretFinding>();

  for (const finding of scanTextForSecrets(html)) {
    mergeSecretFinding(findingsByKind, finding);
  }

  const embedded = extractEmbeddedSessionData(html);
  if (embedded) {
    visitStringValues(embedded.sessionData, (text) => {
      for (const finding of scanTextForSecrets(text)) {
        mergeSecretFinding(findingsByKind, finding);
      }
    });
  }

  return [...findingsByKind.values()].sort((lhs, rhs) => rhs.count - lhs.count);
}

function redactionPatternsForPolicy(policy: ShareSessionRedactionPolicy): ShareRedactionPattern[] {
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

function defaultRedactHtmlForShare(
  html: string,
  policy: ShareSessionRedactionPolicy = normalizeRedactionPolicy(undefined),
): ShareHtmlRedactionResult {
  const patterns = redactionPatternsForPolicy(policy);
  let redactedHtml = html;
  const findingsByKind = new Map<string, ShareRedactionFinding>();

  for (const pattern of patterns) {
    const result = applyRedactionPattern(redactedHtml, pattern);
    redactedHtml = result.html;
    if (!result.finding) continue;
    mergeRedactionFinding(findingsByKind, result.finding);
  }

  const embedded = extractEmbeddedSessionData(redactedHtml);
  if (embedded) {
    const sanitized = sanitizeSessionDataForShare(embedded.sessionData, policy, findingsByKind);

    const redactedSessionData = redactSessionDataStrings(
      sanitized.sessionData,
      patterns,
      findingsByKind,
      policy,
    ) as Record<string, unknown>;

    redactedHtml = embedded.rewriteHtml(redactedSessionData);
  }

  const findings = [...findingsByKind.values()].sort((lhs, rhs) => rhs.count - lhs.count);
  const totalReplacements = findings.reduce((sum, finding) => sum + finding.count, 0);

  return {
    html: redactedHtml,
    findings,
    totalReplacements,
  };
}

function normalizeShareError(error: unknown): ShareSessionError {
  if (error instanceof ShareSessionError) {
    return error;
  }

  const message = error instanceof Error ? error.message : String(error);

  if (/(ENOENT|spawn\s+gh|not found)/i.test(message)) {
    return shareError(
      "gh_not_installed",
      "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/",
    );
  }

  if (/timed out/i.test(message)) {
    return shareError("share_timeout", "Share request timed out. Please try again.");
  }

  return shareError("share_unknown", message || "Share failed.");
}

function defaultEnsureGhAuthenticated(): void {
  try {
    const auth = spawnSync("gh", ["auth", "status"], { encoding: "utf-8" });
    if (auth.error) {
      const code = (auth.error as NodeJS.ErrnoException).code;
      if (code === "ENOENT") {
        throw shareError(
          "gh_not_installed",
          "GitHub CLI (gh) is not installed. Install it from https://cli.github.com/",
        );
      }
      throw auth.error;
    }

    if (auth.status !== 0) {
      throw shareError(
        "gh_not_authenticated",
        "GitHub CLI is not logged in. Run 'gh auth login' first.",
      );
    }
  } catch (error) {
    if (error instanceof ShareSessionError) {
      throw error;
    }
    if (error instanceof Error) {
      throw normalizeShareError(error);
    }
    throw shareError("share_unknown", String(error));
  }
}

async function runGhCommand(args: string[], timeoutMs: number): Promise<GhCommandResult> {
  return new Promise<GhCommandResult>((resolve, reject) => {
    const proc = spawn("gh", args, {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    const settle = (callback: () => void): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      callback();
    };

    const timer = setTimeout(() => {
      proc.kill();
      settle(() =>
        reject(shareError("share_timeout", `gh ${args.join(" ")} timed out after ${timeoutMs}ms`)),
      );
    }, timeoutMs);

    proc.stdout?.setEncoding("utf-8");
    proc.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });

    proc.stderr?.setEncoding("utf-8");
    proc.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });

    proc.on("error", (error) => {
      settle(() => reject(error));
    });

    proc.on("close", (code) => {
      settle(() => {
        resolve({
          stdout,
          stderr,
          code: code ?? -1,
        });
      });
    });
  });
}

async function defaultCreateSecretGist(htmlPath: string): Promise<GhCommandResult> {
  const result = await runGhCommand(["gist", "create", "--public=false", htmlPath], 120_000);

  if (result.code !== 0) {
    const reason = result.stderr.trim() || result.stdout.trim() || "Unknown error";
    throw shareError("gist_create_failed", `Failed to create gist: ${reason}`);
  }

  return result;
}

async function defaultExportSessionToHtml(
  session: AgentSession,
  outputPath: string,
): Promise<void> {
  await session.exportToHtml(outputPath);
}

function defaultMakeShareViewerUrl(gistId: string): string {
  const baseUrl = process.env.PI_SHARE_VIEWER_URL || DEFAULT_SHARE_VIEWER_URL;
  return `${baseUrl}#${gistId}`;
}

function parseGistUrl(output: string): string | undefined {
  const lines = output
    .split(/\r?\n/g)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  for (const line of lines) {
    if ((line.startsWith("https://") || line.startsWith("http://")) && line.includes("gist")) {
      return line;
    }
  }

  return undefined;
}

function parseGistId(gistUrl: string): string | undefined {
  try {
    const url = new URL(gistUrl);
    const segment = url.pathname
      .split("/")
      .filter((part) => part.length > 0)
      .at(-1);
    if (!segment) {
      return undefined;
    }

    const normalized = segment.replace(/\.git$/i, "");
    return normalized.length > 0 ? normalized : undefined;
  } catch {
    const fallback = gistUrl
      .split("/")
      .filter((part) => part.length > 0)
      .at(-1)
      ?.replace(/\.git$/i, "");
    return fallback && fallback.length > 0 ? fallback : undefined;
  }
}

export async function shareSession(
  session: AgentSession,
  deps: ShareSessionDeps = {},
  options: ShareSessionOptions = {},
): Promise<ShareSessionCommandResult> {
  const action: ShareSessionAction = options.action === "prepare" ? "prepare" : "publish";
  const ensureGhAuthenticated = deps.ensureGhAuthenticated ?? defaultEnsureGhAuthenticated;
  const exportSessionToHtml = deps.exportSessionToHtml ?? defaultExportSessionToHtml;
  const createSecretGist = deps.createSecretGist ?? defaultCreateSecretGist;
  const makeShareViewerUrl = deps.makeShareViewerUrl ?? defaultMakeShareViewerUrl;
  const scanHtmlForSecrets = deps.scanHtmlForSecrets ?? defaultScanHtmlForSecrets;
  const redactHtml = deps.redactHtml ?? defaultRedactHtmlForShare;
  const isSecretScanEnabled = deps.isSecretScanEnabled ?? secretScanEnabled;
  const isAutoRedactionEnabled = deps.isAutoRedactionEnabled ?? autoRedactionEnabled;
  const shouldBlockOnSecrets = deps.shouldBlockOnSecrets ?? blockOnSecretFindings;
  const redactionPolicy = normalizeRedactionPolicy(options.redactionPolicy);

  const sessionFile = session.getSessionStats().sessionFile;
  if (!sessionFile) {
    throw shareError(
      "session_not_persisted",
      "Cannot share this session because it has no persisted session file.",
    );
  }

  const tempDir =
    typeof deps.makeTempPath === "function" ? null : mkdtempSync(join(tmpdir(), "oppi-share-"));
  // The public share viewer expects the gist to contain a stable `session.html` file.
  // Keep the parent temp directory unique, but the uploaded filename deterministic.
  const tempHtmlPath =
    typeof deps.makeTempPath === "function"
      ? deps.makeTempPath()
      : join(tempDir ?? tmpdir(), "session.html");

  try {
    await exportSessionToHtml(session, tempHtmlPath);

    if (existsSync(tempHtmlPath)) {
      try {
        chmodSync(tempHtmlPath, 0o600);
      } catch {
        // Best-effort hardening on POSIX systems.
      }
    }

    let html = "";
    try {
      html = readFileSync(tempHtmlPath, "utf-8");
    } catch (error) {
      throw shareError(
        "share_export_failed",
        `Failed to read temporary share export: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    const redactionEnabled = isAutoRedactionEnabled();
    if (!redactionEnabled) {
      const sanitizedHtml = defaultSanitizeHtmlForShare(html, redactionPolicy);
      if (sanitizedHtml !== html) {
        html = sanitizedHtml;
        try {
          writeFileSync(tempHtmlPath, html, "utf-8");
        } catch (error) {
          throw shareError(
            "share_export_failed",
            `Failed to write sanitized share export: ${error instanceof Error ? error.message : String(error)}`,
          );
        }
      }
    }

    const scanEnabled = isSecretScanEnabled();
    const preRedactionFindings = scanEnabled ? scanHtmlForSecrets(html) : [];

    const redactionResult = redactionEnabled
      ? redactHtml(html, redactionPolicy)
      : {
          html,
          findings: [] as ShareRedactionFinding[],
          totalReplacements: 0,
        };

    if (redactionEnabled && redactionResult.html !== html) {
      html = redactionResult.html;
      try {
        writeFileSync(tempHtmlPath, html, "utf-8");
      } catch (error) {
        throw shareError(
          "share_export_failed",
          `Failed to write redacted share export: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }

    const residualFindings = scanEnabled ? scanHtmlForSecrets(html) : [];
    const blocked = residualFindings.length > 0 && shouldBlockOnSecrets();

    const artifact: ShareSessionArtifactSummary = {
      format: "html",
      bytes: Buffer.byteLength(html, "utf-8"),
    };

    const scan: ShareSessionScanSummary = {
      enabled: scanEnabled,
      blocked,
      findings: preRedactionFindings,
      residualFindings,
    };

    const redaction: ShareSessionRedactionSummary = {
      enabled: redactionEnabled,
      policy: redactionPolicy,
      totalReplacements: redactionResult.totalReplacements,
      findings: redactionResult.findings,
    };

    if (action === "prepare") {
      return {
        phase: "prepared",
        canPublish: !blocked,
        artifact,
        scan,
        redaction,
      };
    }

    if (blocked) {
      throw new ShareSessionError(
        "share_secret_detected",
        `Potential secrets remained after redaction (${summarizeFindings(residualFindings)}). Sharing blocked.`,
        residualFindings,
      );
    }

    ensureGhAuthenticated();

    const gist = await createSecretGist(tempHtmlPath);

    const gistUrl = parseGistUrl(gist.stdout) ?? parseGistUrl(gist.stderr);
    if (!gistUrl) {
      throw shareError("gist_parse_failed", "Failed to parse gist URL from gh output");
    }

    const gistId = parseGistId(gistUrl);
    if (!gistId) {
      throw shareError("gist_parse_failed", "Failed to parse gist ID from gist URL");
    }

    const warnings: string[] = [];
    if (redaction.totalReplacements > 0) {
      warnings.push(`auto_redaction_applied:${redaction.totalReplacements}`);
    }
    if (scan.residualFindings.length > 0) {
      warnings.push(`residual_secret_findings:${summarizeFindings(scan.residualFindings)}`);
    }

    const shareUrl = makeShareViewerUrl(gistId);
    return {
      shareUrl,
      gistUrl,
      gistId,
      phase: "published",
      share: {
        id: `share:${gistId}`,
        url: shareUrl,
        provider: "github_gist",
        providerRef: {
          gistId,
          gistUrl,
        },
      },
      artifact,
      scan,
      redaction,
      warnings,
    };
  } catch (error) {
    throw normalizeShareError(error);
  } finally {
    if (tempDir) {
      try {
        rmSync(tempDir, { recursive: true, force: true });
      } catch {
        // Best-effort cleanup.
      }
    } else if (existsSync(tempHtmlPath)) {
      try {
        unlinkSync(tempHtmlPath);
      } catch {
        // Best-effort cleanup.
      }
    }
  }
}

export const __shareSessionTestUtils = {
  parseGistUrl,
  parseGistId,
  defaultMakeShareViewerUrl,
  formatShareErrorMessage,
  defaultScanHtmlForSecrets,
  defaultRedactHtmlForShare,
  normalizeRedactionPolicy,
};
