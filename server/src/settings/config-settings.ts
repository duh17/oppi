/**
 * Save contract for the settings stored in `config.json` and revisioned: auto-title and server
 * metrics. A write is validated through its registry definition by the route, then applied here
 * under the config lock. A `baseRevision` that is not the saved revision is refused and leaves
 * the setting as it is; omitting it keeps last-writer-wins.
 */
import type { ServerConfig } from "../types.js";
import {
  SettingValidationError,
  type AutoTitlePatch,
  type ServerMetricsPatch,
} from "./registry.js";

type AutoTitleSettings = NonNullable<ServerConfig["autoTitle"]>;
type ServerMetricsSettings = NonNullable<ServerConfig["serverMetrics"]>;

/** A setting as the API returns it: its value and the revision that saved it. */
export type RevisionedAutoTitle = AutoTitleSettings & { revision: number };
export type RevisionedServerMetrics = ServerMetricsSettings & { revision: number };

interface ConfigSettingShapes {
  autoTitle: { patch: AutoTitlePatch; saved: RevisionedAutoTitle };
  serverMetrics: { patch: ServerMetricsPatch; saved: RevisionedServerMetrics };
}

export type RevisionedConfigKey = keyof ConfigSettingShapes;

/** What a conflict names in `error`, matching the Mobile Output Guide's `<name> setting changed`. */
const CONFLICT_LABELS: Record<RevisionedConfigKey, string> = {
  autoTitle: "Auto-title",
  serverMetrics: "Server Metrics",
};

export type ConfigSettingResult<K extends RevisionedConfigKey> =
  | { readonly ok: true; readonly current: ConfigSettingShapes[K]["saved"] }
  | {
      readonly ok: false;
      readonly reason: "revision_conflict";
      readonly current: ConfigSettingShapes[K]["saved"];
    };

/** The config surface a settings write needs; `Storage` and `ConfigStore` consumers provide it. */
export interface ConfigSettingsWriter {
  mutateConfig(mutator: (latest: ServerConfig) => Partial<ServerConfig>): ServerConfig;
}

export function readConfigSetting<K extends RevisionedConfigKey>(
  config: ServerConfig,
  key: K,
): ConfigSettingShapes[K]["saved"] {
  if (key === "autoTitle") {
    const saved = config.autoTitle ?? { enabled: false };
    return { ...saved, revision: saved.revision ?? 0 } as ConfigSettingShapes[K]["saved"];
  }
  const saved = config.serverMetrics ?? { enabled: false };
  return { ...saved, revision: saved.revision ?? 0 } as ConfigSettingShapes[K]["saved"];
}

/** `baseRevision` from a request body: absent is last-writer-wins, anything else must be a count. */
export function parseBaseRevision(value: unknown): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new SettingValidationError("baseRevision: expected a non-negative safe integer");
  }
  return value;
}

/** The 409 body for a stale write, the same shape for every revisioned setting. */
export function revisionConflictBody(
  key: RevisionedConfigKey | "mobileOutputGuide",
  current: unknown,
): { error: string; code: "revision_conflict"; current: unknown } {
  const label = key === "mobileOutputGuide" ? "Mobile Output Guide" : CONFLICT_LABELS[key];
  return { error: `${label} setting changed`, code: "revision_conflict", current };
}

/** Saves a patch that its registry definition already validated. */
export function applySetting<K extends RevisionedConfigKey>(
  writer: ConfigSettingsWriter,
  key: K,
  patch: ConfigSettingShapes[K]["patch"],
  baseRevision: number | undefined,
): ConfigSettingResult<K> {
  const outcome: { conflict?: ConfigSettingShapes[K]["saved"] } = {};
  const config = writer.mutateConfig((latest) => {
    const current = readConfigSetting(latest, key);
    if (baseRevision !== undefined && baseRevision !== current.revision) {
      outcome.conflict = current;
      return {};
    }
    const revision = current.revision + 1;
    if (key === "autoTitle") {
      const next = patch as AutoTitlePatch;
      const saved = current as RevisionedAutoTitle;
      const model = next.model === undefined ? saved.model : (next.model ?? undefined);
      return {
        autoTitle: {
          enabled: next.enabled ?? saved.enabled,
          ...(model === undefined ? {} : { model }),
          revision,
        },
      };
    }
    return { serverMetrics: { enabled: (patch as ServerMetricsPatch).enabled, revision } };
  });
  if (outcome.conflict) {
    return { ok: false, reason: "revision_conflict", current: outcome.conflict };
  }
  return { ok: true, current: readConfigSetting(config, key) };
}
