/**
 * Boot the durable runtime's built-in plugins once per test file.
 *
 * The first durable runtime a worker opens imports every built-in plugin and the modules they
 * share: about half a second on an idle machine, several seconds on a busy one, and the same
 * work every later runtime in the file reuses from the module cache. Left to the first test,
 * that boot counts against one test's budget and makes the first test of a durable file the
 * one that times out under load. A file calls this from `beforeAll` so the boot is a step of
 * its own, with its own explicit budget.
 */
import { join } from "node:path";
import { BUILT_IN_PLUGINS_DIR, DurableHarness } from "../../src/durable-harness.js";
import { makeTempDir } from "./temp-dir.js";

/**
 * Generous on purpose: this is a one-time module boot, not behavior under test, and a busy
 * host stretches imports far more than steady-state work.
 */
export const DURABLE_BOOT_TIMEOUT_MS = 60_000;

export async function bootDurablePlugins(): Promise<void> {
  const runtime = new DurableHarness(
    join(makeTempDir("oppi-durable-boot-"), "data"),
    BUILT_IN_PLUGINS_DIR,
  );
  try {
    await runtime.ensureShared();
  } finally {
    await runtime.closeAll();
  }
}
