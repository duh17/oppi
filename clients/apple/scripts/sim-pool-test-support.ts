import { existsSync, readFileSync } from "node:fs";

/**
 * Timing for the sim-pool script tests, which spawn many Bun and shell processes.
 *
 * Every Bun start resolves its entry file and working directory up through their parents, so a
 * temp directory with hundreds of thousands of entries made each start cost about 0.65 s even idle,
 * and several times that while the pre-push gate is building. A pool CLI call is one such start
 * plus a dozen fake simctl/xcodebuild spawns. Measured that way, with 16 CPU burners and the test
 * process at background QoS, 12 tests ran into Bun's 5 s default and the slowest pool CLI test (an
 * explicit 60 s limit) took 38 s, so:
 *
 * - SUBPROCESS_TEST_TIMEOUT_MS is the per-file default for tests that spawn processes. It is far
 *   above anything measured and only bounds a real hang.
 * - SPAWN_WAIT_MS bounds each wait for a spawned process to do something (publish a file, print a
 *   line). It is shorter than the test timeout so a stuck process fails with a message naming what
 *   it never did, not with a bare test timeout.
 */
export const SUBPROCESS_TEST_TIMEOUT_MS = 60_000;
export const SPAWN_WAIT_MS = 30_000;

/**
 * Resolves with the file's contents once it exists and is not empty (a writer that creates the
 * file before writing it is not yet done); rejects with the path when that never happens.
 */
export function waitForFile(path: string, timeoutMs = SPAWN_WAIT_MS): Promise<string> {
  const start = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      if (existsSync(path)) {
        const text = readFileSync(path, "utf8");
        if (text.trim().length > 0) {
          resolve(text);
          return;
        }
      }
      if (Date.now() - start > timeoutMs) {
        reject(new Error(`timeout waiting for ${path}`));
        return;
      }
      setTimeout(tick, 20);
    };
    tick();
  });
}

/** Resolves once `ready()` is true; rejects naming `what` when it never becomes true. */
export async function waitUntil(ready: () => boolean, what: string, timeoutMs = SPAWN_WAIT_MS): Promise<void> {
  const start = Date.now();
  while (!ready()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(`timeout waiting for ${what}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}
