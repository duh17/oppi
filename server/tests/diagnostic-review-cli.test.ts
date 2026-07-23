import { spawnSync } from "node:child_process";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

const scripts = ["client-log-review.ts", "metrickit-review.ts", "server-log-review.ts"];

describe("diagnostic review CLI validation", () => {
  for (const script of scripts) {
    it(`${script} rejects malformed numeric values and unknown flags`, () => {
      const path = join(process.cwd(), "scripts", script);
      const malformed = spawnSync("bun", [path, "--hours", "2hours", "--json"], {
        encoding: "utf8",
      });
      const unknown = spawnSync("bun", [path, "--bogus"], { encoding: "utf8" });
      const leadingHyphenPattern = spawnSync(
        "bun",
        [path, "--hours", "1", "--match", "-1009|timeout", "--json"],
        { encoding: "utf8" },
      );
      const missingPattern = spawnSync("bun", [path, "--match", "--json"], {
        encoding: "utf8",
      });
      const doubleHyphenPattern = spawnSync(
        "bun",
        [path, "--hours", "1", "--match=--offline|timeout", "--json"],
        { encoding: "utf8" },
      );

      expect(malformed.status).not.toBe(0);
      expect(`${malformed.stdout}${malformed.stderr}`).toContain("requires a positive number");
      expect(unknown.status).not.toBe(0);
      expect(`${unknown.stdout}${unknown.stderr}`).toContain("Unknown argument");
      expect(leadingHyphenPattern.status).toBe(0);
      expect(missingPattern.status).not.toBe(0);
      expect(`${missingPattern.stdout}${missingPattern.stderr}`).toContain("--match requires a value");
      expect(doubleHyphenPattern.status).toBe(0);
    });
  }
});
