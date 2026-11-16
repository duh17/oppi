/**
 * systemd user-unit generation: where the unit goes, and that ExecStart and
 * Environment carry exact paths through systemd's quoting, specifier (`%`),
 * and ExecStart variable (`$`) rules.
 */
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { parseCliArgs } from "../src/cli/args.js";
import { unsupportedFlagsMessage } from "../src/cli/help.js";
import {
  buildSystemdUnit,
  installService,
  parseSystemdUnit,
  systemdUnitPath,
  undoLinger,
} from "../src/systemd.js";

function line(unit: string, prefix: string): string[] {
  return unit.split("\n").filter((l) => l.startsWith(prefix));
}

describe("systemdUnitPath", () => {
  it("uses ~/.config/systemd/user without XDG_CONFIG_HOME", () => {
    expect(systemdUnitPath({}, "/home/alice")).toBe(
      "/home/alice/.config/systemd/user/oppi.service",
    );
  });

  it("follows an absolute XDG_CONFIG_HOME and ignores a relative one", () => {
    expect(systemdUnitPath({ XDG_CONFIG_HOME: "/srv/cfg" }, "/home/alice")).toBe(
      "/srv/cfg/systemd/user/oppi.service",
    );
    expect(systemdUnitPath({ XDG_CONFIG_HOME: "cfg" }, "/home/alice")).toBe(
      "/home/alice/.config/systemd/user/oppi.service",
    );
  });
});

describe("buildSystemdUnit", () => {
  const node = "/home/alice/.oppi/runtime/node/bin/node";
  const cli = "/home/alice/.oppi/install/current/lib/node_modules/oppi-server/dist/src/cli.js";

  it("starts the CLI with flags its serve help topic accepts", () => {
    const unit = buildSystemdUnit(node, cli, "/home/alice/.config/oppi");
    const execStart = line(unit, "ExecStart=")[0] ?? "";
    // The test paths need no escapes, so each quoted word is the argv word.
    const argv = [...execStart.matchAll(/"([^"]*)"/g)].map((match) => match[1] ?? "");
    expect(argv.slice(0, 2)).toEqual([node, cli]);
    expect(unsupportedFlagsMessage(parseCliArgs(argv.slice(2)))).toBeUndefined();
  });

  it("runs serve with the chosen runtime and CLI by absolute path", () => {
    const unit = buildSystemdUnit(node, cli, "/home/alice/.config/oppi");
    expect(line(unit, "ExecStart=")).toEqual([
      `ExecStart="${node}" "${cli}" "serve" "--data-dir" "/home/alice/.config/oppi"`,
    ]);
    expect(parseSystemdUnit(unit)).toEqual({
      runtimePath: node,
      cliPath: cli,
      dataDir: "/home/alice/.config/oppi",
    });
  });

  it("puts the runtime's directory first on the service PATH without duplicates", () => {
    const unit = buildSystemdUnit("/usr/bin/node", cli, "/data");
    expect(line(unit, "Environment=")).toEqual([
      'Environment="PATH=/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin"',
      'Environment="OPPI_DATA_DIR=/data"',
    ]);
  });

  it("escapes spaces, quotes, backslashes, % specifiers, and $ expansion so paths survive exactly", () => {
    const dataDir = '/home/a b/100%/$HOME/"q"\\x';
    const unit = buildSystemdUnit(node, cli, dataDir);

    expect(line(unit, "ExecStart=")[0]).toContain('"/home/a b/100%%/$$HOME/\\"q\\"\\\\x"');
    // Environment= expands specifiers but not $NAME.
    expect(line(unit, "Environment=")[1]).toBe(
      'Environment="OPPI_DATA_DIR=/home/a b/100%%/$HOME/\\"q\\"\\\\x"',
    );
    expect(parseSystemdUnit(unit)?.dataDir).toBe(dataDir);
  });

  it("refuses a path with a line break, which a unit cannot express", () => {
    expect(() => buildSystemdUnit(node, cli, "/data\nExecStartPre=/bin/false")).toThrow(
      /line break/,
    );
  });
});

describe("parseSystemdUnit", () => {
  it("returns null for a unit that does not run oppi serve --data-dir", () => {
    expect(parseSystemdUnit("[Service]\nExecStart=/usr/bin/true\n")).toBeNull();
    expect(parseSystemdUnit("[Service]\n")).toBeNull();
  });
});

describe("lingering", () => {
  let root: string;
  let calls: string;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "oppi-linger-"));
    calls = join(root, "calls");
    const bin = join(root, "bin");
    mkdirSync(bin);
    // A user manager that accepts everything, and a loginctl whose linger state is a file.
    writeFileSync(join(bin, "systemctl"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
    writeFileSync(
      join(bin, "loginctl"),
      [
        "#!/bin/sh",
        `echo "$*" >>"${calls}"`,
        `state="${join(root, "linger")}"`,
        'case "$1" in',
        '  show-user) cat "$state" 2>/dev/null || echo no ;;',
        '  enable-linger) echo yes >"$state" ;;',
        '  disable-linger) echo no >"$state" ;;',
        "esac",
      ].join("\n"),
      { mode: 0o755 },
    );
    const cli = join(root, "cli.js");
    writeFileSync(cli, "");
    vi.stubEnv("PATH", `${bin}:${process.env.PATH ?? ""}`);
    vi.stubEnv("HOME", root);
    vi.stubEnv("XDG_CONFIG_HOME", join(root, "config"));
    vi.stubEnv("XDG_RUNTIME_DIR", root);
    vi.stubEnv("OPPI_NODE", process.execPath);
    vi.spyOn(process, "argv", "get").mockReturnValue([process.execPath, cli]);
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
    rmSync(root, { recursive: true, force: true });
  });
  const loginctlCalls = (): string[] =>
    existsSync(calls) ? readFileSync(calls, "utf8").trim().split("\n") : [];

  it("is turned off at uninstall only when Oppi turned it on", () => {
    const dataDir = join(root, "data");

    expect(installService(dataDir)).toMatchObject({ ok: true, lingerNote: undefined });
    expect(loginctlCalls()).toContain("enable-linger");
    expect(undoLinger(dataDir)).toMatchObject({ ok: true });
    expect(loginctlCalls()).toContain("disable-linger");
    // Done once: a second uninstall leaves lingering alone.
    expect(undoLinger(dataDir)).toBeNull();
  });

  it("stays on at uninstall when it was on before Oppi", () => {
    const dataDir = join(root, "data");
    writeFileSync(join(root, "linger"), "yes\n");

    expect(installService(dataDir)).toMatchObject({ ok: true });
    expect(undoLinger(dataDir)).toBeNull();
    expect(loginctlCalls()).not.toContain("enable-linger");
    expect(loginctlCalls()).not.toContain("disable-linger");
  });
});
