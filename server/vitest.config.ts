import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const MAX_FILE_WORKERS = 8;

/**
 * File-worker cap. OPPI_VITEST_MAX_WORKERS may only lower it: Vitest treats 0 and NaN as
 * unset (one worker per core), so a typo must fail instead of silently removing the cap.
 */
export function resolveMaxWorkers(raw: string | undefined): number {
  if (raw === undefined) return MAX_FILE_WORKERS;
  const workers = /^\d+$/.test(raw) ? Number(raw) : Number.NaN;
  if (!Number.isInteger(workers) || workers < 1 || workers > MAX_FILE_WORKERS) {
    throw new Error(
      `OPPI_VITEST_MAX_WORKERS must be an integer from 1 to ${MAX_FILE_WORKERS}, got ${JSON.stringify(raw)}`,
    );
  }
  return workers;
}

export default defineConfig({
  test: {
    testTimeout: 10_000,
    // CLI tests launch child processes; cap file workers so host-core fan-out does
    // not starve nested subprocesses or the concurrent Apple pre-push lane.
    // 8 because the CLI suite is split into several files that overlap: at 4 workers the
    // full suite took 192 s (cli.test.ts alone 181 s); the 4-file split at 8 workers took
    // 108 s with 5838/5838 passing. Set OPPI_VITEST_MAX_WORKERS to lower it on a busy host.
    maxWorkers: resolveMaxWorkers(process.env.OPPI_VITEST_MAX_WORKERS),
    // Build the CLI once in an invocation-local directory so parallel test files or
    // external release builds cannot mutate the executable and docs under test.
    globalSetup: ["./vitest.global-setup.ts"],
    // Point OPPI_LOCAL_SESSIONS_ROOT at a temp tree before any test file imports
    // local-sessions discovery (avoids scanning the developer home Pi sessions root).
    setupFiles: ["./vitest.setup.ts"],
    exclude: ["dist/**", "node_modules/**", "e2e/**", "proxy-review/**"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts", "extensions/**/*.ts"],
      exclude: [
        "src/cli.ts", // CLI entry point — not unit-testable
        "src/server-metric-registry.ts", // const registry + types — no logic to test
        "src/routes/types.ts", // type-only exports — no runtime code
        "extensions/**/*.test.ts",
      ],
      reporter: ["text", "json-summary"],
      reportsDirectory: "coverage",
      thresholds: {
        statements: 70,
        branches: 63,
        functions: 77,
        lines: 70,
      },
    },
  },
  resolve: {
    alias: [
      // Tests import durable package entries directly; production loads them only through
      // the extension loader, which aliases `oppi/durable` the same way.
      {
        find: /^oppi\/durable$/,
        replacement: fileURLToPath(new URL("./src/durable-extension-api.ts", import.meta.url)),
      },
      // Resolve .js imports to .ts sources (NodeNext moduleResolution)
      { find: /^(\..+)\.js$/, replacement: "$1.ts" },
    ],
  },
});
