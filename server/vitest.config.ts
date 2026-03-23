import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 10_000,
    exclude: ["dist/**", "node_modules/**", "e2e/**"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
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
