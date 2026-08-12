export const OPPI_EXTENSION_SETTINGS_VERSION = 2 as const;
const PREVIOUS_OPPI_EXTENSION_SETTINGS_VERSION = 1 as const;
export const OPPI_EXTENSION_SETTINGS_MAX_ERROR_LENGTH = 2048;

export type OppiApprovalPolicy = "confirmDestructiveOnly" | "confirmAllChanges" | "readOnly";

export interface OppiExtensionSettingsSnapshot {
  readonly enabled: boolean;
  readonly approvalPolicy: OppiApprovalPolicy;
  readonly mobileOutputGuideEnabled: boolean;
  readonly revision: number;
}

export interface OppiExtensionSettingsRecord extends OppiExtensionSettingsSnapshot {
  readonly version: typeof OPPI_EXTENSION_SETTINGS_VERSION;
}

export interface OppiExtensionSettingsReplacement {
  readonly enabled: boolean;
  readonly approvalPolicy: OppiApprovalPolicy;
  /** Optional so older Apple clients can keep using the full-CAS route. */
  readonly mobileOutputGuideEnabled?: boolean;
}

export interface OppiExtensionSettingsReader {
  get(): OppiExtensionSettingsSnapshot;
  getLoadError(): string | undefined;
}

export const DEFAULT_OPPI_EXTENSION_SETTINGS: OppiExtensionSettingsSnapshot = Object.freeze({
  enabled: false,
  approvalPolicy: "confirmDestructiveOnly",
  mobileOutputGuideEnabled: false,
  revision: 0,
});

export function isOppiApprovalPolicy(value: unknown): value is OppiApprovalPolicy {
  return (
    value === "confirmDestructiveOnly" || value === "confirmAllChanges" || value === "readOnly"
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

function assertRevision(value: unknown, field: string): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new OppiExtensionSettingsValidationError(
      `${field}: expected a non-negative safe integer`,
    );
  }
}

export class OppiExtensionSettingsValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "OppiExtensionSettingsValidationError";
  }
}

export function validateOppiExtensionSettingsRecord(value: unknown): OppiExtensionSettingsRecord {
  if (!isRecord(value)) {
    throw new OppiExtensionSettingsValidationError("settings: expected an object");
  }

  const isPreviousVersion = value.version === PREVIOUS_OPPI_EXTENSION_SETTINGS_VERSION;
  if (
    !hasExactKeys(
      value,
      isPreviousVersion
        ? ["version", "revision", "enabled", "approvalPolicy"]
        : ["version", "revision", "enabled", "approvalPolicy", "mobileOutputGuideEnabled"],
    )
  ) {
    throw new OppiExtensionSettingsValidationError(
      isPreviousVersion
        ? "settings: expected exactly version, revision, enabled, and approvalPolicy"
        : "settings: expected exactly version, revision, enabled, approvalPolicy, and mobileOutputGuideEnabled",
    );
  }
  if (!isPreviousVersion && value.version !== OPPI_EXTENSION_SETTINGS_VERSION) {
    throw new OppiExtensionSettingsValidationError(
      `version: expected ${OPPI_EXTENSION_SETTINGS_VERSION}`,
    );
  }
  assertRevision(value.revision, "revision");
  if (typeof value.enabled !== "boolean") {
    throw new OppiExtensionSettingsValidationError("enabled: expected boolean");
  }
  if (!isOppiApprovalPolicy(value.approvalPolicy)) {
    throw new OppiExtensionSettingsValidationError(
      "approvalPolicy: expected confirmDestructiveOnly, confirmAllChanges, or readOnly",
    );
  }
  if (!isPreviousVersion && typeof value.mobileOutputGuideEnabled !== "boolean") {
    throw new OppiExtensionSettingsValidationError("mobileOutputGuideEnabled: expected boolean");
  }

  return Object.freeze({
    version: OPPI_EXTENSION_SETTINGS_VERSION,
    revision: value.revision,
    enabled: value.enabled,
    approvalPolicy: value.approvalPolicy,
    // Existing v1 records migrate in memory with the guide disabled.
    mobileOutputGuideEnabled: isPreviousVersion
      ? false
      : (value.mobileOutputGuideEnabled as boolean),
  });
}

export function validateOppiExtensionSettingsReplacement(
  value: unknown,
): OppiExtensionSettingsReplacement {
  if (!isRecord(value)) {
    throw new OppiExtensionSettingsValidationError("replacement: expected an object");
  }
  const hasGuide = Object.prototype.hasOwnProperty.call(value, "mobileOutputGuideEnabled");
  if (
    !hasExactKeys(
      value,
      hasGuide
        ? ["enabled", "approvalPolicy", "mobileOutputGuideEnabled"]
        : ["enabled", "approvalPolicy"],
    )
  ) {
    throw new OppiExtensionSettingsValidationError(
      hasGuide
        ? "replacement: expected exactly enabled, approvalPolicy, and mobileOutputGuideEnabled"
        : "replacement: expected exactly enabled and approvalPolicy",
    );
  }
  if (typeof value.enabled !== "boolean") {
    throw new OppiExtensionSettingsValidationError("enabled: expected boolean");
  }
  if (!isOppiApprovalPolicy(value.approvalPolicy)) {
    throw new OppiExtensionSettingsValidationError(
      "approvalPolicy: expected confirmDestructiveOnly, confirmAllChanges, or readOnly",
    );
  }
  if (hasGuide && typeof value.mobileOutputGuideEnabled !== "boolean") {
    throw new OppiExtensionSettingsValidationError("mobileOutputGuideEnabled: expected boolean");
  }
  return Object.freeze({
    enabled: value.enabled,
    approvalPolicy: value.approvalPolicy,
    ...(hasGuide ? { mobileOutputGuideEnabled: value.mobileOutputGuideEnabled as boolean } : {}),
  });
}

export function validateOppiExtensionSettingsBaseRevision(value: unknown): number {
  assertRevision(value, "baseRevision");
  return value;
}

export function freezeOppiExtensionSettingsSnapshot(
  value: OppiExtensionSettingsSnapshot,
): OppiExtensionSettingsSnapshot {
  return Object.freeze({
    enabled: value.enabled,
    approvalPolicy: value.approvalPolicy,
    mobileOutputGuideEnabled: value.mobileOutputGuideEnabled ?? false,
    revision: value.revision,
  });
}

function replaceControlCharacters(value: string): string {
  return Array.from(value, (character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f) ? " " : character;
  }).join("");
}

export function boundOppiExtensionSettingsError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const sanitized = replaceControlCharacters(raw).replace(/\s+/g, " ").trim();
  const message = sanitized || "unknown settings error";
  return message.slice(0, OPPI_EXTENSION_SETTINGS_MAX_ERROR_LENGTH);
}
