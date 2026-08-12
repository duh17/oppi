import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  DEFAULT_OPPI_EXTENSION_SETTINGS,
  type OppiExtensionSettingsSnapshot,
} from "../src/oppi-extension-settings.js";
import { Storage } from "../src/storage.js";
import {
  OppiExtensionSettingsPersistenceError,
  OppiExtensionSettingsStore,
  type OppiExtensionSettingsAtomicOperations,
} from "../src/storage/oppi-extension-settings-store.js";

const roots: string[] = [];

function makeRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-extension-settings-store-"));
  roots.push(root);
  return root;
}

function settingsPath(root: string): string {
  return join(root, "extensions", "oppi.json");
}

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe("OppiExtensionSettingsStore", () => {
  it("uses frozen off-by-default settings without writing a missing file", () => {
    const root = makeRoot();
    const store = new OppiExtensionSettingsStore(root);

    const first = store.get();
    const second = store.get();

    expect(first).toEqual(DEFAULT_OPPI_EXTENSION_SETTINGS);
    expect(first).not.toBe(second);
    expect(Object.isFrozen(first)).toBe(true);
    expect(store.getLoadError()).toBeUndefined();
    expect(existsSync(settingsPath(root))).toBe(false);
    expect(existsSync(join(root, "extensions"))).toBe(false);
  });

  it.each([
    ["invalid JSON", "{"],
    [
      "wrong version",
      JSON.stringify({
        version: 3,
        revision: 4,
        enabled: true,
        approvalPolicy: "readOnly",
        mobileOutputGuideEnabled: true,
      }),
    ],
    [
      "unknown field",
      JSON.stringify({
        version: 1,
        revision: 4,
        enabled: true,
        approvalPolicy: "readOnly",
        extra: true,
      }),
    ],
    [
      "invalid revision",
      JSON.stringify({ version: 1, revision: -1, enabled: true, approvalPolicy: "readOnly" }),
    ],
    [
      "invalid policy",
      JSON.stringify({ version: 1, revision: 4, enabled: true, approvalPolicy: "sometimes" }),
    ],
  ])("fails closed for %s and exposes one bounded load error", (_label, contents) => {
    const root = makeRoot();
    mkdirSync(join(root, "extensions"), { recursive: true });
    writeFileSync(settingsPath(root), contents);

    const store = new OppiExtensionSettingsStore(root);

    expect(store.get()).toEqual(DEFAULT_OPPI_EXTENSION_SETTINGS);
    expect(store.getLoadError()).toBeTypeOf("string");
    expect(store.getLoadError()?.length).toBeLessThanOrEqual(2048);
    expect(readFileSync(settingsPath(root), "utf8")).toBe(contents);
  });

  it("decodes v1 records as guide-off without rewriting them on load", () => {
    const root = makeRoot();
    const contents = JSON.stringify({
      version: 1,
      revision: 4,
      enabled: true,
      approvalPolicy: "readOnly",
    });
    mkdirSync(join(root, "extensions"), { recursive: true });
    writeFileSync(settingsPath(root), contents);

    const store = new OppiExtensionSettingsStore(root);

    expect(store.get()).toEqual({
      enabled: true,
      approvalPolicy: "readOnly",
      mobileOutputGuideEnabled: false,
      revision: 4,
    });
    expect(readFileSync(settingsPath(root), "utf8")).toBe(contents);
  });

  it("performs full-snapshot CAS replacement with one winner and owner-only modes", async () => {
    const root = makeRoot();
    const store = new OppiExtensionSettingsStore(root);

    const [first, second] = await Promise.all([
      Promise.resolve().then(() =>
        store.replace(0, { enabled: true, approvalPolicy: "confirmAllChanges" }),
      ),
      Promise.resolve().then(() => store.replace(0, { enabled: true, approvalPolicy: "readOnly" })),
    ]);

    const winners = [first, second].filter((result) => result.ok);
    const conflicts = [first, second].filter((result) => !result.ok);
    expect(winners).toHaveLength(1);
    expect(conflicts).toHaveLength(1);

    const current = store.get();
    expect(current.revision).toBe(1);
    expect(conflicts[0]).toEqual({ ok: false, reason: "revision_conflict", current });
    expect(Object.isFrozen(current)).toBe(true);
    expect(statSync(join(root, "extensions")).mode & 0o777).toBe(0o700);
    expect(statSync(settingsPath(root)).mode & 0o777).toBe(0o600);
    expect(JSON.parse(readFileSync(settingsPath(root), "utf8"))).toEqual({
      version: 2,
      ...current,
    });
  });

  it("allows an explicit revision-zero replacement to repair malformed data", () => {
    const root = makeRoot();
    mkdirSync(join(root, "extensions"), { recursive: true });
    writeFileSync(settingsPath(root), "not json");
    const store = new OppiExtensionSettingsStore(root);

    const result = store.replace(0, { enabled: true, approvalPolicy: "readOnly" });

    expect(result).toEqual({
      ok: true,
      current: {
        enabled: true,
        approvalPolicy: "readOnly",
        mobileOutputGuideEnabled: false,
        revision: 1,
      },
    });
    expect(store.getLoadError()).toBeUndefined();
  });

  it.each(["write", "fsync", "rename"] as const)(
    "rolls back memory and disk when atomic %s fails",
    (failedOperation) => {
      const root = makeRoot();
      const baselineStore = new OppiExtensionSettingsStore(root);
      const baselineResult = baselineStore.replace(0, {
        enabled: true,
        approvalPolicy: "confirmAllChanges",
        mobileOutputGuideEnabled: true,
      });
      expect(baselineResult.ok).toBe(true);
      const before = readFileSync(settingsPath(root), "utf8");
      const baseline = baselineStore.get();

      const operations: Partial<OppiExtensionSettingsAtomicOperations> = {
        [failedOperation]: () => {
          throw new Error(`${failedOperation} failed`);
        },
      };
      const failingStore = new OppiExtensionSettingsStore(root, { operations });

      expect(() => failingStore.replace(1, { enabled: false, approvalPolicy: "readOnly" })).toThrow(
        OppiExtensionSettingsPersistenceError,
      );
      expect(failingStore.get()).toEqual(baseline);
      expect(readFileSync(settingsPath(root), "utf8")).toBe(before);
      // Unique temporary files must be removed on every failure path.
      expect(readdirSync(join(root, "extensions"))).toEqual(["oppi.json"]);
    },
  );

  it("is owned through Storage without widening ServerConfig", () => {
    const root = makeRoot();
    const storage = new Storage(root);

    expect(storage.getOppiExtensionSettings()).toEqual(DEFAULT_OPPI_EXTENSION_SETTINGS);
    expect(
      storage.replaceOppiExtensionSettings(0, {
        enabled: true,
        approvalPolicy: "confirmAllChanges",
      }),
    ).toEqual({
      ok: true,
      current: {
        enabled: true,
        approvalPolicy: "confirmAllChanges",
        mobileOutputGuideEnabled: false,
        revision: 1,
      },
    });
    expect(storage.getConfig()).not.toHaveProperty("oppiExtensionSettings");
    expect(new Storage(root).getOppiExtensionSettings()).toEqual({
      enabled: true,
      approvalPolicy: "confirmAllChanges",
      mobileOutputGuideEnabled: false,
      revision: 1,
    });
  });

  it("rejects incomplete or malformed replacement snapshots without changing authority", () => {
    const root = makeRoot();
    const store = new OppiExtensionSettingsStore(root);
    const before: OppiExtensionSettingsSnapshot = store.get();

    expect(() => store.replace(0, { enabled: true } as never)).toThrow(/approvalPolicy/);
    expect(() => store.replace(-1, { enabled: true, approvalPolicy: "readOnly" })).toThrow(
      /baseRevision/,
    );
    expect(store.get()).toEqual(before);
    expect(existsSync(settingsPath(root))).toBe(false);
  });
});
