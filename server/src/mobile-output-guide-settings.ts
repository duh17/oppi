export const MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION = 1 as const;
export const MOBILE_OUTPUT_GUIDE_SETTINGS_MAX_ERROR_LENGTH = 2048;

export interface MobileOutputGuideSettingsSnapshot {
  readonly enabled: boolean;
  readonly revision: number;
}

export interface MobileOutputGuideSettingsRecord extends MobileOutputGuideSettingsSnapshot {
  readonly version: typeof MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION;
}

export interface MobileOutputGuideSettingsReader {
  get(): MobileOutputGuideSettingsSnapshot;
  getLoadError(): string | undefined;
}

export const DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS: MobileOutputGuideSettingsSnapshot =
  Object.freeze({
    enabled: false,
    revision: 0,
  });

export class MobileOutputGuideSettingsValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MobileOutputGuideSettingsValidationError";
  }
}

export function validateMobileOutputGuideSettingsRecord(
  value: unknown,
): MobileOutputGuideSettingsRecord {
  if (!isRecord(value) || !hasExactKeys(value, ["version", "revision", "enabled"])) {
    throw new MobileOutputGuideSettingsValidationError(
      "settings: expected exactly version, revision, and enabled",
    );
  }
  if (value.version !== MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION) {
    throw new MobileOutputGuideSettingsValidationError(
      `version: expected ${MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION}`,
    );
  }
  assertRevision(value.revision, "revision");
  if (typeof value.enabled !== "boolean") {
    throw new MobileOutputGuideSettingsValidationError("enabled: expected boolean");
  }
  return Object.freeze({
    version: MOBILE_OUTPUT_GUIDE_SETTINGS_VERSION,
    revision: value.revision,
    enabled: value.enabled,
  });
}

export function validateMobileOutputGuideSettingsReplacement(
  value: unknown,
): Readonly<{ enabled: boolean }> {
  if (!isRecord(value) || !hasExactKeys(value, ["enabled"]) || typeof value.enabled !== "boolean") {
    throw new MobileOutputGuideSettingsValidationError(
      "replacement: expected exactly enabled as a boolean",
    );
  }
  return Object.freeze({ enabled: value.enabled });
}

export function validateMobileOutputGuideSettingsBaseRevision(value: unknown): number {
  assertRevision(value, "baseRevision");
  return value;
}

export function freezeMobileOutputGuideSettingsSnapshot(
  value: MobileOutputGuideSettingsSnapshot,
): MobileOutputGuideSettingsSnapshot {
  return Object.freeze({ enabled: value.enabled, revision: value.revision });
}

export function boundMobileOutputGuideSettingsError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const sanitized = Array.from(raw, (character) => {
    const code = character.charCodeAt(0);
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f) ? " " : character;
  })
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  return (sanitized || "unknown settings error").slice(
    0,
    MOBILE_OUTPUT_GUIDE_SETTINGS_MAX_ERROR_LENGTH,
  );
}

function assertRevision(value: unknown, field: string): asserts value is number {
  if (!Number.isSafeInteger(value) || (value as number) < 0) {
    throw new MobileOutputGuideSettingsValidationError(
      `${field}: expected a non-negative safe integer`,
    );
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}
