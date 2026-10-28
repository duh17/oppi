import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { DefaultPackageManager, SettingsManager } from "@earendil-works/pi-coding-agent";

import { setUpAutoNamePackage } from "../src/auto-name-package.js";
import { Storage } from "../src/storage.js";
import {
  extractAutoTitle,
  readAutoTitleCarryover,
} from "../src/storage/auto-title-extension-migration.js";

const AUTO_NAME = join(import.meta.dirname, "../extensions/pi/auto-name");
const KEY = "auto_title_to_extension_v1";

let dataDir: string;
let agentDir: string;
beforeEach(() => {
  dataDir = mkdtempSync(join(tmpdir(), "auto-title-migration-data-"));
  agentDir = mkdtempSync(join(tmpdir(), "auto-title-migration-agent-"));
});
afterEach(() => {
  rmSync(dataDir, { recursive: true, force: true });
  rmSync(agentDir, { recursive: true, force: true });
});

/** A server data directory whose config.json carries `autoTitle`, as an older server wrote it. */
function seedConfig(autoTitle: unknown): void {
  const config = new Storage(dataDir).getConfig();
  writeFileSync(
    join(dataDir, "config.json"),
    JSON.stringify({ ...config, ...(autoTitle === undefined ? {} : { autoTitle }) }, null, 2),
  );
}

const readConfig = (): Record<string, unknown> =>
  JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8")) as Record<string, unknown>;

const readSettings = (): { packages?: unknown[] } & Record<string, unknown> =>
  JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8"));

/** `oppi serve`'s step, over a real migration ledger. */
async function serve(packageDir = AUTO_NAME): Promise<void> {
  const storage = new Storage(dataDir);
  await setUpAutoNamePackage({
    dataDir,
    agentDir,
    packageDir,
    once: (key, run) => storage.runMigrationOnce(key, run),
  });
}

/** Whether Pi resolves the package's extension as enabled, as the Extensions list asks it. */
async function piSeesEnabled(): Promise<boolean | undefined> {
  const settings = SettingsManager.create(agentDir, agentDir, { projectTrusted: false });
  const resolved = await new DefaultPackageManager({
    cwd: agentDir,
    agentDir,
    settingsManager: settings,
  }).resolve(async () => "skip");
  return resolved.extensions.find((resource) => resource.path.endsWith("auto-name/index.ts"))
    ?.enabled;
}

describe("autoTitle in config.json, before the config loads", () => {
  it("backs config.json up and carries a model that titled sessions", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5", revision: 3 });
    const before = readFileSync(join(dataDir, "config.json"), "utf8");

    const result = extractAutoTitle(dataDir);

    if (result.status !== "carried") throw new Error(result.status);
    expect(result.model).toBe("anthropic/claude-haiku-5");
    expect(result.backupPath).toContain(KEY);
    expect(readFileSync(result.backupPath, "utf8")).toBe(before);
    expect(statSync(result.backupPath).mode & 0o777).toBe(0o600);
    expect(readAutoTitleCarryover(dataDir)?.model).toBe("anthropic/claude-haiku-5");
    const config = readConfig();
    expect(config).not.toHaveProperty("autoTitle");
    expect(config).toHaveProperty("port");
  });

  it.each([
    ["off", { enabled: false, model: "anthropic/claude-haiku-5" }],
    ["on without a model, which titled nothing", { enabled: true }],
  ])("only drops auto-title that was %s", (_name, autoTitle) => {
    seedConfig(autoTitle);

    expect(extractAutoTitle(dataDir)).toMatchObject({ status: "dropped" });

    expect(readConfig()).not.toHaveProperty("autoTitle");
    expect(readAutoTitleCarryover(dataDir)).toBeUndefined();
  });

  it("is a no-op without autoTitle, and a second call finds nothing", () => {
    seedConfig(undefined);
    expect(extractAutoTitle(dataDir)).toEqual({ status: "none" });
    expect(existsSync(join(dataDir, "backups"))).toBe(false);

    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    extractAutoTitle(dataDir);
    expect(extractAutoTitle(dataDir)).toEqual({ status: "none" });
    expect(readdirSync(join(dataDir, "backups"))).toHaveLength(1);
  });

  it("runs wherever a config store is built, so a command before the first serve cannot drop it", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });

    // `oppi config get`, `oppi pair`: they build a Storage and never serve.
    new Storage(dataDir);

    expect(readdirSync(join(dataDir, "backups")).filter((name) => name.includes(KEY))).toHaveLength(
      1,
    );
    expect(readAutoTitleCarryover(dataDir)?.model).toBe("anthropic/claude-haiku-5");
    expect(readConfig()).not.toHaveProperty("autoTitle");
  });

  it("runs under the config lock, as every other config write does", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    const before = readFileSync(join(dataDir, "config.json"), "utf8");
    // A lock a dead process left behind: taking the lock fails at once.
    mkdirSync(join(dataDir, "config.json.lock"));
    writeFileSync(join(dataDir, "config.json.lock", "pid"), "2147483646\n");

    expect(() => new Storage(dataDir)).toThrow(/Stale config lock/);

    expect(readFileSync(join(dataDir, "config.json"), "utf8")).toBe(before);
    expect(existsSync(join(dataDir, "backups"))).toBe(false);
  });

  it("does not take the lock when there is nothing to carry over", () => {
    seedConfig(undefined);
    mkdirSync(join(dataDir, "config.json.lock"));
    writeFileSync(join(dataDir, "config.json.lock", "pid"), "2147483646\n");

    // Reading the config needs no lock: only a write waits on it.
    expect(() => new Storage(dataDir)).not.toThrow();
  });

  it("refuses to load the config when it cannot back it up, leaving it as it was", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    const before = readFileSync(join(dataDir, "config.json"), "utf8");
    writeFileSync(join(dataDir, "backups"), "a file where the backup directory goes");

    expect(() => new Storage(dataDir)).toThrow(/refusing to load the config/);

    expect(readFileSync(join(dataDir, "config.json"), "utf8")).toBe(before);
  });

  it("leaves an unreadable config to the config store", () => {
    writeFileSync(join(dataDir, "config.json"), "{ not json");
    expect(extractAutoTitle(dataDir)).toEqual({ status: "none" });
  });
});

describe("the shipped auto-name package in Pi's settings", () => {
  it("lists a fresh install's package as a disabled row, once", async () => {
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "mock" }));

    await serve();

    expect(readSettings()).toEqual({
      defaultProvider: "mock",
      packages: [{ source: AUTO_NAME, extensions: [] }],
    });
    expect(await piSeesEnabled()).toBe(false);

    // The user deletes the row: a later start does not bring it back.
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: [] }));
    await serve();
    expect(readSettings().packages).toEqual([]);
  });

  it("tries again at the next start when Pi's settings cannot be written, and keeps the carried model", async () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    new Storage(dataDir);
    writeFileSync(join(agentDir, "settings.json"), "{ not json");

    await serve(); // logged, never thrown: the server still starts

    expect(readAutoTitleCarryover(dataDir)?.model).toBe("anthropic/claude-haiku-5");

    writeFileSync(join(agentDir, "settings.json"), "{}");
    await serve();

    expect(readSettings().packages).toEqual([{ source: AUTO_NAME, extensions: ["+index.ts"] }]);
    expect(readAutoTitleCarryover(dataDir)).toBeUndefined();
  });

  it("carries the old setting over: its model in auto-name.json, the package listed on", async () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    new Storage(dataDir);

    await serve();

    expect(JSON.parse(readFileSync(join(agentDir, "auto-name.json"), "utf8"))).toEqual({
      model: "anthropic/claude-haiku-5",
    });
    expect(readSettings().packages).toEqual([{ source: AUTO_NAME, extensions: ["+index.ts"] }]);
    expect(await piSeesEnabled()).toBe(true);
    expect(readAutoTitleCarryover(dataDir)).toBeUndefined();

    await serve();
    expect(readSettings().packages).toHaveLength(1);
  });

  it("keeps the user's own model file", async () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    new Storage(dataDir);
    writeFileSync(join(agentDir, "auto-name.json"), '{"model":"openai/gpt-5-mini"}');

    await serve();

    expect(readFileSync(join(agentDir, "auto-name.json"), "utf8")).toBe(
      '{"model":"openai/gpt-5-mini"}',
    );
  });

  it("turns a row the user already has on, without adding a second", async () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    new Storage(dataDir);
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ packages: [{ source: AUTO_NAME, extensions: [] }] }),
    );

    await serve();

    expect(readSettings().packages).toEqual([{ source: AUTO_NAME, extensions: ["+index.ts"] }]);
  });

  it("points a copy whose path is gone at this install, keeping its on or off", async () => {
    const moved = "/gone/lib/node_modules/oppi-server/dist/extensions/pi/auto-name";
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({
        packages: [
          "npm:some-other-package",
          { source: moved, extensions: ["+index.ts"] },
          { source: "/gone/elsewhere", extensions: [] },
        ],
      }),
    );

    await serve();

    expect(readSettings().packages).toEqual([
      "npm:some-other-package",
      { source: AUTO_NAME, extensions: ["+index.ts"] },
      { source: "/gone/elsewhere", extensions: [] },
    ]);
  });

  it("leaves a copy that still exists alone", async () => {
    const other = join(dataDir, "other-install/extensions/pi/auto-name");
    mkdirSync(other, { recursive: true });
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ packages: [{ source: other, extensions: [] }] }),
    );

    await serve();

    expect(readSettings().packages).toEqual([{ source: other, extensions: [] }]);
  });

  it("does not list the package beside the user's own install of the extension", async () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    new Storage(dataDir);
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    symlinkSync(AUTO_NAME, join(agentDir, "extensions", "auto-name"));

    await serve();

    expect(existsSync(join(agentDir, "settings.json"))).toBe(false);
    expect(JSON.parse(readFileSync(join(agentDir, "auto-name.json"), "utf8")).model).toBe(
      "anthropic/claude-haiku-5",
    );
  });

  it("removes the shipped entry once the user links their own copy, so there is one", async () => {
    await serve();
    expect(readSettings().packages).toEqual([{ source: AUTO_NAME, extensions: [] }]);

    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    symlinkSync(AUTO_NAME, join(agentDir, "extensions", "auto-name"));
    await serve();

    expect(readSettings().packages).toEqual([]);
    // Nothing relists it beside the user's copy, and other entries stay.
    writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: ["npm:other"] }));
    await serve();
    expect(readSettings().packages).toEqual(["npm:other"]);
  });

  it("does nothing, and does not fail, when the install lacks the package", async () => {
    await serve(join(dataDir, "no-such-package"));
    expect(existsSync(join(agentDir, "settings.json"))).toBe(false);
  });
});
