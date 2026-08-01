import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 10_000,
    // CLI tests launch child processes; cap file workers so host-core fan-out does
    // not starve nested subprocesses or the concurrent Apple pre-push lane.
    maxWorkers: 4,
    // Build the CLI once in an invocation-local directory so parallel test files or
    // external release builds cannot mutate the executable and docs under test.
    globalSetup: ["./vitest.global-setup.ts"],
    // Point OPPI_LOCAL_SESSIONS_ROOT at a temp tree before any test file imports
    // local-sessions discovery (avoids scanning the developer home Pi sessions root).
    setupFiles: ["./vitest.setup.ts"],
    exclude: ["dist/**", "node_modules/**", "e2e/**"],
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
      // Resolve .js imports to .ts sources (NodeNext moduleResolution)
      { find: /^(\..+)\.js$/, replacement: "$1.ts" },
    ],
  },
});
