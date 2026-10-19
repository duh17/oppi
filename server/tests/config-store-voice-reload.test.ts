import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import { ConfigStore } from "../src/storage/config-store.js";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("ConfigStore.readVoiceConfig", () => {
  it("sees voice settings another process saved after the server loaded its config", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-voice-reload-"));
    dirs.push(dataDir);
    const server = new ConfigStore(dataDir);
    server.updateConfig({
      asr: { sttEndpoint: "http://127.0.0.1:7946", liveVoiceBackend: "grok-voice" },
    });

    // `oppi config set` runs in its own process with its own store.
    const cli = new ConfigStore(dataDir);
    cli.updateConfig({
      asr: { sttEndpoint: "http://127.0.0.1:7936", liveVoiceBackend: "yuwp" },
      tts: { provider: "http", endpoint: "http://127.0.0.1:7938", voice: "elena" },
    });

    expect(server.getConfig().asr?.liveVoiceBackend).toBe("grok-voice");
    expect(server.readVoiceConfig()).toEqual({
      asr: { sttEndpoint: "http://127.0.0.1:7936", liveVoiceBackend: "yuwp" },
      tts: { provider: "http", endpoint: "http://127.0.0.1:7938", voice: "elena" },
    });
  });

  it("keeps the loaded voice settings when the file cannot be parsed", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-voice-reload-"));
    dirs.push(dataDir);
    const server = new ConfigStore(dataDir);
    server.updateConfig({ asr: { sttEndpoint: "http://127.0.0.1:7946" } });

    writeFileSync(server.getConfigPath(), "{ not json");

    expect(server.readVoiceConfig().asr?.sttEndpoint).toBe("http://127.0.0.1:7946");
  });
});
