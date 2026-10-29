import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, readdirSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const serverRoot = dirname(fileURLToPath(import.meta.url));

/** Name prefix of a run's private temp root; the pid lets a later run recognise a dead one. */
const RUN_ROOT_PREFIX = "ovt";

/**
 * Where run roots live. A test's data dir sits under the root and its `run/oppi.sock` must
 * stay within the 100-byte socket path cap, or the server falls back to /tmp, outside the temp
 * guard. macOS's default $TMPDIR (`/var/folders/xx/<hash>/T/`) is 49 bytes before the test
 * adds anything, so prefer the short `/tmp`; use $TMPDIR where /tmp is unavailable.
 */
function runRootParents(): string[] {
  return process.platform === "win32" ? [tmpdir()] : ["/tmp", tmpdir()];
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means the process exists but belongs to someone else.
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Remove run roots left by runs that were killed before their teardown ran. */
function removeDeadRunRoots(parent: string): void {
  for (const name of readdirSync(parent)) {
    const match = new RegExp(`^${RUN_ROOT_PREFIX}(\\d+)$`).exec(name);
    if (!match) continue;
    const pid = Number(match[1]);
    if (pid === process.pid || processIsAlive(pid)) continue;
    try {
      rmSync(join(parent, name), { recursive: true, force: true });
    } catch {
      // Another user's dead root in a shared temp dir (EPERM) is not this run's to remove.
    }
  }
}

function createRunRoot(): string {
  let failure: unknown;
  for (const parent of runRootParents()) {
    try {
      removeDeadRunRoots(parent);
      // The pid is unique among live processes, so a same-named root is a dead run's.
      const runRoot = join(parent, `${RUN_ROOT_PREFIX}${process.pid}`);
      rmSync(runRoot, { recursive: true, force: true });
      mkdirSync(runRoot);
      return runRoot;
    } catch (error) {
      failure = error;
    }
  }
  throw failure;
}

/**
 * Every test file runs with TMPDIR pointing into one run-private root
 * (`/tmp/ovt<pid>`, see vitest.temp-guard.ts), so nothing a test creates lands in
 * the shared temp dir and concurrent runs never see each other's entries. Teardown removes
 * the root, and a run killed before teardown is swept by the next run.
 */
export default function buildCliOnce(): () => void {
  execFileSync(
    process.execPath,
    [join(serverRoot, "scripts", "ensure-installed-deps.mjs"), "--check"],
    {
      cwd: serverRoot,
      stdio: "inherit",
    },
  );

  const runRoot = createRunRoot();
  process.env.OPPI_VITEST_RUN_TMP = runRoot;

  const buildRoot = join(runRoot, "build");
  mkdirSync(buildRoot);

  try {
    execFileSync(
      process.execPath,
      [
        join(serverRoot, "node_modules", "@typescript", "native", "bin", "tsc"),
        "--outDir",
        buildRoot,
      ],
      {
        cwd: serverRoot,
        stdio: "inherit",
      },
    );
    for (const script of ["copy-oppi-docs.mjs", "copy-durable-packages.mjs"])
      execFileSync(process.execPath, [join(serverRoot, "scripts", script)], {
        cwd: serverRoot,
        env: { ...process.env, OPPI_BUILD_DIR: buildRoot },
        stdio: "inherit",
      });

    symlinkSync(join(serverRoot, "node_modules"), join(buildRoot, "node_modules"), "dir");

    const cliPath = join(buildRoot, "src", "cli.js");
    chmodSync(cliPath, 0o755);
    process.env.OPPI_TEST_CLI = cliPath;
  } catch (error) {
    rmSync(runRoot, { recursive: true, force: true });
    throw error;
  }

  return () => {
    // Per-file leaks fail their file (vitest.temp-guard.ts). What remains here was written
    // after a file's own cleanup (a stopped server's last write) or by a dead worker; it
    // stays inside the run root, so removing the root is all that is needed.
    rmSync(runRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  };
}
