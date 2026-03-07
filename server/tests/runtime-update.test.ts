import { describe, expect, it } from "vitest";

import { RuntimeUpdateManager } from "../src/runtime-update.js";

describe("RuntimeUpdateManager", () => {
  it("reports updateAvailable when registry version is newer", async () => {
    const calls: string[] = [];
    const manager = new RuntimeUpdateManager({
      packageName: "@mariozechner/pi-coding-agent",
      currentVersion: "0.56.0",
      commandRunner: async (_file, args) => {
        calls.push(args.join(" "));
        if (args[0] === "--version") {
          return "10.9.0\n";
        }
        if (args[0] === "view") {
          return "0.57.0\n";
        }
        throw new Error(`Unexpected command: ${args.join(" ")}`);
      },
    });

    const status = await manager.getStatus({ force: true });

    expect(status.canUpdate).toBe(true);
    expect(status.latestVersion).toBe("0.57.0");
    expect(status.updateAvailable).toBe(true);
    expect(calls).toEqual(["--version", "view @mariozechner/pi-coding-agent version"]);
  });

  it("marks restartRequired after successful runtime update", async () => {
    const commands: string[] = [];
    const manager = new RuntimeUpdateManager({
      packageName: "@mariozechner/pi-coding-agent",
      currentVersion: "0.56.0",
      commandRunner: async (_file, args) => {
        commands.push(args.join(" "));
        if (args[0] === "--version") {
          return "10.9.0\n";
        }
        if (args[0] === "view") {
          return "0.57.0\n";
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
    expect(result.pendingVersion).toBe("0.57.0");
    expect(status.restartRequired).toBe(true);
    expect(status.updateAvailable).toBe(false);
    expect(status.pendingVersion).toBe("0.57.0");
    expect(commands).toContain("install @mariozechner/pi-coding-agent@latest");
  });

  it("disables updates when npm is unavailable", async () => {
    const manager = new RuntimeUpdateManager({
      packageName: "@mariozechner/pi-coding-agent",
      currentVersion: "0.56.0",
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
