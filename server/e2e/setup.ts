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
    console.warn("[e2e] Skipping E2E suite — MLX server not available on :9847");
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
