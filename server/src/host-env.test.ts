import { afterEach, describe, expect, it } from "vitest";

import { applyHostEnv, buildHostEnv } from "./host-env.js";
import type { ServerConfig } from "./types.js";

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
  process.env.PATH = "/usr/bin:/bin";
});

describe("host env reload", () => {
  it("buildHostEnv is stable against prior apply mutations", () => {
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
