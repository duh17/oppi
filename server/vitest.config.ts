import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 10_000,
    exclude: ["dist/**", "node_modules/**", "e2e/**"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: [
        "src/cli.ts", // CLI entry point — not unit-testable
        "src/server-metric-registry.ts", // const registry + types — no logic to test
        "src/routes/types.ts", // type-only exports — no runtime code
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
