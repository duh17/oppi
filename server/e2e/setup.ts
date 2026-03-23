/**
 * Global setup for E2E tests — starts the server once before all suites,
 * stops it after all suites complete.
 *
 * Uses vitest's `provide` to pass state to test workers.
 */

import type { GlobalSetupContext } from "vitest/node";
import { startServer, stopServer, ensureLMStudioReady } from "./harness.js";

let lmsReady = false;

export default async function setup({ provide }: GlobalSetupContext): Promise<() => Promise<void>> {
  lmsReady = await ensureLMStudioReady();
  if (!lmsReady) {
    console.warn("[e2e] Skipping E2E suite — LM Studio not available");
    provide("e2eLmsReady", false);
    return async () => {};
  }

  provide("e2eLmsReady", true);
  await startServer();

  return async () => {
    await stopServer();
  };
}
