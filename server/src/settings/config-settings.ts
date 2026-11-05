/**
 * Save contract for the settings stored in `config.json` and revisioned: Server Metrics
 * (`serverMetrics.enabled`), Durable Sessions (`experimental.serverDurable`), and the Mobile
 * Output Guide (`mobileOutputGuide.enabled`). A write is
 * validated through its registry definition by the route, then applied here under the config
 * lock. A `baseRevision` that is not the saved revision is refused and leaves the setting as it
 * is; omitting it keeps last-writer-wins.
 */
import type { ServerConfig } from "../types.js";
import { isRevision } from "./revision.js";
import { SettingValidationError, type EnabledPatch } from "./registry.js";

/** A setting as the API returns it: its value and the revision that saved it. */
export interface RevisionedEnabled {
  enabled: boolean;
  revision: number;
}

/** The Mobile Output Guide as it reads when nothing is saved (a fresh install). */
export const DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS: Readonly<RevisionedEnabled> = Object.freeze({
  enabled: false,
  revision: 0,
});

export type RevisionedConfigKey = "serverMetrics" | "durableSessions" | "mobileOutputGuide";

/** What a conflict names in `error`: `<name> setting changed`. */
const CONFLICT_LABELS: Record<RevisionedConfigKey, string> = {
  serverMetrics: "Server Metrics",
  durableSessions: "Durable Sessions",
  mobileOutputGuide: "Mobile Output Guide",
};

export type ConfigSettingResult =
  | { readonly ok: true; readonly current: RevisionedEnabled }
  | {
      readonly ok: false;
      readonly reason: "revision_conflict";
      readonly current: RevisionedEnabled;
    };

/** The config surface a settings write needs; `Storage` and `ConfigStore` consumers provide it. */
export interface ConfigSettingsWriter {
  mutateConfig(mutator: (latest: ServerConfig) => Partial<ServerConfig>): ServerConfig;
}

export function readConfigSetting(
  config: ServerConfig,
  key: RevisionedConfigKey,
): RevisionedEnabled {
  if (key === "durableSessions") {
    const experimental = config.experimental;
    return {
      enabled: experimental?.serverDurable === true,
      revision: experimental?.serverDurableRevision ?? 0,
    };
  }
  const saved = (key === "mobileOutputGuide" ? config.mobileOutputGuide : config.serverMetrics) ?? {
    enabled: false,
  };
  return { enabled: saved.enabled, revision: saved.revision ?? 0 };
}

/** The config fields that store `value` for `key`, keeping the rest of their block. */
function storedFields(
  latest: ServerConfig,
  key: RevisionedConfigKey,
  value: RevisionedEnabled,
): Partial<ServerConfig> {
  if (key === "durableSessions") {
    return {
      experimental: {
        ...latest.experimental,
        serverDurable: value.enabled,
        serverDurableRevision: value.revision,
      },
    };
  }
  const stored = { enabled: value.enabled, revision: value.revision };
  return key === "mobileOutputGuide" ? { mobileOutputGuide: stored } : { serverMetrics: stored };
}

/** `baseRevision` from a request body: absent is last-writer-wins, anything else must be a count. */
export function parseBaseRevision(value: unknown): number | undefined {
  if (value === undefined) return undefined;
  if (!isRevision(value)) {
    throw new SettingValidationError("baseRevision: expected a non-negative safe integer");
  }
  return value;
}

/** The 409 body for a stale write, the same shape for every revisioned setting. */
export function revisionConflictBody(
  key: RevisionedConfigKey,
  current: unknown,
): { error: string; code: "revision_conflict"; current: unknown } {
  return { error: `${CONFLICT_LABELS[key]} setting changed`, code: "revision_conflict", current };
}

/** Saves a patch that its registry definition already validated. */
export function applySetting(
  writer: ConfigSettingsWriter,
  key: RevisionedConfigKey,
  patch: EnabledPatch,
  baseRevision: number | undefined,
): ConfigSettingResult {
  const outcome: { conflict?: RevisionedEnabled } = {};
  const config = writer.mutateConfig((latest) => {
    const current = readConfigSetting(latest, key);
    if (baseRevision !== undefined && baseRevision !== current.revision) {
      outcome.conflict = current;
      return {};
    }
    return storedFields(latest, key, { enabled: patch.enabled, revision: current.revision + 1 });
  });
  if (outcome.conflict) {
    return { ok: false, reason: "revision_conflict", current: outcome.conflict };
  }
  return { ok: true, current: readConfigSetting(config, key) };
}
