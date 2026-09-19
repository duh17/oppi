import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 600_000,
    hookTimeout: 300_000,
    include: ["proxy-review/**/*.e2e.test.ts"],
    exclude: ["dist/**", "node_modules/**"],
    fileParallelism: false,
    maxWorkers: 1,
    minWorkers: 1,
    sequence: { concurrent: false },
  },
  resolve: {
    alias: [{ find: /^(\..+)\.js$/, replacement: "$1.ts" }],
  },
});
