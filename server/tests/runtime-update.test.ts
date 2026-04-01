import { describe, expect, it } from "vitest";

import { RuntimeUpdateManager } from "../src/runtime-update.js";

describe("RuntimeUpdateManager", () => {
  it("reports current version", async () => {
    const manager = new RuntimeUpdateManager({
      currentVersion: "0.62.0",
    });

    const status = await manager.getStatus();

    expect(status.currentVersion).toBe("0.62.0");
    expect(status.updateAvailable).toBe(false);
    expect(status.checking).toBe(false);
  });

  it("returns error when runtime dir not found", async () => {
    // In test environment, process.argv[1] won't point to a valid runtime dir
    // and ~/.config/oppi/server-runtime likely doesn't exist, so updateRuntime
    // should fail gracefully.
    const manager = new RuntimeUpdateManager({
      currentVersion: "0.62.0",
    });

    const result = await manager.updateRuntime();

    // Either runtime dir not found or no package manager — both are acceptable
    expect(result.ok).toBe(false);
    expect(result.restartRequired).toBe(false);
  });

  it("uses custom package name", async () => {
    const manager = new RuntimeUpdateManager({
      packageName: "@custom/agent",
      currentVersion: "1.0.0",
    });

    const status = await manager.getStatus();
    expect(status.packageName).toBe("@custom/agent");
  });
});
