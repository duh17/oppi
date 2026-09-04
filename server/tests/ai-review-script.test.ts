import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import {
  buildChecks,
  didAppleProtocolWireChange,
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

  it("passes protocol lockstep for non-wire server/src/types/protocol.ts-only edits", () => {
    const checks = buildChecks(["server/src/types/protocol.ts"], [], "", {
      serverTypesWireContractChanged: false,
    });

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("pass");
    expect(protocolCheck?.reason).toContain("wire contract shapes");
  });

  it("fails protocol lockstep for server-to-client wire changes without ServerMessage.swift", () => {
    const checks = buildChecks(["server/src/types/protocol.ts"], [], "", {
      serverMessageChanged: true,
      clientMessageChanged: false,
    });

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("fail");
    expect(protocolCheck?.details).toEqual({
      touched: ["server/src/types/protocol.ts"],
      missing: ["clients/apple/OppiCore/Models/ServerMessage.swift"],
    });
  });

  it("fails protocol lockstep for client-to-server wire changes without ClientMessage.swift", () => {
    const checks = buildChecks(["server/src/types/protocol.ts"], [], "", {
      serverMessageChanged: false,
      clientMessageChanged: true,
    });

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("fail");
    expect(protocolCheck?.details).toEqual({
      touched: ["server/src/types/protocol.ts"],
      missing: ["clients/apple/OppiCore/Models/ClientMessage.swift"],
    });
  });

  it("passes protocol lockstep for server-to-client changes with ServerMessage.swift", () => {
    const checks = buildChecks(
      ["server/src/types/protocol.ts", "clients/apple/OppiCore/Models/ServerMessage.swift"],
      [],
      "",
      { serverMessageChanged: true, clientMessageChanged: false },
    );

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("pass");
  });

  it("fails protocol lockstep for Apple protocol model changes without server contract", () => {
    const checks = buildChecks(["clients/apple/OppiCore/Models/ServerMessage.swift"], [], "");

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("fail");
    expect(protocolCheck?.details).toEqual({
      touched: ["clients/apple/OppiCore/Models/ServerMessage.swift"],
      missing: ["server/src/types/protocol.ts"],
    });
  });

  it("passes protocol lockstep for Apple helper-only ClientMessage.swift changes without protocol.ts", () => {
    const checks = buildChecks(["clients/apple/OppiCore/Models/ClientMessage.swift"], [], "", {
      appleWireContractChanged: false,
    });

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("pass");
    expect(protocolCheck?.reason).toContain("wire contract shapes");
  });

  it("fails protocol lockstep for Apple wire-shape changes without protocol.ts", () => {
    const checks = buildChecks(["clients/apple/OppiCore/Models/ClientMessage.swift"], [], "", {
      appleWireContractChanged: true,
    });

    const protocolCheck = checks.find((check) => check.id === "protocol-lockstep");
    expect(protocolCheck?.status).toBe("fail");
    expect(protocolCheck?.details).toEqual({
      touched: ["clients/apple/OppiCore/Models/ClientMessage.swift"],
      missing: ["server/src/types/protocol.ts"],
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
      "export type ServerMessage =",
      '  | { type: "connected"; sessionId: string }',
      "  & {",
      "    sessionId?: string;",
      "  };",
      "",
      "export interface RegisterDeviceTokenRequest {",
      "  deviceToken: string;",
      "}",
    ].join("\n");

    const nonWireChange = previous.replace(
      'export type ChatMetricName = "chat.ttft_ms";',
      'export type ChatMetricName = "chat.ttft_ms" | "chat.cache_load_ms";',
    );

    const wireChange = previous.replace(
      '  | { type: "prompt"; message: string }',
      '  | { type: "prompt"; message: string }\n  | { type: "abort" }',
    );

    expect(didWebSocketContractChange(previous, nonWireChange)).toBe(false);
    expect(didWebSocketContractChange(previous, wireChange)).toBe(true);
  });

  it("detects Apple protocol wire changes only for ClientMessage/ServerMessage Codable shapes", () => {
    const previous = [
      "enum ClientMessage: Sendable {",
      "    case abort(requestId: String? = nil)",
      "}",
      "",
      "enum ThinkingLevel: String, Codable, Sendable {",
      "    case off, medium",
      "",
      "    var displayTitle: String {",
      "        switch self {",
      "        case .off: \"Off\"",
      "        case .medium: \"Medium\"",
      "        }",
      "    }",
      "}",
      "",
      "extension ClientMessage: Encodable {",
      "    func encode(to encoder: Encoder) throws {",
      "        var c = encoder.container(keyedBy: CodingKeys.self)",
      "        switch self {",
      "        case .abort(let reqId):",
      "            try c.encode(\"abort\", forKey: .type)",
      "            try c.encodeIfPresent(reqId, forKey: .requestId)",
      "        }",
      "    }",
      "",
      "    enum CodingKeys: String, CodingKey {",
      "        case type, requestId",
      "    }",
      "}",
    ].join("\n");

    const helperOnly = previous.replace(
      "    var displayTitle: String {",
      [
        "    /// Parse a session-stored thinking-level string.",
        "    init(sessionValue: String?) {",
        "        self = .medium",
        "    }",
        "",
        "    var displayTitle: String {",
      ].join("\n"),
    );

    const clientCaseChange = previous.replace(
      "    case abort(requestId: String? = nil)",
      "    case abort(requestId: String? = nil)\n    case ping",
    );

    const thinkingLevelChange = previous.replace("    case off, medium", "    case off, medium, high");

    const encodeChange = previous.replace(
      'try c.encode("abort", forKey: .type)',
      'try c.encode("abort_all", forKey: .type)',
    );

    expect(didAppleProtocolWireChange(previous, helperOnly)).toBe(false);
    expect(didAppleProtocolWireChange(previous, clientCaseChange)).toBe(true);
    expect(didAppleProtocolWireChange(previous, thinkingLevelChange)).toBe(true);
    expect(didAppleProtocolWireChange(previous, encodeChange)).toBe(true);
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
