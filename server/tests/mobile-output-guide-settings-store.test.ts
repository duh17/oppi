import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS,
  type MobileOutputGuideSettingsSnapshot,
} from "../src/mobile-output-guide-settings.js";
import { Storage } from "../src/storage.js";
import { MobileOutputGuideSettingsStore } from "../src/storage/mobile-output-guide-settings-store.js";

const roots: string[] = [];

function makeRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-mobile-output-guide-settings-"));
  roots.push(root);
  return root;
}

function settingsPath(root: string): string {
  return join(root, "settings", "mobile-output-guide.json");
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("MobileOutputGuideSettingsStore", () => {
  it("uses a frozen off-by-default snapshot without writing a missing file", () => {
    const root = makeRoot();
    const store = new MobileOutputGuideSettingsStore(root);

    expect(store.get()).toEqual(DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS);
    expect(Object.isFrozen(store.get())).toBe(true);
    expect(existsSync(settingsPath(root))).toBe(false);
  });

  it("CAS-replaces only guide availability with owner-only persistence", () => {
    const root = makeRoot();
    const store = new MobileOutputGuideSettingsStore(root);

    expect(store.replace(0, { enabled: true })).toEqual({
      ok: true,
      current: { enabled: true, revision: 1 },
    });
    expect(store.replace(0, { enabled: false })).toEqual({
      ok: false,
      reason: "revision_conflict",
      current: { enabled: true, revision: 1 },
    });
    expect(JSON.parse(readFileSync(settingsPath(root), "utf8"))).toEqual({
      version: 1,
      enabled: true,
      revision: 1,
    });
    expect(statSync(join(root, "settings")).mode & 0o777).toBe(0o700);
    expect(statSync(settingsPath(root)).mode & 0o777).toBe(0o600);
  });

  it("is owned through Storage without widening ServerConfig", () => {
    const root = makeRoot();
    const storage = new Storage(root);

    expect(storage.getMobileOutputGuideSettings()).toEqual(DEFAULT_MOBILE_OUTPUT_GUIDE_SETTINGS);
    expect(storage.replaceMobileOutputGuideSettings(0, { enabled: true })).toEqual({
      ok: true,
      current: { enabled: true, revision: 1 },
    });
    expect(storage.getConfig()).not.toHaveProperty("mobileOutputGuide");
    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 1,
    } satisfies MobileOutputGuideSettingsSnapshot);
  });
});
