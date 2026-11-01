import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SUBPROCESS_TEST_TIMEOUT_MS } from "./sim-pool-test-support";
import { executedTests, infrastructureFailure } from "./unit-shards";
import { missingTests, normalizeFilters, planShards, profileSlots, pruneStale, recordUIWeights, scanUIClasses, shardCap, shardFlags, testsOf, unplannedTests } from "./ui-shards";

setDefaultTimeout(SUBPROCESS_TEST_TIMEOUT_MS);

const swift = `import XCTest

class UIHarnessTestCase: XCTestCase {
    func testInherited() {}
    func helper() {}
}

final class ChatUITests: UIHarnessTestCase {
    let text = "a { brace in a string"
    // func testCommented() {}
    func testOne() throws { if true { _ = 1 } }
    func testTwo() async throws {}
    func testWithArgument(_ n: Int) {}
    private func testPrivate() {}
    static func testStatic() {}
    @MainActor func testMainActor() {}
    class Inner { func testNested() {} }
}

extension ChatUITests {
    func testFromExtension() {}
}

final class BrokenUITests: XCTestCase {
    func testOne() {
`;

const classes = scanUIClasses([swift]);

describe("ui test scan", () => {
  test("lists the methods XCTest runs: own, extension, and inherited; not private, static, parameterized, nested, or commented", () => {
    expect(testsOf("ChatUITests", classes)).toEqual(["testFromExtension", "testInherited", "testMainActor", "testOne", "testTwo"]);
  });

  test("a class whose body the scan cannot close is never listed, so it is never split", () => {
    expect(testsOf("BrokenUITests", classes)).toBeUndefined();
    expect(testsOf("NoSuchUITests", classes)).toBeUndefined();
  });

  test("a class that inherits from a type the scan did not read is never listed: its tests would be invisible", () => {
    const other = scanUIClasses([
      "final class OwnerUITests: SharedBaseTestCase { func testOwn() {} }\n",
      "final class LoneUITests { func testLone() {} }\n",
      "class HelperBase: XCTestCase { func testFromBase() {} }\nfinal class ViaHelperUITests: HelperBase { func testOwn() {} }\n",
    ]);
    expect(testsOf("OwnerUITests", other)).toBeUndefined();
    expect(testsOf("LoneUITests", other)).toBeUndefined();
    expect(testsOf("ViaHelperUITests", other)).toEqual(["testFromBase", "testOwn"]);
  });
});

// AUITests has two tests, the others one each.
const small = scanUIClasses([
  "final class AUITests: XCTestCase { func testA() {} func testB() {} }\n",
  ...["B", "C", "D"].map((name) => `final class ${name}UITests: XCTestCase { func testA() {} }\n`),
]);
const smallWeights = { "AUITests/testA": 100, "AUITests/testB": 100, "BUITests/testA": 60, "CUITests/testA": 50, "DUITests/testA": 40 };
const names = (plan: ReturnType<typeof planShards>) => plan.map((shard) => shard.units.map((unit) => unit.label));

describe("ui shard plan", () => {
  test("shards balance recorded seconds, longest unit first, and every named test appears in exactly one shard", () => {
    const plan = planShards(
      ["OppiUITests/AUITests", "OppiUITests/BUITests", "OppiUITests/CUITests", "OppiUITests/DUITests"],
      small,
      smallWeights,
      3,
      3,
    );
    // AUITests (200s) is over half of a shard's share (350/3), so it runs as two tests.
    expect(names(plan)).toEqual([["AUITests/testA", "DUITests"], ["AUITests"], ["BUITests", "CUITests"]]);
    expect(plan.map((shard) => shard.seconds)).toEqual([140, 100, 110]);
    // The lightest shard that runs a method of the split class takes the catch-all: the class minus
    // the methods other shards run, so a test the scan missed still runs, once.
    expect(plan.map(shardFlags)).toEqual([
      ["-only-testing:OppiUITests/AUITests/testA", "-only-testing:OppiUITests/DUITests"],
      ["-only-testing:OppiUITests/AUITests", "-skip-testing:OppiUITests/AUITests/testA"],
      ["-only-testing:OppiUITests/BUITests", "-only-testing:OppiUITests/CUITests"],
    ]);
    expect(plan.flatMap((shard) => shard.ids).sort()).toEqual(["AUITests/testA", "AUITests/testB", "BUITests/testA", "CUITests/testA", "DUITests/testA"]);
    expect(plan.reduce((sum, shard) => sum + shard.tests!, 0)).toBe(5);
  });

  test("a selection too short to pay for a second shard stays on one", () => {
    // 60 + 50 seconds of tests: a second shard would cost about as much to start as it saves.
    const plan = planShards(["OppiUITests/BUITests", "OppiUITests/CUITests"], small, smallWeights, 3);
    expect(names(plan)).toEqual([["BUITests", "CUITests"]]);
  });

  test("unrecorded tests weigh the median of the recorded ones, so an unrecorded selection balances by count", () => {
    const plan = planShards(["OppiUITests/AUITests", "OppiUITests/BUITests", "OppiUITests/CUITests", "OppiUITests/DUITests"], small, {}, 2, 2);
    expect(plan.map((shard) => shard.tests)).toEqual([3, 2]);
    expect(plan.map((shard) => shard.seconds)).toEqual([90, 60]);
  });

  test("the shard count never passes the cap or the number of units", () => {
    const filters = ["OppiUITests/BUITests", "OppiUITests/CUITests", "OppiUITests/DUITests"];
    expect(planShards(filters, small, { "BUITests/testA": 500, "CUITests/testA": 500, "DUITests/testA": 500 }, 2)).toHaveLength(2);
    expect(planShards(["OppiUITests/BUITests"], small, { "BUITests/testA": 5000 }, 6)).toHaveLength(1);
    // One class is as many units as it has tests: a single heavy class still spreads over the cap.
    expect(names(planShards(["OppiUITests/AUITests"], small, { "AUITests/testA": 200, "AUITests/testB": 200 }, 3))).toEqual([["AUITests"], ["AUITests/testB"]]);
    expect(planShards(filters, small, {}, 6, 6)).toHaveLength(3);
  });

  test("a filter the scan cannot list runs as named, weighed by its recorded tests, and the plan cannot count its tests", () => {
    const plan = planShards(["OppiUITests/GhostUITests", "OppiUITests/BUITests/testA"], small, { "GhostUITests/testX": 70, "GhostUITests/testY": 30 }, 2, 2);
    const ghost = plan.flatMap((shard) => shard.units).find((unit) => unit.label === "GhostUITests")!;
    expect(ghost).toMatchObject({ flags: ["-only-testing:OppiUITests/GhostUITests"], seconds: 100, tests: undefined });
    expect(plan.some((shard) => shard.tests === undefined)).toBe(true);
    expect(ghost.ids).toEqual([]);
  });

  test("a named test is not run twice when its class is also named", () => {
    expect(normalizeFilters(["OppiUITests/A/testX", "OppiUITests/A", "OppiUITests/B/testY", "OppiUITests/B/testY"])).toEqual(["OppiUITests/A", "OppiUITests/B/testY"]);
  });

  test("Class/test and Class/test() are one test", () => {
    expect(normalizeFilters(["OppiUITests/A/testX()", "OppiUITests/A/testX", "OppiUITests/B/testY()"])).toEqual(["OppiUITests/A/testX", "OppiUITests/B/testY"]);
  });

  test("a planned test that did not run is named even when an unlisted one ran in its place", () => {
    const plans = planShards(["OppiUITests/AUITests"], small, { "AUITests/testA": 200, "AUITests/testB": 200 }, 3);
    const keeper = plans.findIndex((plan) => plan.units.some((unit) => unit.catchAll));
    const [other] = plans.filter((_, index) => index !== keeper);
    // Same count as planned, wrong test: a count check would pass this.
    expect(missingTests(plans[keeper], new Set(["AUITests/testHidden"]))).toEqual(plans[keeper].ids);
    expect(missingTests(other, new Set(other.ids))).toEqual([]);
  });

  test("a test the scan missed runs in the split class's catch-all shard and is reported as unlisted", () => {
    // The catch-all runs the class minus what other shards run, so a hidden method lands there.
    const plans = planShards(["OppiUITests/AUITests"], small, { "AUITests/testA": 200, "AUITests/testB": 200 }, 3);
    const keeper = plans.findIndex((plan) => plan.units.some((unit) => unit.catchAll));
    const flags = shardFlags(plans[keeper]);
    expect(flags[0]).toBe("-only-testing:OppiUITests/AUITests");
    expect(flags.slice(1).every((flag) => flag.startsWith("-skip-testing:OppiUITests/AUITests/test"))).toBe(true);
    const ran = new Set([...plans[keeper].ids, "AUITests/testHidden"]);
    expect(unplannedTests(plans, keeper, ran)).toEqual(["AUITests/testHidden"]);
    expect(unplannedTests(plans, keeper, new Set(plans[keeper].ids))).toEqual([]);
  });

  test("a class that is not split gets no catch-all", () => {
    const plans = planShards(["OppiUITests/BUITests", "OppiUITests/CUITests"], small, smallWeights, 3, 2);
    expect(plans.flatMap((plan) => plan.units).some((unit) => unit.catchAll || unit.flags.some((flag) => flag.startsWith("-skip-testing")))).toBe(false);
  });

  test("recorded tests the sources no longer declare are pruned; an unlistable class keeps its record", () => {
    const pruned = pruneStale({ "AUITests/testA": 1, "AUITests/testGone": 2, "GoneUITests/testA": 3, "OwnerUITests/testOwn": 4 }, scanUIClasses([
      "final class AUITests: XCTestCase { func testA() {} }\n",
      "final class OwnerUITests: SharedBaseTestCase { func testOwn() {} }\n",
    ]));
    expect(pruned).toEqual({ "AUITests/testA": 1, "OwnerUITests/testOwn": 4 });
  });

  test("the cap follows the profile's slots; OPPI_UI_SHARDS may lower or raise it up to them", () => {
    expect(shardCap("iphone", { OPPI_UI_SHARDS: "1" })).toBe(1);
    expect(shardCap("iphone", { OPPI_UI_SHARDS: "50" })).toBe(6);
    expect(shardCap("ipad", { OPPI_UI_SHARDS: "50" })).toBe(4);
    expect(() => shardCap("iphone", { OPPI_UI_SHARDS: "0" })).toThrow("invalid OPPI_UI_SHARDS");
    expect(() => shardCap("watch", {})).toThrow("unknown --profile");
    // --shards N is bounded only by the slots.
    expect([profileSlots("iphone"), profileSlots("ipad"), profileSlots("duo")]).toEqual([6, 4, 1]);
  });
});

describe("ui shard timings and results", () => {
  test("recorded seconds are the median of passed executions per test; failed runs do not count", () => {
    const log = (seconds: number, result = "passed") => `Test Case '-[OppiUITests.ChatUITests testOne]' started.\nTest Case '-[OppiUITests.ChatUITests testOne]' ${result} (${seconds} seconds).\n`;
    expect(recordUIWeights([log(10), log(40), log(20), log(900, "failed"), "Test Case '-[OppiE2ETests.X testY]' passed (5.0 seconds).\n"])).toEqual({ "ChatUITests/testOne": 20 });
  });

  test("a UI shard that died partway counts the cases it finished, so it is a test failure and not an infrastructure failure", () => {
    const dir = mkdtempSync(join(tmpdir(), "ui-shards-"));
    try {
      const run = (log: string) => {
        writeFileSync(join(dir, "pool.log"), log);
        writeFileSync(join(dir, "summary.json"), JSON.stringify({ log_path: join(dir, "pool.log") }));
        return executedTests(join(dir, "summary.json"));
      };
      const finished = "Test Suite 'Selected tests' failed at 2026-10-30 01:00:00.000.\n\t Executed 5 tests, with 1 failure (1 unexpected) in 90.0 (90.1) seconds\n";
      expect(run(finished)).toBe(5);
      const died = "Test Case '-[OppiUITests.A testX]' passed (3.0 seconds).\nTest Case '-[OppiUITests.A testY]' failed (4.0 seconds).\n";
      expect(run(died)).toBe(2);
      expect(infrastructureFailure({ code: 65, tests: run(died) }, "")).toBeUndefined();
      expect(infrastructureFailure({ code: 70, tests: run("error: all 6 simulator slots are busy\n") }, "error: all 6 simulator slots are busy\n")).toContain("all 6 simulator slots");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
