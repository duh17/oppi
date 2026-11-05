import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { applySetting } from "../src/settings/config-settings.js";
import { Storage } from "../src/storage.js";

const roots: string[] = [];

function makeRoot(): string {
  const root = mkdtempSync(join(tmpdir(), "oppi-mobile-output-guide-"));
  roots.push(root);
  return root;
}

const legacyPath = (root: string): string => join(root, "settings", "mobile-output-guide.json");
const migratedPath = (root: string): string => `${legacyPath(root)}.migrated`;

function writeLegacy(root: string, contents: unknown): void {
  mkdirSync(join(root, "settings"), { recursive: true });
  writeFileSync(
    legacyPath(root),
    typeof contents === "string" ? contents : JSON.stringify(contents),
  );
}

function savedInConfig(root: string): unknown {
  return JSON.parse(readFileSync(join(root, "config.json"), "utf8")).mobileOutputGuide;
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe("Mobile Output Guide setting in config.json", () => {
  it("reads off at revision 0 on a fresh install and writes nothing for it", () => {
    const root = makeRoot();
    const storage = new Storage(root);

    expect(storage.getMobileOutputGuideSettings()).toEqual({ enabled: false, revision: 0 });
    expect(savedInConfig(root)).toBeUndefined();
    expect(existsSync(legacyPath(root))).toBe(false);
  });

  it("saves through the revisioned path, survives a reload, and refuses a stale revision", () => {
    const root = makeRoot();
    const storage = new Storage(root);

    expect(applySetting(storage, "mobileOutputGuide", { enabled: true }, 0)).toEqual({
      ok: true,
      current: { enabled: true, revision: 1 },
    });
    expect(applySetting(storage, "mobileOutputGuide", { enabled: false }, 0)).toEqual({
      ok: false,
      reason: "revision_conflict",
      current: { enabled: true, revision: 1 },
    });
    expect(savedInConfig(root)).toEqual({ enabled: true, revision: 1 });
    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 1,
    });
  });

  it("carries the old settings file's value and revision into config.json, then retires the file", () => {
    const root = makeRoot();
    writeLegacy(root, { version: 1, enabled: true, revision: 4 });

    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 4,
    });
    expect(savedInConfig(root)).toEqual({ enabled: true, revision: 4 });
    expect(existsSync(legacyPath(root))).toBe(false);
    expect(existsSync(migratedPath(root))).toBe(true);

    // A second load finds nothing to do and keeps the carried value.
    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 4,
    });
  });

  it("keeps a value already in config.json over a stale old file and still retires the file", () => {
    const root = makeRoot();
    const first = new Storage(root);
    applySetting(first, "mobileOutputGuide", { enabled: true }, 0);
    writeLegacy(root, { version: 1, enabled: false, revision: 9 });

    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 1,
    });
    expect(existsSync(legacyPath(root))).toBe(false);
  });

  it("starts with the guide off and leaves an unreadable old file in place", () => {
    const root = makeRoot();
    writeLegacy(root, "{ not json");

    const storage = new Storage(root);

    expect(storage.getMobileOutputGuideSettings()).toEqual({ enabled: false, revision: 0 });
    expect(savedInConfig(root)).toBeUndefined();
    expect(existsSync(legacyPath(root))).toBe(true);

    // A save writes config.json, so the next load retires the leftover file.
    applySetting(storage, "mobileOutputGuide", { enabled: true }, 0);
    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 1,
    });
    expect(existsSync(legacyPath(root))).toBe(false);
  });

  it("treats an old file of the wrong shape as unreadable", () => {
    const root = makeRoot();
    writeLegacy(root, { version: 2, enabled: true, revision: 1 });

    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: false,
      revision: 0,
    });
    expect(existsSync(legacyPath(root))).toBe(true);
  });

  it("leaves config.json and the old file alone while config.json has invalid fields", () => {
    const root = makeRoot();
    new Storage(root);
    const invalid = JSON.parse(readFileSync(join(root, "config.json"), "utf8"));
    invalid.port = 70_000;
    writeFileSync(join(root, "config.json"), JSON.stringify(invalid));
    const before = readFileSync(join(root, "config.json"));
    writeLegacy(root, { version: 1, enabled: true, revision: 4 });

    const storage = new Storage(root);

    expect(storage.getMobileOutputGuideSettings()).toEqual({ enabled: false, revision: 0 });
    expect(readFileSync(join(root, "config.json")).equals(before)).toBe(true);
    expect(existsSync(legacyPath(root))).toBe(true);
    expect(existsSync(migratedPath(root))).toBe(false);
  });

  it("keeps an earlier .migrated copy and gives this one a timestamped name", () => {
    const root = makeRoot();
    new Storage(root);
    writeLegacy(root, { version: 1, enabled: true, revision: 2 });
    writeFileSync(migratedPath(root), "earlier copy");

    expect(new Storage(root).getMobileOutputGuideSettings()).toEqual({
      enabled: true,
      revision: 2,
    });

    expect(readFileSync(migratedPath(root), "utf8")).toBe("earlier copy");
    expect(existsSync(legacyPath(root))).toBe(false);
    const extra = readdirSync(join(root, "settings")).filter((name) =>
      /^mobile-output-guide\.json\.migrated\.\d+$/.test(name),
    );
    expect(extra).toHaveLength(1);
    expect(JSON.parse(readFileSync(join(root, "settings", extra[0]), "utf8"))).toEqual({
      version: 1,
      enabled: true,
      revision: 2,
    });
  });
});
