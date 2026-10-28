import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { Storage } from "../src/storage.js";
import { runAutoTitleToExtensionMigration } from "../src/storage/auto-title-extension-migration.js";

const AUTO_NAME = join(import.meta.dirname, "../extensions/pi/auto-name");

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

const migrate = () =>
  runAutoTitleToExtensionMigration({ dataDir, agentDir, packageDir: AUTO_NAME });

describe("auto-title → auto-name extension migration", () => {
  it("enables the extension with its model for a server that had auto-title on", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5", revision: 3 });

    const result = migrate();

    expect(result).toMatchObject({ status: "enabled", model: "anthropic/claude-haiku-5" });
    // Pi loads a package linked into its extensions directory, for every session.
    const link = join(agentDir, "extensions", "auto-name");
    expect(lstatSync(link).isSymbolicLink()).toBe(true);
    expect(realpathSync(link)).toBe(realpathSync(AUTO_NAME));
    expect(JSON.parse(readFileSync(join(agentDir, "auto-name.json"), "utf8"))).toEqual({
      model: "anthropic/claude-haiku-5",
    });
    // The server's own config no longer has it, and keeps everything else.
    const config = readConfig();
    expect(config).not.toHaveProperty("autoTitle");
    expect(config).toHaveProperty("port");
  });

  it("backs config.json up before changing it, keyed by the migration", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    const before = readFileSync(join(dataDir, "config.json"), "utf8");

    const result = migrate();

    if (result.status === "none" || result.status === "failed") throw new Error(result.status);
    expect(result.backupPath).toContain("auto_title_to_extension_v1");
    expect(readFileSync(result.backupPath, "utf8")).toBe(before);
    expect(statSync(result.backupPath).mode & 0o777).toBe(0o600);
  });

  it.each([
    ["off", { enabled: false, model: "anthropic/claude-haiku-5" }],
    ["on without a model, which titled nothing", { enabled: true }],
  ])("only drops auto-title that was %s", (_name, autoTitle) => {
    seedConfig(autoTitle);

    expect(migrate()).toMatchObject({ status: "dropped" });

    expect(readConfig()).not.toHaveProperty("autoTitle");
    expect(existsSync(join(agentDir, "extensions"))).toBe(false);
    expect(existsSync(join(agentDir, "auto-name.json"))).toBe(false);
  });

  it("does nothing for a config without auto-title, and a second start finds nothing", () => {
    seedConfig(undefined);
    expect(migrate()).toEqual({ status: "none" });
    expect(existsSync(join(dataDir, "backups"))).toBe(false);

    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    migrate();
    expect(migrate()).toEqual({ status: "none" });
    expect(readdirSync(join(dataDir, "backups"))).toHaveLength(1);
  });

  it("keeps the user's own install and model file", () => {
    mkdirSync(join(agentDir, "extensions"), { recursive: true });
    symlinkSync("/somewhere/else", join(agentDir, "extensions", "auto-name"));
    writeFileSync(join(agentDir, "auto-name.json"), '{"model":"openai/gpt-5-mini"}');
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });

    expect(migrate()).toMatchObject({ status: "enabled" });

    expect(readFileSync(join(agentDir, "auto-name.json"), "utf8")).toBe(
      '{"model":"openai/gpt-5-mini"}',
    );
    expect(lstatSync(join(agentDir, "extensions", "auto-name")).isSymbolicLink()).toBe(true);
  });

  it("leaves the config and Pi untouched when the package is missing from the install", () => {
    seedConfig({ enabled: true, model: "anthropic/claude-haiku-5" });
    const before = readFileSync(join(dataDir, "config.json"), "utf8");

    const result = runAutoTitleToExtensionMigration({
      dataDir,
      agentDir,
      packageDir: join(dataDir, "no-such-package"),
    });

    expect(result).toMatchObject({ status: "failed", error: expect.stringContaining("missing") });
    expect(readFileSync(join(dataDir, "config.json"), "utf8")).toBe(before);
    expect(existsSync(join(agentDir, "auto-name.json"))).toBe(false);
    // The copy survives for the user to restore from.
    expect(result.status === "failed" && result.backupPath && existsSync(result.backupPath)).toBe(
      true,
    );
  });

  it("leaves an unreadable config to the config store", () => {
    writeFileSync(join(dataDir, "config.json"), "{ not json");
    expect(migrate()).toEqual({ status: "none" });
  });
});
