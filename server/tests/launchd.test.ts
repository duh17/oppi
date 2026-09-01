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
const mockRealpathSync = vi.fn<(path: string) => string>();
const mockUnlinkSync = vi.fn();
const mockExecSync = vi.fn<(cmd: string, opts?: object) => string>();
const mockHomedir = vi.fn(() => "/Users/testuser");

vi.mock("node:fs", () => ({
  existsSync: (...args: unknown[]) => mockExistsSync(args[0] as string),
  mkdirSync: (...args: unknown[]) => mockMkdirSync(...args),
  writeFileSync: (...args: unknown[]) => mockWriteFileSync(...args),
  readFileSync: (...args: unknown[]) => mockReadFileSync(args[0] as string, args[1] as string),
  realpathSync: (...args: unknown[]) => mockRealpathSync(args[0] as string),
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
  mockHomedir.mockImplementation(() => "/Users/testuser");
  mockUnlinkSync.mockImplementation(() => undefined);
  mockRealpathSync.mockImplementation((path: string) => path);
  mockReadFileSync.mockImplementation((path: string) => {
    if (path.endsWith("package.json")) {
      return JSON.stringify({ engines: { node: ">=23.6.0" } });
    }
    return "";
  });
  mockExecSync.mockImplementation((cmd: string) => defaultLaunchctlOutput(cmd));
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

function isPrintDomain(cmd: string, domain: string): boolean {
  return cmd.includes(`launchctl print ${domain}`) && !cmd.includes(`launchctl print ${domain}/`);
}

function isPrintService(cmd: string, domain: string, label = "dev.chaosdonkey.oppi"): boolean {
  return cmd.includes(`launchctl print ${domain}/${label}`);
}

function isPrintAnyService(cmd: string): boolean {
  return /launchctl print (?:gui|user)\/\d+\//.test(cmd);
}

function defaultLaunchctlOutput(cmd: string): string {
  if (cmd.includes("--version")) return "v25.0.0";
  if (isPrintAnyService(cmd)) {
    throw new Error("Could not find service");
  }
  return "";
}

function execError(message: string, status?: number): Error {
  const err = new Error(message) as Error & { status?: number };
  if (status !== undefined) err.status = status;
  return err;
}

function setupValidInstall() {
  mockExistsSync.mockImplementation((p: string) => {
    if (p === "/opt/homebrew/bin/node") return true;
    if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
    if (p.endsWith(".plist")) return false;
    return false;
  });
}

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
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });

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
    expect(xml).toContain("<string>/opt/homebrew/bin/node</string>");
    expect(xml).toContain(
      "<string>/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js</string>",
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

  it("sets PATH and OPPI_DATA_DIR without a second runtime owner", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>EnvironmentVariables</key>");
    expect(xml).toContain("<key>PATH</key>");
    expect(xml).toContain("/opt/homebrew/bin");
    expect(xml).toContain("<key>OPPI_DATA_DIR</key>");
    expect(xml).toContain("<string>/tmp/test-oppi</string>");
    expect(xml).not.toContain("OPPI_RUNTIME_BIN");
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

  it("allows Aqua and Background session types", () => {
    const xml = captureWrittenPlist("/tmp/test-oppi");

    expect(xml).toContain("<key>LimitLoadToSessionType</key>");
    expect(xml).toContain("<string>Aqua</string>");
    expect(xml).toContain("<string>Background</string>");
  });

  it("defaults dataDir to ~/.config/oppi when not provided", () => {
    const xml = captureWrittenPlist(undefined);

    expect(xml).toContain("<key>OPPI_DATA_DIR</key>");
    expect(xml).toContain("<string>/Users/testuser/.config/oppi</string>");
  });
});

// ── Runtime resolution ─────────────────────────────────────────────────────

describe("runtime resolution", () => {
  it("prefers Homebrew node", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/usr/local/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.runtimePath).toBe("/opt/homebrew/bin/node");
  });

  it("falls back to /usr/local/bin/node when Homebrew node is unavailable", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return false;
      if (p === "/usr/local/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.runtimePath).toBe("/usr/local/bin/node");
  });

  it("rejects nodes older than the server minimum", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("--version")) {
        return "v20.11.1";
      }
      return "";
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Node.js 20.11.1 found");
    expect(result.message).toContain("23.6.0 or newer");
  });

  it("returns error when no runtime found", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      return false;
    });
    const result = installService("/tmp/data");

    expect(result.ok).toBe(false);
    expect(result.message).toContain("Node.js 23.6.0 or newer not found");
  });
});

// ── CLI resolution ─────────────────────────────────────────────────────────

describe("CLI resolution", () => {
  it("returns error when CLI not found", () => {
    // Runtime exists, but no CLI
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Oppi CLI not found");
  });

  it("resolves the globally installed npm CLI", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    expect(result.cliPath).toBe("/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js");
  });

  it("resolves the current npm CLI symlink before fallback locations", () => {
    const originalArgv1 = process.argv[1];
    process.argv[1] = "/tmp/npm-prefix/bin/oppi";
    mockRealpathSync.mockImplementation((p: string) => {
      if (p === "/tmp/npm-prefix/bin/oppi") {
        return "/tmp/npm-prefix/lib/node_modules/oppi-server/dist/src/cli.js";
      }
      return p;
    });
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/tmp/npm-prefix/bin/oppi") return true;
      if (p === "/tmp/npm-prefix/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p.endsWith(".plist")) return false;
      return false;
    });

    try {
      const result = installService("/tmp/data");
      expect(result.ok).toBe(true);
      expect(result.cliPath).toBe("/tmp/npm-prefix/bin/oppi");
    } finally {
      process.argv[1] = originalArgv1;
    }
  });
});

// ── installService flow ────────────────────────────────────────────────────

describe("installService", () => {
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
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p === "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist") return true;
      return false;
    });

    installService("/tmp/data");

    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
  });

  it("handles error 37 (already loaded) by kickstarting", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootstrap")) {
        throw new Error("37: Service is already loaded");
      }
      return defaultLaunchctlOutput(cmd);
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
      return defaultLaunchctlOutput(cmd);
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
    expect(result.runtimePath).toBe("/opt/homebrew/bin/node");
    expect(result.cliPath).toBe("/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js");
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
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) {
        throw new Error("already unloaded");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = uninstallService();
    expect(result.ok).toBe(true);
    expect(mockUnlinkSync).toHaveBeenCalled();
  });

  it("returns error if plist removal fails", () => {
    mockExistsSync.mockReturnValue(true);
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

    const result = stopService();

    expect(result.ok).toBe(true);
    expect(result.message).toContain("not running");
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist 2>/dev/null",
      { stdio: "pipe" },
    );
  });

  it("treats 'No such process' as success (already stopped)", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) {
        throw new Error("No such process");
      }
      return defaultLaunchctlOutput(cmd);
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
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintAnyService(cmd)) {
        return ["dev.chaosdonkey.oppi = {", "  pid = 12345", "  state = running", "}"].join("\n");
      }
      if (cmd.includes("bootout")) {
        throw new Error("unexpected launchctl error");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = stopService();
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Stop failed");
    expect(result.message).toMatch(/loaded/i);
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
        <string>/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js</string>
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
    expect(parsed!.cliPath).toBe("/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js");
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

// ── Domain selection (gui vs user) ─────────────────────────────────────────

describe("launchd domain selection", () => {
  const plist = "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist";
  const runningPrint = ["dev.chaosdonkey.oppi = {", "  pid = 12345", "  state = running", "}"].join(
    "\n",
  );

  it("installs into user domain when gui is unavailable", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintDomain(cmd, "gui/501")) {
        throw new Error("Could not find domain gui/501");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);

    const bootstrapCalls = mockExecSync.mock.calls
      .map(([cmd]) => cmd as string)
      .filter((cmd) => cmd.includes("bootstrap"));
    expect(bootstrapCalls).toEqual([`launchctl bootstrap user/501 ${plist}`]);
  });

  it("installs into gui domain when both domains exist", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => defaultLaunchctlOutput(cmd));

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);

    const bootstrapCalls = mockExecSync.mock.calls
      .map(([cmd]) => cmd as string)
      .filter((cmd) => cmd.includes("bootstrap"));
    expect(bootstrapCalls).toEqual([`launchctl bootstrap gui/501 ${plist}`]);
  });

  it("bootouts the current job in both domains before loading", () => {
    setupValidInstall();
    installService("/tmp/data");

    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
  });

  it("fails with a useful error when neither domain exists", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintDomain(cmd, "gui/501") || isPrintDomain(cmd, "user/501")) {
        throw new Error("Could not find domain");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("No launchd user domain available");
    expect(result.message).toContain("gui/501");
    expect(result.message).toContain("user/501");
    expect(mockExecSync.mock.calls.some(([cmd]) => (cmd as string).includes("bootstrap"))).toBe(
      false,
    );
  });

  it("kickstarts the user domain on error 37 when gui is unavailable", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintDomain(cmd, "gui/501")) {
        throw new Error("Could not find domain gui/501");
      }
      if (cmd.includes("bootstrap")) {
        throw new Error("37: Service is already loaded");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl kickstart -k user/501/dev.chaosdonkey.oppi",
      { stdio: "pipe" },
    );
  });

  it("status finds a user-domain job even when the gui domain exists", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintService(cmd, "gui/501")) {
        throw new Error("Could not find service");
      }
      if (isPrintService(cmd, "user/501")) {
        return runningPrint;
      }
      if (isPrintDomain(cmd, "gui/501")) {
        return ["gui/501 = {", "  pid = 1", "  state = running", "}"].join("\n");
      }
      return "";
    });

    const status = getServiceStatus();
    expect(status.installed).toBe(true);
    expect(status.running).toBe(true);
    expect(status.pid).toBe(12345);
  });

  it("restart kickstarts the loaded domain, not merely the preferred domain", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintService(cmd, "gui/501")) {
        throw new Error("Could not find service");
      }
      if (isPrintService(cmd, "user/501")) {
        return runningPrint;
      }
      if (isPrintDomain(cmd, "gui/501")) {
        return "gui domain available";
      }
      return "";
    });

    const result = restartService();
    expect(result.ok).toBe(true);
    expect(result.message).toContain("restarted");
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl kickstart -k user/501/dev.chaosdonkey.oppi",
      { stdio: "pipe" },
    );
    expect(mockExecSync).not.toHaveBeenCalledWith(
      "launchctl kickstart -k gui/501/dev.chaosdonkey.oppi",
      { stdio: "pipe" },
    );
  });

  it("stops a user-domain job when gui bootout is unsupported", () => {
    mockExistsSync.mockReturnValue(true);
    let userLoaded = true;
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout gui/501")) {
        throw new Error("125: Domain does not support specified action");
      }
      if (cmd.includes("bootout user/501")) {
        userLoaded = false;
        return "";
      }
      if (isPrintService(cmd, "gui/501")) {
        throw new Error("Could not find service");
      }
      if (isPrintService(cmd, "user/501")) {
        if (userLoaded) return runningPrint;
        throw new Error("Could not find service");
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = stopService();
    expect(result.ok).toBe(true);
    expect(result.message).toContain("stopped");
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
  });

  it("uninstall bootouts the job in both domains", () => {
    mockExistsSync.mockReturnValue(true);

    const result = uninstallService();
    expect(result.ok).toBe(true);
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout gui/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl bootout user/501/dev.chaosdonkey.oppi 2>/dev/null",
      { stdio: "pipe" },
    );
  });
});

// ── launchctl 125 leftover jobs ────────────────────────────────────────────

describe("launchctl leftover jobs", () => {
  const plist = "/Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist";
  const runningPrint = ["dev.chaosdonkey.oppi = {", "  pid = 12345", "  state = running", "}"].join(
    "\n",
  );
  const error125 = new Error("125: Domain does not support specified action");
  const notFound = new Error("Could not find service");

  it("stop fails when owning-domain bootout returns 125 and the other domain is empty", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) throw error125;
      if (isPrintService(cmd, "gui/501")) return runningPrint;
      if (isPrintService(cmd, "user/501")) throw notFound;
      return "";
    });

    const result = stopService();
    expect(result.ok).toBe(false);
    expect(result.message).not.toMatch(/not running/i);
    expect(result.message).toMatch(/loaded/i);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && isPrintService(cmd, "gui/501"),
      ),
    ).toBe(true);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && isPrintService(cmd, "user/501"),
      ),
    ).toBe(true);
  });

  it("stop fails when a user-domain job survives GUI-preferred bootout 125", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) throw error125;
      if (isPrintService(cmd, "gui/501")) throw notFound;
      if (isPrintService(cmd, "user/501")) return runningPrint;
      return "";
    });

    const result = stopService();
    expect(result.ok).toBe(false);
    expect(result.message).not.toMatch(/not running/i);
    expect(result.message).toMatch(/loaded/i);
  });

  it("install does not bootstrap GUI or kickstart while a user-domain job remains loaded", () => {
    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      if (p === plist) return true;
      return false;
    });
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("--version")) return "v25.0.0";
      if (cmd.includes("bootout")) throw error125;
      if (cmd.includes("bootstrap")) throw new Error("37: Service is already loaded");
      if (isPrintService(cmd, "user/501")) return runningPrint;
      if (isPrintAnyService(cmd)) throw notFound;
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toMatch(/unload|loaded/i);
    expect(result.message).toContain("user/501");
    expect(mockWriteFileSync).not.toHaveBeenCalled();
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("bootstrap"))).toBe(false);
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("kickstart"))).toBe(false);
  });

  it("uninstall does not unlink the plist when a job remains loaded after bootout 125", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) throw error125;
      if (isPrintService(cmd, "gui/501")) return runningPrint;
      if (isPrintService(cmd, "user/501")) throw notFound;
      return "";
    });

    const result = uninstallService();
    expect(result.ok).toBe(false);
    expect(result.message).toMatch(/unload|loaded/i);
    expect(result.message).toContain("gui/501");
    expect(mockUnlinkSync).not.toHaveBeenCalled();
  });

  it("keeps bootstrap 125 fail-closed when GUI probing succeeded", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("--version")) return "v25.0.0";
      if (cmd.includes("bootstrap")) throw error125;
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to load LaunchAgent");
    const bootstrapCalls = mockExecSync.mock.calls
      .map(([cmd]) => cmd as string)
      .filter((cmd) => cmd.includes("bootstrap"));
    expect(bootstrapCalls).toEqual([`launchctl bootstrap gui/501 ${plist}`]);
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("kickstart"))).toBe(false);
  });

  it("uninstall fails closed on a missing-plist orphan that remains loaded", () => {
    mockExistsSync.mockReturnValue(false);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout")) throw error125;
      if (isPrintService(cmd, "user/501")) return runningPrint;
      if (isPrintService(cmd, "gui/501")) throw notFound;
      return "";
    });

    const result = uninstallService();
    expect(result.ok).toBe(false);
    expect(result.message).toMatch(/unload|loaded/i);
    expect(result.message).toContain("user/501");
    expect(result.message).not.toMatch(/not installed/i);
    expect(mockUnlinkSync).not.toHaveBeenCalled();
  });

  it("status reports a loaded job even when the plist is missing", () => {
    mockExistsSync.mockReturnValue(false);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintService(cmd, "gui/501")) throw notFound;
      if (isPrintService(cmd, "user/501")) return runningPrint;
      return "";
    });

    const status = getServiceStatus();
    expect(status.installed).toBe(false);
    expect(status.running).toBe(true);
    expect(status.pid).toBe(12345);
  });

  it("stop still succeeds when GUI bootout is 125 but the job is then absent", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootout gui/501/")) throw error125;
      if (cmd.includes("bootout user/501/")) return "";
      return defaultLaunchctlOutput(cmd);
    });

    const result = stopService();
    expect(result.ok).toBe(true);
    expect(result.message).not.toMatch(/loaded/i);
  });

  it("stop unloads a GUI job that stays loaded after a successful label bootout by booting out the plist", () => {
    let guiLoaded = true;
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes(`launchctl bootout gui/501 ${plist}`)) {
        guiLoaded = false;
        return "";
      }
      if (cmd.includes("launchctl bootout")) return "";
      if (isPrintService(cmd, "gui/501")) {
        if (guiLoaded) return runningPrint;
        throw notFound;
      }
      if (isPrintService(cmd, "user/501")) throw notFound;
      return defaultLaunchctlOutput(cmd);
    });

    const result = stopService();
    expect(result.ok).toBe(true);
    expect(result.message).toContain("stopped");
    expect(result.message).not.toMatch(/not running/i);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && cmd.includes("bootout gui/501/dev.chaosdonkey.oppi"),
      ),
    ).toBe(true);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && cmd.includes("bootout user/501/dev.chaosdonkey.oppi"),
      ),
    ).toBe(true);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && cmd.includes(`bootout gui/501 ${plist}`),
      ),
    ).toBe(true);
    expect(
      mockExecSync.mock.calls.some(
        ([cmd]) => typeof cmd === "string" && cmd.includes(`bootout user/501 ${plist}`),
      ),
    ).toBe(true);
  });
});

// ── launchctl error classification ─────────────────────────────────────────

describe("launchctl error classification", () => {
  const unexpectedPrint = execError("5: Input/output error", 5);
  const error125 = new Error("125: Domain does not support specified action");

  it("does not treat bootstrap 125 as already-loaded when uid or path contains 37", () => {
    process.getuid = () => 537;
    mockHomedir.mockReturnValue("/Users/chen37");
    setupValidInstall();
    const plist = "/Users/chen37/Library/LaunchAgents/dev.chaosdonkey.oppi.plist";
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootstrap")) {
        throw execError(
          `Command failed: ${cmd}\nBootstrap failed: 125: Domain does not support specified action`,
          125,
        );
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to load LaunchAgent");
    expect(result.message).toContain("125");
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("kickstart"))).toBe(false);
    const bootstrapCalls = mockExecSync.mock.calls
      .map(([cmd]) => cmd as string)
      .filter((cmd) => cmd.includes("bootstrap"));
    expect(bootstrapCalls).toEqual([`launchctl bootstrap gui/537 ${plist}`]);
  });

  it("still kickstarts on bootstrap 37 when uid or path contains 37", () => {
    process.getuid = () => 537;
    mockHomedir.mockReturnValue("/Users/chen37");
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (cmd.includes("bootstrap")) {
        throw execError(
          `Command failed: ${cmd}\nBootstrap failed: 37: Operation already in progress`,
          37,
        );
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    expect(mockExecSync).toHaveBeenCalledWith(
      "launchctl kickstart -k gui/537/dev.chaosdonkey.oppi",
      { stdio: "pipe" },
    );
  });

  it("install does not bootstrap after an unexpected service print failure", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintService(cmd, "gui/501") || isPrintService(cmd, "user/501")) {
        throw unexpectedPrint;
      }
      if (cmd.includes("bootout")) throw error125;
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to load LaunchAgent");
    expect(result.message).not.toMatch(/not running|not installed/i);
    expect(mockWriteFileSync).not.toHaveBeenCalled();
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("bootstrap"))).toBe(false);
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("kickstart"))).toBe(false);
  });

  it("uninstall does not unlink after an unexpected service print failure", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintAnyService(cmd)) throw unexpectedPrint;
      if (cmd.includes("bootout")) throw error125;
      return defaultLaunchctlOutput(cmd);
    });

    const result = uninstallService();
    expect(result.ok).toBe(false);
    expect(result.message).not.toMatch(/not installed/i);
    expect(mockUnlinkSync).not.toHaveBeenCalled();
  });

  it("stop does not report absence after an unexpected service print failure", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintAnyService(cmd)) throw unexpectedPrint;
      if (cmd.includes("bootout")) throw error125;
      return defaultLaunchctlOutput(cmd);
    });

    const result = stopService();
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Stop failed");
    expect(result.message).not.toMatch(/not running/i);
  });

  it("does not fall back to user domain when GUI print fails unexpectedly", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintDomain(cmd, "gui/501")) throw unexpectedPrint;
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("Failed to load LaunchAgent");
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("bootstrap"))).toBe(false);
  });

  it("status does not treat an unexpected print failure as not running", () => {
    mockExistsSync.mockReturnValue(true);
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintAnyService(cmd)) throw unexpectedPrint;
      return defaultLaunchctlOutput(cmd);
    });

    expect(() => getServiceStatus()).toThrow(/Input\/output error/);
  });

  it("treats launchctl print exit 113 without stderr text as service absence", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintAnyService(cmd)) {
        throw execError(`Command failed: ${cmd}`, 113);
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    expect(mockExecSync.mock.calls.some(([cmd]) => String(cmd).includes("bootstrap"))).toBe(true);
  });

  it("treats launchctl print exit 112 without stderr text as GUI domain absence", () => {
    setupValidInstall();
    mockExecSync.mockImplementation((cmd: string) => {
      if (isPrintDomain(cmd, "gui/501")) {
        throw execError(`Command failed: ${cmd}`, 112);
      }
      return defaultLaunchctlOutput(cmd);
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(true);
    const bootstrapCalls = mockExecSync.mock.calls
      .map(([cmd]) => cmd as string)
      .filter((cmd) => cmd.includes("bootstrap"));
    expect(bootstrapCalls).toEqual([
      "launchctl bootstrap user/501 /Users/testuser/Library/LaunchAgents/dev.chaosdonkey.oppi.plist",
    ]);
  });
});

// ── uid() edge case ────────────────────────────────────────────────────────

describe("uid unavailable", () => {
  it("installService returns error when getuid is not available", () => {
    // Remove getuid to simulate non-macOS
    process.getuid = undefined as unknown as () => number;

    mockExistsSync.mockImplementation((p: string) => {
      if (p === "/opt/homebrew/bin/node") return true;
      if (p === "/opt/homebrew/lib/node_modules/oppi-server/dist/src/cli.js") return true;
      // No existing plist, so bootout path is skipped — uid() is hit at bootstrap
      if (p.endsWith(".plist")) return false;
      return false;
    });

    const result = installService("/tmp/data");
    expect(result.ok).toBe(false);
    expect(result.message).toContain("uid() not available");
  });
});
