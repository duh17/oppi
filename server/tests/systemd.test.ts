/**
 * systemd user-unit generation: where the unit goes, and that ExecStart and
 * Environment carry exact paths through systemd's quoting, specifier (`%`),
 * and ExecStart variable (`$`) rules.
 */
import { describe, expect, it } from "vitest";

import { buildSystemdUnit, parseSystemdUnit, systemdUnitPath } from "../src/systemd.js";

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
