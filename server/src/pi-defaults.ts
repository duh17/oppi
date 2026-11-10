import type { SettingsManager } from "@earendil-works/pi-coding-agent";

/**
 * Pi 1.5.1 made `cacheWarming` default to "idle", which spends money keeping caches warm between
 * runs. An update of Pi must not change what a session costs, so unless the owner set it in Pi's
 * settings, a session keeps the earlier default ("streaming"). The owner's settings file is never
 * written: the manager just answers for the unset value.
 */
export function keepPreviousPiDefaults(settings: SettingsManager): SettingsManager {
  const current = settings.getCacheWarmingMode.bind(settings);
  settings.getCacheWarmingMode = () =>
    settings.getGlobalSettings().cacheWarming === undefined ? "streaming" : current();
  return settings;
}
