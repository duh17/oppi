import { fileURLToPath } from "node:url";

export default {
  resolve: {
    alias: {
      "@earendil-works/pi-coding-agent": fileURLToPath(
        new URL(
          "../../server/node_modules/@earendil-works/pi-coding-agent/dist/index.js",
          import.meta.url,
        ),
      ),
    },
  },
  test: {
    include: ["extensions/**/*.test.ts"],
  },
};
