import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const app = vi.hoisted(() => ({
  runCli: vi.fn(async () => ({ ok: true, exitCode: 0, stdout: "", humanOutput: "" })),
}));

const lifecycle = vi.hoisted(() => ({
  getServiceStatus: vi.fn(() => ({
    installed: false,
    running: false,
    pid: null,
    plistPath: "/tmp/oppi-test.plist",
    label: "dev.chaosdonkey.oppi",
  })),
  installService: vi.fn(() => ({ ok: true, message: "should not run" })),
  readInstalledPlist: vi.fn(() => null),
  restartService: vi.fn(() => ({ ok: true, message: "should not run" })),
  stopService: vi.fn(() => ({ ok: true, message: "should not run" })),
  uninstallService: vi.fn(() => ({ ok: true, message: "should not run" })),
}));

vi.mock("../src/launchd.js", () => lifecycle);
vi.mock("../src/cli/runner.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../src/cli/runner.js")>();
  return { ...actual, runCli: app.runCli };
});

import { runCliMain } from "../src/cli.js";
import {
  helpPathFor,
  isNestedHelpRequest,
  listCliHelpTopicPaths,
  resolveHelpTopic,
} from "../src/cli/help.js";
import { parseCliArgs } from "../src/cli/args.js";
import { captureCliOutput } from "../src/cli/output.js";

const tempDirs: string[] = [];

const MUTATING_AND_LIFECYCLE_HELP_PATHS = [
  ["init"],
  ["serve"],
  ["start"],
  ["pair"],
  ["update"],
  ["token", "rotate"],
  ["config", "set"],
  ["server", "install"],
  ["server", "uninstall"],
  ["server", "restart"],
  ["server", "stop"],
  ["server", "status"],
  ["workspace", "create"],
  ["workspace", "update"],
  ["workspace", "delete"],
  ["worktree", "create"],
  ["worktree", "open"],
  ["worktree", "remove"],
  ["schedule", "create"],
  ["schedule", "update"],
  ["schedule", "run"],
  ["schedule", "pause"],
  ["schedule", "resume"],
  ["schedule", "archive"],
  ["schedule", "restore"],
  ["session", "create"],
  ["session", "send"],
  ["session", "abort"],
  ["session", "stop"],
  ["session", "resume"],
  ["session", "fork"],
  ["session", "delete"],
  ["agent", "create"],
  ["agent", "update"],
  ["agent", "archive"],
] as const;

beforeEach(() => {
  vi.clearAllMocks();
  const home = mkdtempSync(join(tmpdir(), "oppi-help-home-"));
  const dataDir = mkdtempSync(join(tmpdir(), "oppi-help-data-"));
  tempDirs.push(home, dataDir);
  vi.stubEnv("HOME", home);
  vi.stubEnv("OPPI_DATA_DIR", dataDir);
});

afterEach(() => {
  vi.unstubAllEnvs();
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("centralized nested-help dispatch", () => {
  it("treats the incident token sequence as help before server lifecycle dispatch", () => {
    const parsed = parseCliArgs(["server", "install", "help"]);

    expect(isNestedHelpRequest(parsed.command, parsed.positional, parsed.flags)).toBe(true);
    expect(helpPathFor(parsed.command, parsed.positional)).toEqual(["server", "install"]);
  });

  it("renders exact `server install help` safely without calling lifecycle code", async () => {
    const captured = await captureCliOutput(() => runCliMain(["server", "install", "help"]), {
      includeHuman: true,
    });

    expect(captured.exitCode).toBe(0);
    expect(captured.stdout).toBe("");
    expect(captured.humanStdout).toContain("Install background server");
    expect(lifecycle.installService).not.toHaveBeenCalled();
    expect(lifecycle.restartService).not.toHaveBeenCalled();
    expect(lifecycle.stopService).not.toHaveBeenCalled();
    expect(lifecycle.uninstallService).not.toHaveBeenCalled();
    expect(lifecycle.getServiceStatus).not.toHaveBeenCalled();
    expect(lifecycle.readInstalledPlist).not.toHaveBeenCalled();
    expect(app.runCli).not.toHaveBeenCalled();
  });

  it("keeps JSON help deterministic and side-effect-free for the incident spelling", async () => {
    const captured = await captureCliOutput(
      () => runCliMain(["server", "install", "help", "--json"]),
      { includeHuman: true },
    );

    expect(captured.exitCode).toBe(0);
    expect(JSON.parse(captured.stdout)).toMatchObject({
      ok: true,
      data: { help: { path: ["server", "install"] } },
    });
    expect(captured.humanStdout).toContain("Install background server");
    expect(lifecycle.installService).not.toHaveBeenCalled();
    expect(lifecycle.getServiceStatus).not.toHaveBeenCalled();
    expect(lifecycle.readInstalledPlist).not.toHaveBeenCalled();
    expect(app.runCli).not.toHaveBeenCalled();
  });

  it.each(MUTATING_AND_LIFECYCLE_HELP_PATHS.map((path) => [path] as const))(
    "does not dispatch mutating or lifecycle command %s for a bare help token",
    async (path) => {
      const args = [...path, "help"];
      const captured = await captureCliOutput(() => runCliMain(args), { includeHuman: true });

      expect(captured.exitCode, args.join(" ")).toBe(0);
      expect(captured.humanStdout, args.join(" ")).toContain("Usage:");
      expect(app.runCli, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.installService, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.restartService, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.stopService, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.uninstallService, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.getServiceStatus, args.join(" ")).not.toHaveBeenCalled();
      expect(lifecycle.readInstalledPlist, args.join(" ")).not.toHaveBeenCalled();
    },
  );

  it("preserves normal app-state dispatch after the help guard", async () => {
    await runCliMain(["session", "list", "--json"]);

    expect(app.runCli).toHaveBeenCalledOnce();
    expect(app.runCli).toHaveBeenCalledWith(["session", "list", "--json"]);
  });

  it.each([
    ["server", "install", "ignored", "help"],
    ["session", "delete", "ignored", "help"],
    ["workspace", "remove", "ignored", "help"],
  ] as const)("short-circuits misplaced help after ignored positionals: %s", async (...args) => {
    const captured = await captureCliOutput(() => runCliMain(args), { includeHuman: true });

    expect(captured.exitCode, args.join(" ")).toBe(0);
    expect(captured.humanStdout, args.join(" ")).toContain("Usage:");
    expect(app.runCli, args.join(" ")).not.toHaveBeenCalled();
    expect(lifecycle.installService, args.join(" ")).not.toHaveBeenCalled();
  });

  it.each([
    ["session", "changes"],
    ["session", "diff"],
    ["session", "dialogs"],
    ["session", "respond"],
    ["skill"],
    ["skill", "list"],
    ["skill", "get"],
    ["skill", "file"],
    ["skill", "update-file"],
  ])("does not discover removed %s help", (path) => {
    expect(resolveHelpTopic(path)).toBeUndefined();
  });

  it("handles unknown help topics deterministically without dispatch", async () => {
    const roots = listCliHelpTopicPaths().filter((path) => path.length === 1);

    for (const [root] of roots) {
      const captured = await captureCliOutput(
        () => runCliMain([root!, "not-a-command", "help", "--json"]),
        { includeHuman: true },
      );
      const topic = resolveHelpTopic([root!]);

      if (topic?.subcommands?.length) {
        expect(captured.exitCode, root).toBe(1);
        expect(JSON.parse(captured.stdout), root).toEqual({
          ok: false,
          error: { message: `No help topic for ${root} not-a-command` },
        });
      } else {
        expect(captured.exitCode, root).toBe(0);
        expect(JSON.parse(captured.stdout), root).toMatchObject({
          ok: true,
          data: { help: { path: [root] } },
        });
      }
    }

    expect(app.runCli).not.toHaveBeenCalled();
    expect(lifecycle.installService).not.toHaveBeenCalled();
  });

  it.each([
    ["server", "install", "--help", "ignored"],
    ["server", "install", "--help=false"],
    ["server", "install", "-h", "ignored"],
  ] as const)("fails safe for boolean/help flag variants: %s", async (...args) => {
    const captured = await captureCliOutput(() => runCliMain(args), { includeHuman: true });

    expect(captured.exitCode, args.join(" ")).toBe(0);
    expect(captured.humanStdout, args.join(" ")).toContain("Install background server");
    expect(app.runCli, args.join(" ")).not.toHaveBeenCalled();
    expect(lifecycle.installService, args.join(" ")).not.toHaveBeenCalled();
  });

  it("audits every authoritative help topic through trailing and leading bare-help spellings", async () => {
    const allPaths = listCliHelpTopicPaths();
    for (const args of [
      ["help", "--json"],
      ["--help", "--json"],
      ["-h", "--json"],
    ]) {
      const root = await captureCliOutput(() => runCliMain(args), { includeHuman: true });
      expect(root.exitCode, args.join(" ")).toBe(0);
      expect(JSON.parse(root.stdout), args.join(" ")).toMatchObject({
        ok: true,
        data: { help: { path: [] } },
      });
    }

    const paths = allPaths.filter((path) => path.length > 0);

    for (const path of paths) {
      const variants = [
        [...path, "help", "--json"],
        [...path, "--help", "--json"],
        [...path, "-h", "--json"],
        [path[0]!, "help", ...path.slice(1), "--json"],
        ["help", ...path, "--json"],
      ];
      if (path.length > 1) variants.push([...path, "ignored", "help", "--json"]);

      for (const args of variants) {
        const captured = await captureCliOutput(() => runCliMain(args), { includeHuman: true });
        const label = args.join(" ");
        expect(captured.exitCode, label).toBe(0);
        expect(JSON.parse(captured.stdout), label).toMatchObject({
          ok: true,
          data: { help: { path } },
        });
        expect(captured.humanStdout, label).toContain("Usage:");
      }
    }

    expect(allPaths.length).toBe(76);
    expect(paths.length).toBe(75);
    expect(app.runCli).not.toHaveBeenCalled();
    expect(lifecycle.installService).not.toHaveBeenCalled();
    expect(lifecycle.restartService).not.toHaveBeenCalled();
    expect(lifecycle.stopService).not.toHaveBeenCalled();
    expect(lifecycle.uninstallService).not.toHaveBeenCalled();
    expect(lifecycle.getServiceStatus).not.toHaveBeenCalled();
  });

  it.each([
    [
      ["workspace", "remove", "help", "--json"],
      ["workspace", "delete"],
    ],
    [
      ["session", "start", "help", "--json"],
      ["session", "create"],
    ],
  ] as const)("resolves compatibility aliases before dispatch: %s", async (args, path) => {
    const captured = await captureCliOutput(() => runCliMain(args), { includeHuman: true });

    expect(captured.exitCode, args.join(" ")).toBe(0);
    expect(JSON.parse(captured.stdout), args.join(" ")).toMatchObject({
      ok: true,
      data: { help: { path } },
    });
    expect(app.runCli, args.join(" ")).not.toHaveBeenCalled();
  });
});
