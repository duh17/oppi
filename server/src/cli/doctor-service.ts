import { existsSync } from "node:fs";
import { userInfo } from "node:os";
import * as launchd from "../launchd.js";
import * as systemd from "../systemd.js";

export type DoctorCheck = { level: "pass" | "warn" | "fail"; message: string };

/** One platform's background-service manager, as `oppi doctor` sees it. */
export interface DoctorServiceManager {
  /** How the service is named in messages, e.g. "LaunchAgent". */
  label: string;
  status(): { installed: boolean; running: boolean; pid: number | null; linger?: boolean | null };
  installedPaths(): { runtimePath: string; cliPath: string } | null;
  /** A reason the installed service should be reinstalled, if any. */
  migrationWarning?(paths: { runtimePath: string; cliPath: string }): string | null;
}

const launchAgent: DoctorServiceManager = {
  label: "LaunchAgent",
  status: () => launchd.getServiceStatus(),
  installedPaths: () => launchd.readInstalledPlist(),
  migrationWarning: (paths) => launchd.launchAgentRuntimeMigrationWarning(paths),
};

const systemdUserService: DoctorServiceManager = {
  label: "systemd user service",
  status: () => systemd.getServiceStatus(),
  installedPaths: () => systemd.readInstalledUnit(),
};

/**
 * The service manager `oppi server install` uses on this platform. Other platforms have
 * none: probing `launchctl` or `systemctl` there would fail, and `oppi serve` runs under
 * the host's own supervisor.
 */
export function doctorServiceManager(platform: NodeJS.Platform): DoctorServiceManager | undefined {
  if (platform === "darwin") return launchAgent;
  if (platform === "linux") return systemdUserService;
  return undefined;
}

export interface DoctorServiceReport {
  installed: boolean;
  checks: DoctorCheck[];
}

/** Doctor checks for the background service. Undefined when the platform has none. */
export function inspectService(
  manager: DoctorServiceManager | undefined,
  options: { user?: string } = {},
): DoctorServiceReport | undefined {
  if (!manager) return undefined;
  const { label } = manager;
  const status = manager.status();
  const checks: DoctorCheck[] = [];

  if (!status.installed) {
    checks.push({
      level: "warn",
      message: `${label} not installed (oppi server install for background service)`,
    });
    return { installed: false, checks };
  }

  checks.push({ level: "pass", message: `${label} installed` });
  checks.push(
    status.running
      ? { level: "pass", message: `${label} running (PID ${status.pid})` }
      : { level: "warn", message: `${label} installed but not running (oppi server restart)` },
  );

  // Without lingering, the user manager and Oppi stop at logout.
  if (status.linger === false) {
    const user = options.user ?? userInfo().username;
    checks.push({
      level: "warn",
      message: `${label} stops when you log out until an admin runs: sudo loginctl enable-linger ${user}`,
    });
  }

  const paths = manager.installedPaths();
  if (paths) {
    if (!existsSync(paths.runtimePath)) {
      checks.push({
        level: "fail",
        message: `${label} runtime missing: ${paths.runtimePath} (oppi server install to fix)`,
      });
    }
    if (!existsSync(paths.cliPath)) {
      checks.push({
        level: "fail",
        message: `${label} CLI missing: ${paths.cliPath} (oppi server install to fix)`,
      });
    }
    const migration = manager.migrationWarning?.(paths);
    if (migration) checks.push({ level: "warn", message: migration });
  }

  return { installed: true, checks };
}
