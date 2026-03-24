import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  buildChecks,
  didWebSocketContractChange,
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

  it("passes protocol lockstep for non-wire server/src/types.ts-only edits", () => {
    const checks = buildChecks(
      ["server/src/types.ts"],
      [],
      "",
      { serverTypesWireContractChanged: false },
    );

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("pass");
    expect(protocolCheck?.reason).toContain("wire contract shapes");
  });

  it("fails protocol lockstep for wire contract changes without iOS lockstep files", () => {
    const checks = buildChecks(
      ["server/src/types.ts"],
      [],
      "",
      { serverTypesWireContractChanged: true },
    );

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("fail");
    expect(protocolCheck?.details).toEqual({
      touched: ["server/src/types.ts"],
      missing: [
        "clients/apple/Oppi/Core/Models/ServerMessage.swift",
        "clients/apple/Oppi/Core/Models/ClientMessage.swift",
      ],
    });
  });

  it("detects websocket contract changes only when ClientMessage/ServerMessage shapes differ", () => {
    const previous = [
      'export type ChatMetricName = "chat.ttft_ms";',
      "",
      "export type ClientMessage =",
      '  | { type: "prompt"; message: string }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// Server → Client",
      "export type ServerMessage =",
      '  | { type: "connected"; session: Session }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// ─── Push ───",
      "export interface RegisterDeviceTokenRequest {",
      "  deviceToken: string;",
      "}",
    ].join("\n");

    const nonWireChange = [
      'export type ChatMetricName = "chat.ttft_ms" | "chat.cache_load_ms";',
      "",
      "export type ClientMessage =",
      '  | { type: "prompt"; message: string }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// Server → Client",
      "export type ServerMessage =",
      '  | { type: "connected"; session: Session }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// ─── Push ───",
      "export interface RegisterDeviceTokenRequest {",
      "  deviceToken: string;",
      "}",
    ].join("\n");

    const wireChange = [
      'export type ChatMetricName = "chat.ttft_ms";',
      "",
      "export type ClientMessage =",
      '  | { type: "prompt"; message: string }',
      '  | { type: "abort" }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// Server → Client",
      "export type ServerMessage =",
      '  | { type: "connected"; session: Session }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "// ─── Push ───",
      "export interface RegisterDeviceTokenRequest {",
      "  deviceToken: string;",
      "}",
    ].join("\n");

    expect(didWebSocketContractChange(previous, nonWireChange)).toBe(false);
    expect(didWebSocketContractChange(previous, wireChange)).toBe(true);
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
