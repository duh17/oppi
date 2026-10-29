/**
 * Give each test file its own TMPDIR and fail the file if it leaves anything in it.
 *
 * os.tmpdir() reads TMPDIR on every call, so every mkdtemp(join(tmpdir(), ...)) in a test or
 * in the code under test lands in the file's private directory, as do child processes that
 * inherit the environment. The directory lives in the run's private root
 * (vitest.global-setup.ts) so concurrent runs never share entries. After the file's own
 * hooks have run, whatever is still there is a leak: it is removed and reported by name,
 * which fails the file. Fix the leak with an afterEach/afterAll `rmSync(dir, { recursive:
 * true, force: true })` (or the code under test's dispose), never by loosening this check.
 *
 * Must be listed before vitest.setup.ts in `setupFiles`: Vitest runs afterAll hooks in
 * reverse registration order, so setup-owned directories are removed before this check.
 */
import { mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, sep } from "node:path";
import { afterAll, expect } from "vitest";

const runRoot = process.env.OPPI_VITEST_RUN_TMP;

/**
 * Entries that tooling and production code keep in the temp dir under fixed names by design:
 * module-loader caches (jiti, tsx) and the sandbox/git helper dirs. They are reused,
 * not accumulated, so they are not leaks; they still go away with the file's directory.
 */
const SHARED_BY_DESIGN = /^(?:jiti|tsx-\d+|oppi-sandbox-pi-overlay|oppi-sandbox-git-\d+)$/;

/**
 * A server a test forgot to stop can still be writing; retry, then give up quietly: the file
 * directory is inside the run root, which global teardown removes.
 */
function removeTree(path: string): void {
  try {
    rmSync(path, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  } catch {
    /* removed with the run root */
  }
}

if (runRoot) {
  const inheritedTmpdir = process.env.TMPDIR;
  // Node processes (this worker and the CLIs and helpers tests spawn) keep their compile cache
  // in `$TMPDIR/node-compile-cache` and write it when they exit, possibly after this file's
  // directory is gone. Pin it to the shared TMPDIR's reused directory before redirecting.
  process.env.NODE_COMPILE_CACHE ??= join(tmpdir(), "node-compile-cache");
  // A trailing separator makes mkdtemp create the directory inside the root (join() drops it).
  const fileTmp = mkdtempSync(`${runRoot}${sep}`);
  process.env.TMPDIR = fileTmp;

  afterAll(() => {
    if (inheritedTmpdir === undefined) delete process.env.TMPDIR;
    else process.env.TMPDIR = inheritedTmpdir;
    const leftovers = readdirSync(fileTmp).filter((name) => !SHARED_BY_DESIGN.test(name));
    removeTree(fileTmp);
    if (leftovers.length > 0)
      throw new Error(
        `${expect.getState().testPath ?? "test file"} left ${leftovers.length} temp entries in TMPDIR (removed): ${leftovers.join(", ")}`,
      );
  });
}
