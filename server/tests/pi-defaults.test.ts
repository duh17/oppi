import { SettingsManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { keepPreviousPiDefaults } from "../src/pi-defaults.js";

describe("Pi defaults an update must not change", () => {
  it("keeps cache warming on the earlier default unless the owner chose one", () => {
    expect(keepPreviousPiDefaults(SettingsManager.inMemory({})).getCacheWarmingMode()).toBe(
      "streaming",
    );
    expect(
      keepPreviousPiDefaults(
        SettingsManager.inMemory({ cacheWarming: "idle" }),
      ).getCacheWarmingMode(),
    ).toBe("idle");
  });
});
