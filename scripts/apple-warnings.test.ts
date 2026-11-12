import { describe, expect, test } from "bun:test";
import { type Baseline, countWarnings, fileCounts, lowered, newWarnings, parseLog, regressions } from "./apple-warnings";

const root = "/work/tree/clients/apple";
const compiler = (path: string, line: number, message: string) => `${root}/${path}:${line}:5: warning: ${message}`;
const lint = (path: string, line: number) =>
  `${root}/${path}:${line}:1: warning: Force Unwrapping Violation: Force unwrapping should be avoided (force_unwrapping)`;

const log = [
  compiler("Oppi/A.swift", 10, "variable 'x' was never mutated"),
  compiler("Oppi/A.swift", 10, "variable 'x' was never mutated"), // the same diagnostic, printed twice
  compiler("OppiTests/T.swift", 3, "'init(frame:)' was deprecated"),
  lint("OppiTests/T.swift", 4),
  "/var/folders/x/T/swift-generated-sources/@__swiftmacro_9OppiTests0016ThingTestsswift_Fi1_.swift:1:90: warning: result unused",
  "warning: 'NIOCore' is missing a dependency on 'Atomics'",
  "2026-11-11 23:42:29.573 appintentsmetadataprocessor[1:2] warning: Metadata extraction skipped",
  `SwiftCompile normal arm64 ${root}/Oppi/A.swift (in target 'Oppi' from project 'Oppi')`,
  "PhaseScriptExecution SwiftLint /x/y.sh (in target 'Oppi' from project 'Oppi')",
].join("\n");

const empty: Baseline = { counts: {}, files: {} };

describe("warning parsing", () => {
  const parsed = parseLog(log);

  test("counts unique diagnostics per group, with SwiftLint, macro expansions and package scans apart", () => {
    expect(countWarnings(parsed.warnings)).toEqual({
      Oppi: { compiler: 1 },
      OppiTests: { compiler: 2, swiftlint: 1 },
      SwiftPM: { dependency: 1 },
    });
  });

  test("reads which files compiled and whether the SwiftLint phase ran", () => {
    expect([...parsed.compiled]).toEqual(["Oppi/A.swift"]);
    expect(parsed.swiftlintRan).toBe(true);
  });
});

describe("ratchet", () => {
  const parsed = parseLog(log);
  const counts = countWarnings(parsed.warnings);
  const baseline: Baseline = { counts, files: fileCounts(parsed.warnings) };

  test("passes at the baseline and below it", () => {
    expect(regressions(counts, baseline)).toEqual([]);
    expect(regressions({ Oppi: {} }, baseline)).toEqual([]);
  });

  test("fails on a rise in one group and names the file that gained the warning", () => {
    const more = parseLog(`${log}\n${compiler("Oppi/B.swift", 7, "result of call to 'f()' is unused")}`);
    const rise = regressions(countWarnings(more.warnings), baseline);
    expect(rise).toEqual([{ group: "Oppi", kind: "compiler", baseline: 1, now: 2 }]);
    expect(newWarnings(more.warnings, baseline)).toEqual([
      "Oppi/B.swift [compiler]: 1 warnings, baseline 0",
      "    :7 result of call to 'f()' is unused",
    ]);
  });

  test("catches a new warning in a recompiled file while the group total sits under its baseline", () => {
    // A build that reused earlier output reports 1 of the group's 5 baseline warnings, plus a new one.
    const roomy: Baseline = { counts: { Oppi: { compiler: 5 } }, files: { compiler: { "Oppi/A.swift": 1, "Oppi/Old.swift": 4 } } };
    const partial = parseLog(`${compiler("Oppi/A.swift", 10, "variable 'x' was never mutated")}\n${compiler("Oppi/B.swift", 7, "unused")}`);
    expect(regressions(countWarnings(partial.warnings), roomy)).toEqual([]);
    expect(newWarnings(partial.warnings, roomy)).toEqual(["Oppi/B.swift [compiler]: 1 warnings, baseline 0", "    :7 unused"]);
  });

  test("keeps #expect macro expansions in one record per module", () => {
    const expansion = (name: string) => `/tmp/swift-generated-sources/@__swiftmacro_9OppiTests${name}.swift:1:9: warning: unused`;
    const macros = parseLog([expansion("0016AaaTestsswift_Fi1_"), expansion("0016AaaTestsswift_Fi2_")].join("\n"));
    expect(Object.keys(fileCounts(macros.warnings).compiler ?? {})).toEqual(["OppiTests/(macro expansions)"]);
  });

  test("counts a kind the baseline never had as a rise from zero", () => {
    expect(regressions({ Oppi: { swiftlint: 1 } }, baseline)).toEqual([
      { group: "Oppi", kind: "swiftlint", baseline: 0, now: 1 },
    ]);
  });
});

describe("lowering the baseline", () => {
  const parsed = parseLog(log);
  const baseline: Baseline = {
    counts: { Oppi: { compiler: 5 }, OppiTests: { compiler: 9, swiftlint: 4 }, SwiftPM: { dependency: 3 } },
    files: { compiler: { "Oppi/A.swift": 5, "OppiTests/Old.swift": 9 }, swiftlint: { "OppiTests/Old.swift": 4 } },
  };
  // Oppi has one file and the log compiled it; OppiTests has two, and the log compiled neither.
  const sources = (group: string) => (group === "Oppi" ? ["Oppi/A.swift"] : [`${group}/T.swift`, `${group}/U.swift`]);
  const next = lowered(baseline, countWarnings(parsed.warnings), parsed.warnings, parsed, sources);

  test("takes a count from the log only where the log is complete for it", () => {
    expect(next.counts.Oppi).toEqual({ compiler: 1 }); // every source file compiled
    expect(next.counts.OppiTests?.compiler).toBe(9); // a partial build would under-report: kept
    expect(next.counts.OppiTests?.swiftlint).toBe(1); // the SwiftLint phase ran
  });

  test("keeps the per-file record of an incomplete group and rewrites a complete one", () => {
    expect(next.files.compiler).toEqual({ "Oppi/A.swift": 1, "OppiTests/Old.swift": 9 });
    expect(next.files.swiftlint).toEqual({ "OppiTests/T.swift": 1 });
  });

  test("never raises a count", () => {
    const raised = lowered({ counts: { Oppi: { compiler: 0 } }, files: {} }, countWarnings(parsed.warnings), parsed.warnings, parsed, sources);
    expect(raised.counts.Oppi).toBeUndefined();
  });
});
