import {
  applyRedactionPattern,
  mergeRedactionFinding,
  mergeSecretFinding,
  redactionPatternsForPolicy,
  scanTextForSecrets,
  type ShareRedactionPattern,
} from "./session-share-redaction-patterns.js";

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

export interface ShareHtmlRedactionResult {
  html: string;
  findings: ShareRedactionFinding[];
  totalReplacements: number;
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

export function secretScanEnabled(): boolean {
  return parseBoolEnv("OPPI_SHARE_SECRET_SCAN", true);
}

export function autoRedactionEnabled(): boolean {
  return parseBoolEnv("OPPI_SHARE_AUTO_REDACT", true);
}

export function blockOnSecretFindings(): boolean {
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

export function normalizeRedactionPolicy(
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

export function formatShareErrorMessage(code: ShareSessionErrorCode, message: string): string {
  const cleaned = message.replace(/\s+/g, " ").trim();
  return `${SHARE_ERROR_PREFIX}${code}] ${cleaned}`;
}

export function shareError(code: ShareSessionErrorCode, message: string): ShareSessionError {
  return new ShareSessionError(code, message);
}

export function summarizeFindings(findings: ShareSecretFinding[]): string {
  return findings.map((finding) => `${finding.kind}×${finding.count}`).join(", ");
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

  let json: string;
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

export function defaultSanitizeHtmlForShare(
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

export function defaultScanHtmlForSecrets(html: string): ShareSecretFinding[] {
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

export function defaultRedactHtmlForShare(
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
