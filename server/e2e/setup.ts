/**
 * Global setup for E2E tests — starts the server once before all suites,
 * stops it after all suites complete.
 *
 * Uses vitest's `provide` to pass state to test workers.
 */

import type { GlobalSetupContext } from "vitest/node";
import { startServer, stopServer, ensureMLXServerReady, E2E_MODEL } from "./harness.js";

let mlxReady = false;

export default async function setup({ provide }: GlobalSetupContext): Promise<() => Promise<void>> {
  mlxReady = await ensureMLXServerReady();
  if (!mlxReady) {
    const message = "[e2e] OMLX server not available on :8400";
    if (process.env.E2E_STRICT === "1") {
      throw new Error(`${message}; refusing to skip because E2E_STRICT=1`);
    }

    console.warn(`${message}; skipping E2E suite`);
    provide("e2eLmsReady", false);
    provide("e2eModel", "");
    return async () => {};
  }

  provide("e2eLmsReady", true);
  provide("e2eModel", E2E_MODEL);
  await startServer();

  return async () => {
    await stopServer();
  };
}
