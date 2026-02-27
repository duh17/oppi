import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 10_000,
    exclude: ["dist/**", "node_modules/**"],
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      reporter: ["text", "json-summary"],
      reportsDirectory: "coverage",
    },
  },
  resolve: {
    alias: [
      // Resolve .js imports to .ts sources (NodeNext moduleResolution)
      { find: /^(\..+)\.js$/, replacement: "$1.ts" },
    ],
  },
});
