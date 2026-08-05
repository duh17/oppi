import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { runCli } from "../src/cli/runner.js";
import { captureCliOutput } from "../src/cli/output.js";
import { cmdConfig } from "../src/cli/commands/config.js";
import { createCliConfigStorage } from "../src/cli/connection-config.js";

const dirs: string[] = [];

afterEach(() => {
  for (const dir of dirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
  process.exitCode = undefined;
});

function makeDataDir(): string {
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-cli-config-"));
  dirs.push(dataDir);
  return dataDir;
}

describe("config command agent safety", () => {
  it("returns pure JSON on errors and does not set process.exitCode under capture", async () => {
    const dataDir = makeDataDir();
    const before = process.exitCode;
    const result = await runCli(["config", "get", "missing.key"], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(result.ok).toBe(false);
    expect(result.exitCode).toBe(1);
    expect(process.exitCode).toBe(before);
    expect(() => JSON.parse(result.stdout)).not.toThrow();
    expect(result.stdout.trim().startsWith("{")).toBe(true);
    expect(result.stdout).not.toContain("✗");
    expect(result.humanOutput).toContain("unset");
  });

  it("redacts token on get/show while preserving non-secret values", async () => {
    const dataDir = makeDataDir();
    const storage = createCliConfigStorage(dataDir);
    storage.updateConfig({
      ...storage.getConfig(),
      token: "owner-secret-token",
      runtimeEnv: {
        OPENAI_API_KEY: "sk-test",
        TTS_BASE_URL: "http://127.0.0.1:7937",
      },
    });

    const getToken = await runCli(["config", "get", "token"], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(getToken.json).toMatchObject({
      ok: true,
      data: { key: "token", value: "[REDACTED]" },
    });

    const show = await runCli(["config", "show"], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(JSON.stringify(show.json)).toContain("[REDACTED]");
    expect(JSON.stringify(show.json)).not.toContain("owner-secret-token");
    expect(JSON.stringify(show.json)).toContain("http://127.0.0.1:7937");
  });

  it("keeps captured failures off the process exitCode", async () => {
    const dataDir = makeDataDir();
    const storage = createCliConfigStorage(dataDir);
    process.exitCode = undefined;
    await captureCliOutput(
      async () => {
        cmdConfig(storage, "get", ["does.not.exist"], { json: "true" });
      },
      { includeHuman: true },
    );
    expect(process.exitCode).toBeUndefined();
  });

  it("captures human output on successful config actions", async () => {
    const dataDir = makeDataDir();
    const storage = createCliConfigStorage(dataDir);
    storage.updateConfig({
      ...storage.getConfig(),
      runtimeEnv: { TTS_BASE_URL: "http://127.0.0.1:7937" },
    });

    const get = await runCli(["config", "get", "runtimeEnv.TTS_BASE_URL"], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(get.ok).toBe(true);
    expect(get.json).toMatchObject({
      ok: true,
      data: { key: "runtimeEnv.TTS_BASE_URL", value: "http://127.0.0.1:7937" },
    });
    expect(get.humanOutput).toContain("http://127.0.0.1:7937");

    const set = await runCli(
      ["config", "set", "runtimeEnv.TTS_BASE_URL", "http://127.0.0.1:7938"],
      {
        dataDir,
        captureHuman: true,
        forceJson: true,
      },
    );
    expect(set.ok).toBe(true);
    expect(set.json).toMatchObject({ ok: true, data: { key: "runtimeEnv.TTS_BASE_URL" } });
    expect(set.humanOutput).toContain("✓");
    expect(set.humanOutput).toContain("7938");
  });

  it("reports invalid validation as structured data with a clean JSON run", async () => {
    const dataDir = makeDataDir();
    const badPath = join(dataDir, "bad-config.json");
    writeFileSync(badPath, "{ not valid json");

    const result = await runCli(["config", "validate", "--config-file", badPath], {
      dataDir,
      captureHuman: true,
      forceJson: true,
    });
    expect(result.ok).toBe(true);
    expect(result.exitCode).toBe(0);
    expect(result.json).toMatchObject({
      ok: true,
      data: { path: badPath, valid: false },
    });
    expect(result.humanOutput).toContain("✗");
    expect(result.humanOutput).toContain("invalid JSON");
  });
});
