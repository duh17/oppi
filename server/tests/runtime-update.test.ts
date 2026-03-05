import { describe, expect, it } from "vitest";

import { RuntimeUpdateManager } from "../src/runtime-update.js";

describe("RuntimeUpdateManager", () => {
  it("reports updateAvailable when registry version is newer", async () => {
    const calls: string[] = [];
    const manager = new RuntimeUpdateManager({
      packageName: "oppi-server",
      currentVersion: "0.2.0",
      commandRunner: async (_file, args) => {
        calls.push(args.join(" "));
        if (args[0] === "--version") {
          return "10.9.0\n";
        }
        if (args[0] === "view") {
          return "0.3.1\n";
        }
        throw new Error(`Unexpected command: ${args.join(" ")}`);
      },
    });

    const status = await manager.getStatus({ force: true });

    expect(status.canUpdate).toBe(true);
    expect(status.latestVersion).toBe("0.3.1");
    expect(status.updateAvailable).toBe(true);
    expect(calls).toEqual(["--version", "view oppi-server version"]);
  });

  it("marks restartRequired after successful runtime update", async () => {
    const commands: string[] = [];
    const manager = new RuntimeUpdateManager({
      packageName: "oppi-server",
      currentVersion: "0.2.0",
      commandRunner: async (_file, args) => {
        commands.push(args.join(" "));
        if (args[0] === "--version") {
          return "10.9.0\n";
        }
        if (args[0] === "view") {
          return "0.3.1\n";
        }
        if (args[0] === "install") {
          return "installed\n";
        }
        throw new Error(`Unexpected command: ${args.join(" ")}`);
      },
    });

    const result = await manager.updateRuntime();
    const status = await manager.getStatus();

    expect(result.ok).toBe(true);
    expect(result.restartRequired).toBe(true);
    expect(result.pendingVersion).toBe("0.3.1");
    expect(status.restartRequired).toBe(true);
    expect(status.updateAvailable).toBe(false);
    expect(status.pendingVersion).toBe("0.3.1");
    expect(commands).toContain("install -g oppi-server@latest");
  });

  it("disables updates when npm is unavailable", async () => {
    const manager = new RuntimeUpdateManager({
      packageName: "oppi-server",
      currentVersion: "0.2.0",
      commandRunner: async (_file, args) => {
        if (args[0] === "--version") {
          throw new Error("ENOENT");
        }
        throw new Error(`Unexpected command: ${args.join(" ")}`);
      },
    });

    const status = await manager.getStatus({ force: true });
    const result = await manager.updateRuntime();

    expect(status.canUpdate).toBe(false);
    expect(status.updateAvailable).toBe(false);
    expect(result.ok).toBe(false);
    expect(result.error).toContain("npm");
  });
});
