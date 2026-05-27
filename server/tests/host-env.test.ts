import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  applyHostEnv,
  buildHostEnv,
  resolveExecutableOnPath,
  resolveHostEnv,
} from "../src/host-env.js";
import type { ServerConfig } from "../src/types.js";

function makeConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    port: 3000,
    host: "127.0.0.1",
    dataDir: "/tmp/oppi-test",
    sessionIdleTimeoutMs: 1,
    workspaceIdleTimeoutMs: 1,
    maxSessionsPerWorkspace: 1,
    maxSessionsGlobal: 1,
    runtimePathEntries: [],
    runtimeEnv: {},
    ...overrides,
  };
}

afterEach(() => {
  delete process.env.RUNTIME_ONLY;
  delete process.env.RUNTIME_OVERRIDE;
  delete process.env.EDITOR;
  process.env.PATH = "/usr/bin:/bin";
});

describe("buildHostEnv", () => {
  it("uses only configured PATH entries", () => {
    const env = buildHostEnv(makeConfig({ runtimePathEntries: ["/custom/bin", "/usr/bin"] }));
    expect(env.PATH).toBe("/custom/bin:/usr/bin");
  });

  it("deduplicates and normalizes configured PATH entries", () => {
    const env = buildHostEnv(
      makeConfig({ runtimePathEntries: ["/usr/bin", "/usr/bin", " /bin ", ""] }),
    );
    expect(env.PATH).toBe("/usr/bin:/bin");
  });

  it("applies runtimeEnv overrides", () => {
    const env = buildHostEnv(makeConfig({ runtimeEnv: { EDITOR: "nvim", LANG: "en_US.UTF-8" } }));
    expect(env.EDITOR).toBe("nvim");
    expect(env.LANG).toBe("en_US.UTF-8");
  });

  it("is stable against prior apply mutations", () => {
    const baseEnv = {
      PATH: "/usr/bin:/bin",
      RUNTIME_OVERRIDE: "base",
    };

    process.env.RUNTIME_OVERRIDE = "mutated";

    const env = buildHostEnv(
      makeConfig({
        runtimePathEntries: ["/custom/bin"],
        runtimeEnv: { RUNTIME_ONLY: "enabled" },
      }),
      baseEnv,
    );

    expect(env.PATH).toBe("/custom/bin");
    expect(env.RUNTIME_OVERRIDE).toBe("base");
    expect(env.RUNTIME_ONLY).toBe("enabled");
  });
});

describe("resolveHostEnv", () => {
  it("returns configured path entries and merged env", () => {
    const resolved = resolveHostEnv(makeConfig({ runtimePathEntries: ["/a", "/b"] }));
    expect(resolved.configuredPathEntries).toEqual(["/a", "/b"]);
    expect(resolved.env.PATH).toBe("/a:/b");
  });
});

describe("applyHostEnv", () => {
  it("applies configured env to process.env", () => {
    const resolved = applyHostEnv(
      makeConfig({ runtimePathEntries: ["/apply/bin"], runtimeEnv: { EDITOR: "helix" } }),
    );

    expect(process.env.PATH).toBe("/apply/bin");
    expect(process.env.EDITOR).toBe("helix");
    expect(resolved.env.EDITOR).toBe("helix");
  });

  it("restores removed runtime env keys to the base environment on reload", () => {
    const baseEnv = {
      PATH: "/usr/bin:/bin",
      RUNTIME_OVERRIDE: "base",
    };

    applyHostEnv(
      makeConfig({
        runtimePathEntries: ["/custom/bin"],
        runtimeEnv: {
          RUNTIME_ONLY: "enabled",
          RUNTIME_OVERRIDE: "override",
        },
      }),
      baseEnv,
    );

    expect(process.env.PATH).toBe("/custom/bin");
    expect(process.env.RUNTIME_ONLY).toBe("enabled");
    expect(process.env.RUNTIME_OVERRIDE).toBe("override");

    applyHostEnv(makeConfig({ runtimePathEntries: ["/other/bin"], runtimeEnv: {} }), baseEnv);

    expect(process.env.PATH).toBe("/other/bin");
    expect(process.env.RUNTIME_ONLY).toBeUndefined();
    expect(process.env.RUNTIME_OVERRIDE).toBe("base");
  });
});

describe("resolveExecutableOnPath", () => {
  it("finds executable files in PATH", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-bin-"));
    const binPath = join(dir, "hello-bin");
    writeFileSync(binPath, "#!/bin/sh\necho hello\n");
    chmodSync(binPath, 0o755);

    try {
      const resolved = resolveExecutableOnPath("hello-bin", dir);
      expect(resolved).toBe(binPath);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns null when binary is not present", () => {
    const resolved = resolveExecutableOnPath("definitely-not-a-real-binary", "/usr/bin:/bin");
    expect(resolved).toBeNull();
  });
});
