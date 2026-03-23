import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 300_000,
    hookTimeout: 180_000,
    include: ["e2e/**/*.e2e.test.ts"],
    exclude: ["dist/**", "node_modules/**"],
    globalSetup: "e2e/setup.ts",
    // E2E tests are sequential — they share a server instance
    sequence: {
      concurrent: false,
    },
  },
  resolve: {
    alias: [
      { find: /^(\..+)\.js$/, replacement: "$1.ts" },
    ],
  },
});
