import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 600_000,
    hookTimeout: 300_000,
    include: ["e2e/**/*.e2e.test.ts"],
    exclude: ["dist/**", "node_modules/**"],
    globalSetup: "e2e/setup.ts",
    // E2E tests share one server process — run in a single worker.
    fileParallelism: false,
    maxWorkers: 1,
    minWorkers: 1,
    sequence: {
      concurrent: false,
    },
  },
  resolve: {
    alias: [{ find: /^(\..+)\.js$/, replacement: "$1.ts" }],
  },
});
