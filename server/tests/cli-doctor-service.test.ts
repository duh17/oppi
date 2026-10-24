import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  doctorServiceManager,
  inspectService,
  type DoctorServiceManager,
} from "../src/cli/doctor-service.js";

describe("doctor service checks", () => {
  let dir: string;
  let runtimePath: string;
  let cliPath: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oppi-doctor-service-"));
    runtimePath = join(dir, "node");
    cliPath = join(dir, "cli.js");
    writeFileSync(runtimePath, "");
    writeFileSync(cliPath, "");
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  function manager(
    status: Partial<ReturnType<DoctorServiceManager["status"]>>,
    extra: Partial<DoctorServiceManager> = {},
  ): DoctorServiceManager {
    return {
      label: "systemd user service",
      status: () => ({ installed: true, running: true, pid: 4242, linger: true, ...status }),
      installedPaths: () => ({ runtimePath, cliPath }),
      ...extra,
    };
  }

  const messages = (checks: { level: string; message: string }[]): string[] =>
    checks.map((check) => `${check.level}: ${check.message}`);

  it("selects the service manager for the platform", () => {
    expect(doctorServiceManager("linux")?.label).toBe("systemd user service");
    expect(doctorServiceManager("darwin")?.label).toBe("LaunchAgent");
    expect(doctorServiceManager("win32")).toBeUndefined();
    expect(inspectService(undefined)).toBeUndefined();
  });

  it("passes an installed, running service that survives logout", () => {
    const report = inspectService(manager({}), { user: "alice" });
    expect(report?.installed).toBe(true);
    expect(messages(report!.checks)).toEqual([
      "pass: systemd user service installed",
      "pass: systemd user service running (PID 4242)",
    ]);
  });

  it("warns that the service stops at logout when lingering is off", () => {
    const report = inspectService(manager({ linger: false }), { user: "alice" });
    expect(messages(report!.checks)).toContain(
      "warn: systemd user service stops when you log out until an admin runs: sudo loginctl enable-linger alice",
    );
  });

  it("stays silent about lingering when loginctl could not say", () => {
    const report = inspectService(manager({ linger: null }), { user: "alice" });
    expect(report!.checks.some((check) => check.message.includes("enable-linger"))).toBe(false);
  });

  it("reports a stopped service and a missing install", () => {
    const stopped = inspectService(manager({ running: false, pid: null }));
    expect(messages(stopped!.checks)).toContain(
      "warn: systemd user service installed but not running (oppi server restart)",
    );

    const missing = inspectService(manager({ installed: false, running: false, pid: null }));
    expect(missing?.installed).toBe(false);
    expect(messages(missing!.checks)).toEqual([
      "warn: systemd user service not installed (oppi server install for background service)",
    ]);
  });

  it("fails when the installed runtime or CLI is gone", () => {
    rmSync(runtimePath);
    rmSync(cliPath);
    const report = inspectService(manager({}));
    expect(messages(report!.checks)).toEqual(
      expect.arrayContaining([
        `fail: systemd user service runtime missing: ${runtimePath} (oppi server install to fix)`,
        `fail: systemd user service CLI missing: ${cliPath} (oppi server install to fix)`,
      ]),
    );
  });

  it("adds the manager's migration warning only when it has one", () => {
    const withWarning = inspectService(manager({}, { migrationWarning: () => "migrate me" }));
    expect(messages(withWarning!.checks)).toContain("warn: migrate me");
    const without = inspectService(manager({}));
    expect(without!.checks.some((check) => check.message === "migrate me")).toBe(false);
  });
});
