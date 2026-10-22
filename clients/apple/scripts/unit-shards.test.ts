import { describe, expect, test } from "bun:test";
import { partition, recordWeights, scanTestTypes, shardFlags, type TestType } from "./unit-shards";

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
