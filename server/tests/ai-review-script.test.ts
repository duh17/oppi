import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  buildChecks,
  extractFileDiff,
  isPackageJsonCiTestingChange,
  readImportsFromFile,
} from "../scripts/ai-review.mjs";

describe("ai-review script", () => {
  it("does not flag package.json as CI/testing infra for unrelated changes", () => {
    const packageJsonDiff = [
      "diff --git a/server/package.json b/server/package.json",
      "index 1111111..2222222 100644",
      "--- a/server/package.json",
      "+++ b/server/package.json",
      "@@ -1,5 +1,5 @@",
      '-  "version": "0.1.0",',
      '+  "version": "0.1.1",',
    ].join("\n");

    const extracted = extractFileDiff(packageJsonDiff, "server/package.json");
    expect(isPackageJsonCiTestingChange(extracted)).toBe(false);

    const checks = buildChecks(["server/package.json"], [], packageJsonDiff);
    const ciCheck = checks.find((check) => check.id === "ci-testing-infra-review");
    expect(ciCheck?.status).toBe("pass");
  });

  it("flags package.json as CI/testing infra when review/test/check scripts change", () => {
    const packageJsonDiff = [
      "diff --git a/server/package.json b/server/package.json",
      "index 1111111..2222222 100644",
      "--- a/server/package.json",
      "+++ b/server/package.json",
      "@@ -60,6 +60,7 @@",
      '+    "review": "node ./scripts/ai-review.mjs --staged",',
    ].join("\n");

    const extracted = extractFileDiff(packageJsonDiff, "server/package.json");
    expect(isPackageJsonCiTestingChange(extracted)).toBe(true);

    const checks = buildChecks(["server/package.json"], [], packageJsonDiff);
    const ciCheck = checks.find((check) => check.id === "ci-testing-infra-review");
    expect(ciCheck?.status).toBe("warn");
    expect(ciCheck?.details).toEqual({ files: ["server/package.json"] });
  });

  it("parses imports with AST and ignores comment/string lookalikes", () => {
    const dir = mkdtempSync(join(tmpdir(), "oppi-ai-review-"));

    try {
      const filePath = join(dir, "imports.ts");
      writeFileSync(
        filePath,
        [
          '// import fake from "./commented";',
          "const text = \"import nope from './string-literal'\";",
          'import real from "./real";',
          'export * from "./exported";',
          '/* export { ghost } from "./commented-export"; */',
        ].join("\n"),
      );

      const imports = readImportsFromFile(filePath);
      expect(imports).toEqual(["./real", "./exported"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
