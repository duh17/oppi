import type { ConfigStore } from "./config-store.js";

export class PreferenceStore {
  constructor(private readonly configStore: ConfigStore) {}

  getModelThinkingLevelPreference(modelId: string): string | undefined {
    const normalized = modelId.trim();
    if (!normalized) return undefined;
    return this.configStore.getConfig().thinkingLevelByModel?.[normalized];
  }

  setModelThinkingLevelPreference(modelId: string, level: string): void {
    const normalizedModel = modelId.trim();
    const normalizedLevel = level.trim();
    if (!normalizedModel || !normalizedLevel) return;

    const current = this.configStore.getConfig().thinkingLevelByModel || {};
    if (current[normalizedModel] === normalizedLevel) return;

    this.configStore.updateConfig({
      thinkingLevelByModel: { ...current, [normalizedModel]: normalizedLevel },
    });
  }
}
