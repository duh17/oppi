import { describe, expect, test } from "bun:test";
import { failedTestIds, partition, readFailures, recordWeights, scanTestTypes, shardFlags, splitQuarantine, type TestType } from "./unit-shards";

const source = `import Testing

@Suite("Mic button orb layout")
@MainActor
struct MicButtonOrbLayoutTests {
    @Test func idle() {}
    @Test(arguments: [1, 2]) func sizes(_ n: Int) {}
    struct Nested {
        @Test func inner() {}
    }
}

private struct Helper {}

extension MicButtonOrbLayoutTests {
    @Test func more() {}
}

final class CacheTests {
    @Test func evicts() {}
}

@Test func topLevel() {}
`;

describe("unit shards", () => {
  test("scan finds top-level test types with their suite names and folds in extensions and nested suites", () => {
    expect(scanTestTypes([{ path: "A.swift", text: source }, { path: "B.swift", text: "struct NoTests {}\n" }])).toEqual([
      { name: "CacheTests", display: "CacheTests", tests: 1 },
      { name: "MicButtonOrbLayoutTests", display: "Mic button orb layout", tests: 4 },
    ]);
  });

  test("shards balance recorded seconds, and the last shard runs everything the others do not", () => {
    const types: TestType[] = ["A", "B", "C", "D", "E"].map((name) => ({ name, display: name, tests: 1 }));
    const parts = partition(types, { A: 100, B: 60, C: 50, D: 40 }, 3);
    expect(parts.map((part) => part.map((type) => type.name))).toEqual([["A"], ["B", "E"], ["C", "D"]]);
    expect(shardFlags(parts, 0)).toEqual(["-only-testing:OppiTests/A"]);
    expect(shardFlags(parts, 2)).toEqual([
      "-only-testing:OppiTests",
      "-skip-testing:OppiTests/A",
      "-skip-testing:OppiTests/B",
      "-skip-testing:OppiTests/E",
    ]);
  });

  test("quarantine entries block once their decision date has passed", () => {
    const entry = (id: string, expires: string) => ({ id, owner: "o", reason: "r", addedAt: "2026-10-01", expires });
    const { active, expired } = splitQuarantine([entry("A", "2026-10-22"), entry("B", "2026-10-21")], "2026-10-22");
    expect(active.map((e) => e.id)).toEqual(["A"]);
    expect(expired.map((e) => e.id)).toEqual(["B"]);
  });

  test("failed tests come from the xcresult tree, nested suites included", () => {
    const tree = JSON.stringify({
      testNodes: [{
        nodeType: "Test Plan", children: [{
          nodeType: "Unit test bundle", children: [
            { nodeType: "Test Suite", children: [
              { nodeType: "Test Case", result: "Failed", nodeIdentifier: "SSHTerminalTests/aPasswordPrompt()" },
              { nodeType: "Test Case", result: "Passed", nodeIdentifier: "SSHTerminalTests/ok()" },
              { nodeType: "Test Suite", children: [{ nodeType: "Test Case", result: "Failed", nodeIdentifier: "Outer/Inner/x()" }] },
            ] },
          ],
        }],
      }],
    });
    expect(failedTestIds(tree)).toEqual(["SSHTerminalTests/aPasswordPrompt()", "Outer/Inner/x()"]);
    expect(failedTestIds("Error: bundle is incomplete")).toBeUndefined();
  });

  test("reads the failures of a full shard's tests JSON, which is several MiB", () => {
    // ~0.7 KB per test, 4,300 tests: more than Bun's default 1 MiB spawn buffer.
    const printTree = `
      const cases = Array.from({ length: 4300 }, (_, i) => ({
        nodeType: "Test Case", result: i === 4000 ? "Failed" : "Passed", nodeIdentifier: "Suite/test" + i + "()",
        name: "test" + i + "()", details: "x".repeat(600),
      }));
      process.stdout.write(JSON.stringify({ testNodes: [{ nodeType: "Test Suite", children: cases }] }));`;
    const failures = readFailures(process.execPath, ["-e", printTree]);
    expect(failures).toEqual({ ids: ["Suite/test4000()"] });
  });

  test("an unreadable xcresulttool result is a reason that names what went wrong", () => {
    const failed = readFailures(process.execPath, ["-e", "console.error('bad bundle'); process.exit(3)"]);
    expect(failed).not.toHaveProperty("ids");
    expect(failed).toHaveProperty("reason");
    const reason = (failed as { reason: string }).reason;
    expect(reason).toContain("3");
    expect(reason).toContain("bad bundle");
    const garbled = readFailures(process.execPath, ["-e", "process.stdout.write('Error: incomplete')"]);
    expect(garbled).not.toHaveProperty("ids");
    expect(garbled).toHaveProperty("reason");
  });

  test("recorded seconds map suite display names to types and skip ambiguous names", () => {
    const types: TestType[] = [
      { name: "MicTests", display: "Mic button orb layout", tests: 3 },
      { name: "CurveA", display: "Curve", tests: 1 },
      { name: "CurveB", display: "Curve", tests: 1 },
    ];
    const log = [
      `✔ Suite "Mic button orb layout" passed after 0.089 seconds.`,
      `✘ Suite "Curve" failed after 3.000 seconds with 1 issue.`,
      `✔ Suite "Inner nested" passed after 9.000 seconds.`,
    ].join("\n");
    expect(recordWeights(log, types)).toEqual({ MicTests: 0.09 });
  });
});
