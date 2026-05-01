/**
 * Unit tests for macOS launchd service management.
 *
 * Mocks filesystem and child_process to test logic without touching launchd.
 * Covers: plist generation, path resolution, status parsing, install/uninstall
 * flows, restart/stop commands, readInstalledPlist parsing, and error paths.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// ── Mocks ──────────────────────────────────────────────────────────────────

const mockExistsSync = vi.fn<(path: string) => boolean>();
const mockMkdirSync = vi.fn();
const mockWriteFileSync = vi.fn();
const mockReadFileSync = vi.fn<(path: string, encoding: string) => string>();
const mockUnlinkSync = vi.fn();
const mockExecSync = vi.fn<(cmd: string, opts?: object) => string>();
const mockHomedir = vi.fn(() => "/Users/testuser");

vi.mock("node:fs", () => ({
  existsSync: (...args: unknown[]) => mockExistsSync(args[0] as string),
  mkdirSync: (...args: unknown[]) => mockMkdirSync(...args),
  writeFileSync: (...args: unknown[]) => mockWriteFileSync(...args),
  readFileSync: (...args: unknown[]) => mockReadFileSync(args[0] as string, args[1] as string),
  unlinkSync: (...args: unknown[]) => mockUnlinkSync(...args),
}));

vi.mock("node:child_process", () => ({
  execSync: (...args: unknown[]) => mockExecSync(args[0] as string, args[1] as object | undefined),
}));

vi.mock("node:os", () => ({
  homedir: () => mockHomedir(),
}));

// Stub process.getuid to return a fake uid on all platforms
const originalGetuid = process.getuid;
beforeEach(() => {
  process.getuid = () => 501;
  mockUnlinkSync.mockImplementation(() => undefined);
});

afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
  process.getuid = originalGetuid;
});

// Import after mocks are in place
import {
  getServiceStatus,
  installService,
  readInstalledPlist,
  restartService,
  stopService,
  uninstallService,
} from "../src/launchd.js";

// ── Plist path ─────────────────────────────────────────────────────────────

describe("plist path resolution", () => {
  it("derives plist path from homedir", () => {
    mockExistsSync.mockReturnValue(false);
    const status = getServiceStatus();
    expect(status.plistPath).toBe(
      "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
    );
    expect(status.label).toBe("dev.chaosdonkey.oppi");
  });
});

// ── Plist XML generation (via installService) ──────────────────────────────

describe("plist XML generation", () => {
  function captureWrittenPlist(dataDir?: string): string {
    // Runtime: bundled bun exists
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      // CLI: runtime dir exists
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      // Existing plist (not installed yet)
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    installService(dataDir);

    const writeCall = mockWriteFileSync.mock.calls[0];
    return writeCall[1] as string;
  }

  it("generates valid plist XML with correct structure", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain('<?xml version="1.0" encoding="UTF-8"?>');
    expect(xml).toContain("<!DOCTYPE plist");
    expect(xml).toContain('<plist version="1.0">');
    expect(xml).toContain("<key>Label</key>");
    expect(xml).toContain("<string>dev.chaosdonkey.oppi</string>");
  });

  it("sets ProgramArguments with runtime, CLI, serve, and data-dir", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>ProgramArguments</key>");
    expect(xml).toContain("<string>/Applications/Oppi.app/Contents/Resources/bun</string>");
    expect(xml).toContain(
      "<string>/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js</string>",
    );
    expect(xml).toContain("<string>serve</string>");
    expect(xml).toContain("<string>--data-dir</string>");
    expect(xml).toContain("<string>/tmp/test-oppi</string>");
  });

  it("includes KeepAlive with SuccessfulExit=false", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>KeepAlive</key>");
    expect(xml).toContain("<key>SuccessfulExit</key>");
    expect(xml).toContain("<false/>");
  });

  it("includes RunAtLoad", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");
    expect(xml).toContain("<key>RunAtLoad</key>");
    expect(xml).toContain("<true/>");
  });

  it("sets environment variables including PATH, OPPI_DATA_DIR, OPPI_RUNTIME_BIN", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>EnvironmentVariables</key>");
    expect(xml).toContain("<key>PATH</key>");
    expect(xml).toContain("/opt/homebrew/bin");
    expect(xml).toContain("/Users/testuser/.bun/bin");
    expect(xml).toContain("<key>OPPI_DATA_DIR</key>");
    expect(xml).toContain("<string>/tmp/test-oppi</string>");
    expect(xml).toContain("<key>OPPI_RUNTIME_BIN</key>");
    expect(xml).toContain("<string>/Applications/Oppi.app/Contents/Resources/bun</string>");
  });

  it("sets log paths to dataDir/server.log", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>StandardOutPath</key>");
    expect(xml).toContain("<key>StandardErrorPath</key>");
    expect(xml).toContain("<string>/tmp/test-oppi/server.log</string>");
  });

  it("includes ThrottleInterval and ProcessType", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>ThrottleInterval</key>");
    expect(xml).toContain("<integer>5</integer>");
    expect(xml).toContain("<key>ProcessType</key>");
    expect(xml).toContain("<string>Standard</string>");
  });

  it("sets WorkingDirectory to homedir", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");
    expect(xml).toContain("<key>WorkingDirectory</key>");
    expect(xml).toContain("<string>/Users/testuser</string>");
  });

  it("defaults dataDir to ~/.config/oppi when not provided", () => {
    const xml = captureWrittenPlist(undefined);

    expect(xml).toContain("<key>OPPI_DATA_DIR</key>");
    expect(xml).toContain("<string>/Users/testuser/.config/oppi</string>");
  });
});

// ── Runtime resolution ─────────────────────────────────────────────────────

describe("runtime resolution", () => {
  it("prefers bundled Bun over system candidates", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/opt/homebrew/bin/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    const result = installService("/tmp/data");
    expect(result.runtimePath).toBe("/Applications/Oppi.app/Contents/Resources/bun");
  });

  it("falls back to Homebrew bun when bundled not available", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return false;
      if (p === "/opt/homebrew/bin/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    const result = installService("/tmp/data");
    expect(result.runtimePath).toBe("/opt/homebrew/bin/bun");
  });

  it("falls back to node when no bun is available", () => {
    mockExistsSync.mockImplementation((p: string) => {
      // No bun anywhere
      if (p.includes("bun")) return false;
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    const result = installService("/tmp/data");
    expect(result.runtimePath).toBe("/opt/homebrew/bin/node");
  });

  it("returns error when no runtime found", () => {
    mockExistsSync.mockReturnValue(false);
    const result = installService("/tmp/data");

    expect(result.ok).toBe(false);
    expect(result.message).toContain("No JS runtime found");
  });
});

// ── CLI resolution ─────────────────────────────────────────────────────────

describe("CLI resolution", () => {
  it("returns error when CLI not found", () => {
    // Runtime exists, but no CLI
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Server CLI not found");
  });

  it("resolves runtime dir CLI first", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p === "/Applications/Oppi.app/Contents/Resources/server-seed/dist/src/cli.js")
        return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    expect(result.cliPath).toBe("/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js");
  });
});

// ── installService flow ────────────────────────────────────────────────────

describe("installService", () => {
  function setupValidInstall() {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockReturnValue("");
  }

  it("creates LaunchAgents directory", () => {
    setupValidInstall();
    installService("/tmp/data");

    expect(mockMkdirSync).toHaveBeenCalledWith("/Users/testuser/Library/LaunchAgents", {
      recursive: true,
    });
  });

  it("writes plist with mode 0o644", () => {
    setupValidInstall();
    installService("/tmp/data");

    expect(mockWriteFileSync).toHaveBeenCalledWith(
      "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
      expect.any(String),
      { mode: 0o644 },
    );
  });

  it("calls launchctl bootstrap after writing plist", () => {
    setupValidInstall();
    installService("/tmp/data");

    const bootstrapCall = mockExecSync.mock.calls.find(([cmd]) =>
      (cmd as string).includes("bootstrap"),
    );
    expect(bootstrapCall).toBeDefined();
    expect(bootstrapCall![0]).toBe(
      "launchctl bootstrap gui/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
    );
  });

  it("bootouts existing plist before installing", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p === "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist") return true;
      return false;
    });
    mockExecSync.mockReturnValue("");

    installService("/tmp/data");

    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
  });

  it("disables legacy dev.chenda LaunchAgent before installing", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p === "/Users/testuser/Library/LaunchAgents/dev.chenda.oppi.plist") return true;
      if (p === "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist") return false;
      return false;
    });
    mockExecSync.mockReturnValue("");

    const result = installService("/tmp/data");

    expect(result.ok).toBe(true);
    expect(result.legacyRemoved).toEqual([
      "/Users/testuser/Library/LaunchAgents/dev.chenda.oppi.plist",
    ]);
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501/dev.chenda.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501 /Users/testuser/Library/LaunchAgents/dev.chenda.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockUnlinkSync).toHaveBeenCalledWith(
      "/Users/testuser/Library/LaunchAgents/dev.chenda.oppi.plist",
    );
  });

  it("fails install when legacy LaunchAgent plist cannot be removed", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      if (p === "/Users/testuser/Library/LaunchAgents/dev.chenda.oppi.plist") return true;
      return false;
    });
    mockExecSync.mockReturnValue("");
    mockUnlinkSync.mockImplementation(() => {
      throw new Error("EACCES: permission denied");
    });

    const result = installService("/tmp/data");

    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to disable legacy LaunchAgent");
    expect(result.message).toContain("EACCES");
  });

  it("handles error 37 (already loaded) by kickstarting", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootstrap")) {
        throw new Error("37: Service is already loaded");
      }
      return "";
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);

    const kickstartCall = mockExecSync.mock.calls.find(([cmd]) =>
      (cmd as string).includes("kickstart"),
    );
    expect(kickstartCall).toBeDefined();
    expect(kickstartCall![0]).toBe("launchctl kickstart -k gui/501/dev.chaosdonkey.oppi");
  });

  it("returns error on non-37 bootstrap failure", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootstrap")) {
        throw new Error("5: Some other error");
      }
      return "";
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to load LaunchAgent");
    expect(result.message).toContain("5: Some other error");
  });

  it("returns ok with paths on success", () => {
    setupValidInstall();
    const result = installService("/tmp/data");

    expect(result.ok).toBe(true);
    expect(result.message).toContain("installed and started");
    expect(result.runtimePath).toBe("/Applications/Oppi.app/Contents/Resources/bun");
    expect(result.cliPath).toBe("/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js");
  });
});

// ── uninstallService ───────────────────────────────────────────────────────

describe("uninstallService", () => {
  it("returns ok when plist not installed", () => {
    mockExistsSync.mockReturnValue(false);
    const result = uninstallService();

    expect(result.ok).toBe(true);
    expect(result.message).toContain("not installed");
  });

  it("bootouts and removes plist when installed", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("");

    const result = uninstallService();

    expect(result.ok).toBe(true);
    expect(result.message).toContain("uninstalled");

    const bootoutCall = mockExecSync.mock.calls.find(([cmd]) =>
      (cmd as string).includes("bootout"),
    );
    expect(bootoutCall).toBeDefined();
    expect(mockUnlinkSync).toHaveBeenCalledWith(
      "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
    );
  });

  it("still removes plist if bootout fails", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("already unloaded");
    });

    const result = uninstallService();
    expect(result.ok).toBe(true);
    expect(mockUnlinkSync).toHaveBeenCalled();
  });

  it("returns error if plist removal fails", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("");
    mockUnlinkSync.mockImplementation(() => {
      throw new Error("EACCES: permission denied");
    });

    const result = uninstallService();
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to remove plist");
    expect(result.message).toContain("EACCES");
  });
});

// ── restartService ─────────────────────────────────────────────────────────

describe("restartService", () => {
  it("returns error when plist not installed", () => {
    mockExistsSync.mockReturnValue(false);
    const result = restartService();

    expect(result.ok).toBe(false);
    expect(result.message).toContain("not installed");
  });

  it("calls kickstart -k with correct label", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("");

    const result = restartService();

    expect(result.ok).toBe(true);
    expect(result.message).toContain("restarted");
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl kickstart -k gui/501/dev.chaosdonkey.oppi",
      { stdio: "pipe" },
    );
  });

  it("returns error on kickstart failure", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("kickstart: no such process");
    });

    const result = restartService();
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Restart failed");
  });
});

// ── stopService ────────────────────────────────────────────────────────────

describe("stopService", () => {
  it("returns error when plist not installed", () => {
    mockExistsSync.mockReturnValue(false);
    const result = stopService();

    expect(result.ok).toBe(false);
    expect(result.message).toContain("not installed");
  });

  it("bootouts by label on stop", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue("");

    const result = stopService();

    expect(result.ok).toBe(true);
    expect(result.message).toContain("stopped");
    expect(mockExecSync).toHaveBeenCalledWith("launchctl bootout gui/501/dev.chaosdonkey.oppi", {
      stdio: "pipe",
    });
  });

  it("treats 'No such process' as success (already stopped)", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("No such process");
    });

    const result = stopService();
    expect(result.ok).toBe(true);
    expect(result.message).toContain("not running");
  });

  it("treats 'Could not find' as success (already stopped)", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("Could not find service");
    });

    const result = stopService();
    expect(result.ok).toBe(true);
    expect(result.message).toContain("not running");
  });

  it("returns error on unexpected stop failure", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("unexpected launchctl error");
    });

    const result = stopService();
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Stop failed");
  });
});

// ── getServiceStatus ───────────────────────────────────────────────────────

describe("getServiceStatus", () => {
  it("returns not installed when plist does not exist", () => {
    mockExistsSync.mockReturnValue(false);

    const status = getServiceStatus();
    expect(status.installed).toBe(false);
    expect(status.running).toBe(false);
    expect(status.pid).toBeNull();
  });

  it("parses PID from launchctl print output", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue(
      [
        "dev.chaosdonkey.oppi = {",
        "  active count = 1",
        "  pid = 12345",
        "  state = running",
        "}",
      ].join("\n"),
    );

    const status = getServiceStatus();
    expect(status.installed).toBe(true);
    expect(status.running).toBe(true);
    expect(status.pid).toBe(12345);
  });

  it("detects running state even without PID line", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue(
      ["dev.chaosdonkey.oppi = {", "  active count = 1", "  state = running", "}"].join("\n"),
    );

    const status = getServiceStatus();
    expect(status.installed).toBe(true);
    expect(status.running).toBe(true);
    expect(status.pid).toBeNull();
  });

  it("treats pid = 0 as not running", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockReturnValue(
      ["dev.chaosdonkey.oppi = {", "  pid = 0", "  state = waiting", "}"].join("\n"),
    );

    const status = getServiceStatus();
    expect(status.installed).toBe(true);
    expect(status.running).toBe(false);
    expect(status.pid).toBe(0);
  });

  it("handles launchctl print failure (service not loaded)", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation(() => {
      throw new Error("Could not find service");
    });

    const status = getServiceStatus();
    expect(status.installed).toBe(true);
    expect(status.running).toBe(false);
    expect(status.pid).toBeNull();
  });

  it("always includes label and plist path", () => {
    mockExistsSync.mockReturnValue(false);
    const status = getServiceStatus();

    expect(status.label).toBe("dev.chaosdonkey.oppi");
    expect(status.plistPath).toBe(
      "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
    );
  });
});

// ── readInstalledPlist ─────────────────────────────────────────────────────

describe("readInstalledPlist", () => {
  it("returns null when plist does not exist", () => {
    mockExistsSync.mockReturnValue(false);
    expect(readInstalledPlist()).toBeNull();
  });

  it("parses runtime, CLI, and data-dir from plist XML", () => {
    const plistXml = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/node</string>
        <string>/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js</string>
        <string>serve</string>
        <string>--data-dir</string>
        <string>/Users/testuser/.config/oppi</string>
    </array>
</dict>
</plist>`;

    mockExistsSync.mockReturnValue(true);
    mockReadFileSync.mockReturnValue(plistXml);

    const parsed = readInstalledPlist();
    expect(parsed).not.toBeNull();
    expect(parsed!.runtimePath).toBe("/opt/homebrew/bin/node");
    expect(parsed!.cliPath).toBe("/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js");
    expect(parsed!.dataDir).toBe("/Users/testuser/.config/oppi");
  });

  it("returns null when ProgramArguments has fewer than 5 entries", () => {
    const plistXml = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/node</string>
        <string>serve</string>
    </array>
</dict>
</plist>`;

    mockExistsSync.mockReturnValue(true);
    mockReadFileSync.mockReturnValue(plistXml);

    expect(readInstalledPlist()).toBeNull();
  });

  it("returns null when readFileSync throws", () => {
    mockExistsSync.mockReturnValue(true);
    mockReadFileSync.mockImplementation(() => {
      throw new Error("EACCES: permission denied");
    });

    expect(readInstalledPlist()).toBeNull();
  });

  it("returns null when plist has no ProgramArguments key", () => {
    const plistXml = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.chaosdonkey.oppi</string>
</dict>
</plist>`;

    mockExistsSync.mockReturnValue(true);
    mockReadFileSync.mockReturnValue(plistXml);

    expect(readInstalledPlist()).toBeNull();
  });
});

// ── uid() edge case ────────────────────────────────────────────────────────

describe("uid unavailable", () => {
  it("installService returns error when getuid is not available", () => {
    // Remove getuid to simulate non-macOS
    process.getuid = undefined as unknown as () => number;

    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/Applications/Oppi.app/Contents/Resources/bun") return true;
      if (p === "/Users/testuser/.config/oppi/server-runtime/dist/src/cli.js") return true;
      // No existing plist, so bootout path is skipped — uid() is hit at bootstrap
      if (p.endsWith(".plist")) return false;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("uid() not available");
  });
});
