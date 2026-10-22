import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  findHomePathViolations,
  isExemptPath,
  NEUTRAL_HOME_NAMES,
  scanTrackedFiles,
} from "../scripts/check-home-paths.ts";

const repoRoot = resolve(__dirname, "../..");

describe("findHomePathViolations", () => {
  it("flags a real home directory with its line number", () => {
    const content = ['const dataDir = "/Users/chenda/.config/oppi";', "const ok = true;"].join(
      "\n",
    );
    expect(findHomePathViolations("server/src/config.ts", content)).toEqual([
      { file: "server/src/config.ts", line: 1, text: "/Users/chenda" },
    ]);
  });

  it("flags a bare home path and an embedded one on every line", () => {
    const content = ['"exact": "/Users/chenda"', "'-d', '/Users/duh/.pi'"].join("\n");
    expect(findHomePathViolations("server/src/config.ts", content).map((v) => v.line)).toEqual([
      1, 2,
    ]);
  });

  it("allows neutral example names", () => {
    for (const name of NEUTRAL_HOME_NAMES) {
      expect(findHomePathViolations("server/src/config.ts", `/Users/${name}/x`)).toEqual([]);
    }
  });

  it("ignores placeholders that are not account names", () => {
    const content = ['if (path.hasPrefix("/Users/")) {', "/// `/Users/.../Foo.swift`"].join("\n");
    expect(findHomePathViolations("server/src/config.ts", content)).toEqual([]);
  });
});

describe("isExemptPath", () => {
  it("exempts tests, fixtures, bench harnesses, reports, and docs", () => {
    for (const file of [
      "server/tests/session-events.test.ts",
      "server/e2e/paired-session.ts",
      "pi-extensions/background-jobs/jobs.test.ts",
      "clients/apple/OppiTests/Models/PendingFileReferenceTests.swift",
      "clients/apple/OppiMacTests/MacLocalHTTPTests.swift",
      "clients/apple/scripts/sim-pool-ops.test.ts",
      "server/bench/server-hotpath.bench.ts",
      "docs/document-viewers.md",
      "dev/architecture-client.md",
      "server/docs/config-schema.md",
      ".internal/reports/audit.md",
      "AGENTS.md",
    ]) {
      expect(isExemptPath(file), file).toBe(true);
    }
  });

  it("does not exempt source, configuration, or scripts", () => {
    for (const file of [
      "server/src/config.ts",
      "server/scripts/check-home-paths.ts",
      "clients/apple/Oppi/Core/Extensions/String+Path.swift",
      "clients/apple/scripts/ci-simulator.sh",
      "install.sh",
      "server/docker-compose.yml",
      "protocol/types.ts",
    ]) {
      expect(isExemptPath(file), file).toBe(false);
    }
  });
});

describe("scanTrackedFiles", () => {
  it("passes on this repository", () => {
    expect(scanTrackedFiles(repoRoot)).toEqual([]);
  });
});
