import { EventEmitter } from "node:events";
import { afterEach, describe, expect, it, vi } from "vitest";

const { spawnMock } = vi.hoisted(() => ({
  spawnMock: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  spawn: spawnMock,
}));

import { openBrowser } from "../src/provider-auth/browser-launcher.js";

class MockChildProcess extends EventEmitter {
  readonly unref = vi.fn();
}

const originalPlatform = Object.getOwnPropertyDescriptor(process, "platform");

afterEach(() => {
  if (originalPlatform) {
    Object.defineProperty(process, "platform", originalPlatform);
  }
  spawnMock.mockReset();
});

function setPlatform(platform: NodeJS.Platform): void {
  Object.defineProperty(process, "platform", {
    configurable: true,
    enumerable: true,
    value: platform,
  });
}

describe("provider auth browser launcher", () => {
  it.each([
    {
      platform: "darwin" as NodeJS.Platform,
      command: "open",
      args: ["https://example.com/login"],
    },
    {
      platform: "win32" as NodeJS.Platform,
      command: "cmd",
      args: ["/c", "start", "", "https://example.com/login"],
    },
    {
      platform: "linux" as NodeJS.Platform,
      command: "xdg-open",
      args: ["https://example.com/login"],
    },
  ])("launches the platform browser command for $platform", async ({ platform, command, args }) => {
    setPlatform(platform);
    const child = new MockChildProcess();
    spawnMock.mockImplementation(() => {
      queueMicrotask(() => child.emit("spawn"));
      return child;
    });

    await openBrowser("https://example.com/login");

    expect(spawnMock).toHaveBeenCalledWith(command, args, {
      detached: true,
      stdio: "ignore",
    });
    expect(child.unref).toHaveBeenCalledTimes(1);
  });

  it("rejects and leaves the child referenced when the opener cannot spawn", async () => {
    setPlatform("linux");
    const child = new MockChildProcess();
    spawnMock.mockImplementation(() => {
      queueMicrotask(() => child.emit("error", new Error("xdg-open missing")));
      return child;
    });

    await expect(openBrowser("https://example.com/login")).rejects.toThrow("xdg-open missing");
    expect(child.unref).not.toHaveBeenCalled();
  });
});
