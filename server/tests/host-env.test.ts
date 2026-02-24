import { describe, it, expect } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  applyHostEnv,
  buildHostEnv,
  resolveExecutableOnPath,
  resolveHostEnv,
} from "../src/host-env.js";
import type { ServerConfig } from "../src/types.js";

function baseConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    port: 7749,
    host: "0.0.0.0",
    dataDir: "/tmp/oppi-test",
    defaultModel: "openai-codex/gpt-5.3-codex",
    sessionIdleTimeoutMs: 600_000,
    workspaceIdleTimeoutMs: 1_800_000,
    maxSessionsPerWorkspace: 3,
    maxSessionsGlobal: 5,
    approvalTimeoutMs: 120_000,
    permissionGate: true,
    runtimePathEntries: ["/usr/bin", "/bin"],
    runtimeEnv: {},
    ...overrides,
  };
}

describe("buildHostEnv", () => {
  it("uses only configured PATH entries", () => {
    const env = buildHostEnv(baseConfig({ runtimePathEntries: ["/custom/bin", "/usr/bin"] }));
    expect(env.PATH).toBe("/custom/bin:/usr/bin");
  });

  it("deduplicates and normalizes configured PATH entries", () => {
    const env = buildHostEnv(
      baseConfig({ runtimePathEntries: ["/usr/bin", "/usr/bin", " /bin ", ""] }),
    );
    expect(env.PATH).toBe("/usr/bin:/bin");
  });

  it("applies runtimeEnv overrides", () => {
    const env = buildHostEnv(baseConfig({ runtimeEnv: { EDITOR: "nvim", LANG: "en_US.UTF-8" } }));
    expect(env.EDITOR).toBe("nvim");
    expect(env.LANG).toBe("en_US.UTF-8");
  });
});

describe("resolveHostEnv", () => {
  it("returns configured path entries and merged env", () => {
    const resolved = resolveHostEnv(baseConfig({ runtimePathEntries: ["/a", "/b"] }));
    expect(resolved.configuredPathEntries).toEqual(["/a", "/b"]);
    expect(resolved.env.PATH).toBe("/a:/b");
  });
});

describe("applyHostEnv", () => {
  it("applies configured env to process.env", () => {
    const originalPath = process.env.PATH;
    const originalEditor = process.env.EDITOR;

    const resolved = applyHostEnv(
      baseConfig({ runtimePathEntries: ["/apply/bin"], runtimeEnv: { EDITOR: "helix" } }),
    );

    expect(process.env.PATH).toBe("/apply/bin");
    expect(process.env.EDITOR).toBe("helix");
    expect(resolved.env.EDITOR).toBe("helix");

    if (originalPath === undefined) delete process.env.PATH;
    else process.env.PATH = originalPath;

    if (originalEditor === undefined) delete process.env.EDITOR;
    else process.env.EDITOR = originalEditor;
  });
});

describe("resolveExecutableOnPath", () => {
  it("finds executable files in PATH", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-bin-"));
    const binPath = join(dir, "hello-bin");
    writeFileSync(binPath, "#!/bin/sh\necho hello\n");
    chmodSync(binPath, 0o755);

    const resolved = resolveExecutableOnPath("hello-bin", dir);
    expect(resolved).toBe(binPath);

    rmSync(dir, { recursive: true, force: true });
  });

  it("returns null when binary is not present", () => {
    const resolved = resolveExecutableOnPath("definitely-not-a-real-binary", "/usr/bin:/bin");
    expect(resolved).toBeNull();
  });
});
