#!/usr/bin/env node
/**
 * Small CLI wrapper around the shared E2E harness for non-Vitest callers.
 * Apple E2E scripts use this so server-only tests, packaged native validation,
 * and iOS bootstrap share model probing, server lifecycle, pairing, and invite
 * generation semantics.
 */

import { existsSync, rmSync, writeFileSync } from "node:fs";
import {
  E2E_MODEL,
  bootstrapAppleE2E,
  ensureMLXServerReady,
  startServer,
  stopServer,
} from "./harness.ts";

interface BootstrapState {
  mode: "apple";
  pid: number;
}

const command = process.argv[2];
const stateFile = process.env.E2E_HARNESS_STATE_FILE || "/tmp/oppi-e2e-harness-state.json";

async function main(): Promise<void> {
  switch (command) {
    case "apple-bootstrap":
      await appleBootstrap();
      return;
    case "apple-teardown":
      await appleTeardown();
      return;
    default:
      throw new Error(`Unknown command: ${command ?? "<missing>"}`);
  }
}

async function appleBootstrap(): Promise<void> {
  process.env.E2E_NATIVE ??= "1";
  process.env.E2E_TLS_MODE ??= "disabled";
  process.env.OPPI_E2E_UI_HARNESS ??= "1";

  const ready = await ensureMLXServerReady();
  if (!ready) {
    throw new Error("Local model server is not ready");
  }

  await startServer();
  const bootstrap = await bootstrapAppleE2E({ model: E2E_MODEL });
  writeFileSync(
    stateFile,
    JSON.stringify({ mode: "apple", pid: process.pid } satisfies BootstrapState),
  );

  console.log(
    JSON.stringify(
      {
        ...bootstrap,
        model: E2E_MODEL,
        stateFile,
      },
      null,
      2,
    ),
  );

  await new Promise<void>((resolve) => {
    process.once("SIGTERM", resolve);
    process.once("SIGINT", resolve);
  });
  await stopServer();
  rmSync(stateFile, { force: true });
}

async function appleTeardown(): Promise<void> {
  if (!existsSync(stateFile)) return;
  const state = JSON.parse(await readText(stateFile)) as BootstrapState;
  if (state.pid && state.pid !== process.pid) {
    try {
      process.kill(state.pid, "SIGTERM");
    } catch {
      // Already stopped.
    }
  }
}

async function readText(path: string): Promise<string> {
  const { readFile } = await import("node:fs/promises");
  return readFile(path, "utf-8");
}

main().catch((err: unknown) => {
  const message = err instanceof Error ? err.message : String(err);
  console.error(`[e2e-harness] ${message}`);
  process.exit(1);
});
