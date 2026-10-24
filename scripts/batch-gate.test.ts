import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { declarations, executedTests, planGate } from "./batch-gate";

const sources: Record<string, string[]> = {
  OppiTests: [
    "struct FooTests { @Test func a() {} }\n",
    "struct BarTests { @Test func baz() {} }\n",
    // A comment is not a declaration: APIClient is only mocked here; the suite is APIClientTests.
    "// mock the actor APIClient\n// struct GhostTests {}\n/* and the class Legacy */\nstruct APIClientTests { @Test func a() {} }\nlet url = \"https://x.test\"; struct AfterUrlTests { @Test func b() {} }\n",
    "struct Alice { func helper() {} }\n",
  ],
  // SharedSupportTests stands in for QAVerificationSupport, which both UI and E2E targets compile.
  OppiUITests: ["final class ChatRoutesUITests: XCTestCase { func testOpen() {} }\n", "struct SharedSupportTests {}\n"],
  OppiE2ETests: ["final class ChatE2ETests: E2ETestCase {}\n", "extension ChatE2ETests { func testSend() {} }\n", "struct SharedSupportTests {}\n"],
};
const types = (target: string) => declarations(sources[target] ?? []);

describe("batch gate plan", () => {
  test("named suites become one lane per kind, UI tests one lane per profile", () => {
    const plan = planGate("/wt", [
      "OppiTests/FooTests",
      "OppiTests/BarTests/baz()",
      "OppiUITests/ChatRoutesUITests",
      "server/tests/cli-a.test.ts",
      "tests/mcp-service.test.ts",
      "OppiE2ETests/ChatE2ETests/testSend",
      "e2e-group:gate",
    ], ["iphone", "ipad"], types);
    expect(plan.errors).toEqual([]);
    const byName = Object.fromEntries(plan.lanes.map((lane) => [lane.name, lane.steps.map((step) => step.args)]));
    expect(Object.keys(byName)).toEqual(["server", "ios-unit", "ui-iphone", "ui-ipad", "e2e"]);
    expect(byName.server[0].slice(-2)).toEqual(["tests/cli-a.test.ts", "tests/mcp-service.test.ts"]);
    expect(byName["ios-unit"][0].slice(-2)).toEqual(["-only-testing:OppiTests/FooTests", "-only-testing:OppiTests/BarTests/baz()"]);
    expect(byName["ui-ipad"][0].slice(0, 3)).toEqual(["run", "--device-profile", "ipad"]);
    expect(byName.e2e).toEqual([
      ["--native", "--only-testing", "OppiE2ETests/ChatE2ETests/testSend"],
      ["--group", "gate"],
    ]);
  });

  test("a bare suite plans exactly like its prefixed form, on the one target that declares it", () => {
    const bare = planGate("/wt", ["FooTests", "BarTests/baz()", "ChatRoutesUITests", "ChatE2ETests/testSend"], ["iphone", "ipad"], types);
    const prefixed = planGate(
      "/wt",
      ["OppiTests/FooTests", "OppiTests/BarTests/baz()", "OppiUITests/ChatRoutesUITests", "OppiE2ETests/ChatE2ETests/testSend"],
      ["iphone", "ipad"],
      types,
    );
    expect(bare.errors).toEqual([]);
    expect(bare.lanes).toEqual(prefixed.lanes);
    expect(bare.resolutions).toEqual([
      "--test 'FooTests' resolved to OppiTests/FooTests",
      "--test 'BarTests/baz()' resolved to OppiTests/BarTests/baz()",
      "--test 'ChatRoutesUITests' resolved to OppiUITests/ChatRoutesUITests",
      "--test 'ChatE2ETests/testSend' resolved to OppiE2ETests/ChatE2ETests/testSend",
    ]);
    expect(prefixed.resolutions).toEqual([]);
  });

  test("a bare suite no target declares, or two targets declare, or with an undeclared test, is an error", () => {
    const plan = planGate("/wt", ["NoSuchTests", "NoSuchTests/a", "SharedSupportTests", "FooTests/baz()", "server", "OppiTests", "APIClient", "OppiTests/APIClient", "Legacy", "Alice", "GhostTests", "OppiTests/Alice/helper", "AfterUrlTests", "APIClientTests", "FooTests/zzz"], [], types);
    expect(plan.errors).toEqual([
      "unknown --test 'NoSuchTests': no test target declares NoSuchTests",
      "unknown --test 'NoSuchTests/a': no test target declares NoSuchTests",
      "ambiguous --test 'SharedSupportTests': declared in 2 test targets; use 'OppiUITests/SharedSupportTests' or 'OppiE2ETests/SharedSupportTests'",
      "unknown --test 'server'",
      "unknown --test 'OppiTests'",
      "unknown --test 'APIClient'",
      "unknown --test 'Legacy'",
      "unknown --test 'Alice'",
      "unknown --test 'GhostTests': no test target declares GhostTests",
      "--test 'OppiTests/FooTests/baz()': FooTests declares no test baz()",
      "--test 'OppiTests/APIClient': OppiTests declares no type APIClient",
      "--test 'OppiTests/FooTests/zzz': FooTests declares no test zzz",
    ]);
    // A bare selector whose resolved filter is rejected is not reported as resolved.
    expect(plan.resolutions).toEqual([
      "--test 'AfterUrlTests' resolved to OppiTests/AfterUrlTests",
      "--test 'APIClientTests' resolved to OppiTests/APIClientTests",
    ]);
  });

  test("an unknown test, an undeclared suite, or an unknown profile is an error, not an empty run", () => {
    const plan = planGate(
      "/wt",
      [
        "ChatRoutesUITest",
        "server/tests/../../etc.test.ts",
        "OppiUITests/ChatRouteUITests",
        "OppiTests/FooTest",
        "OppiTests/BarTests/bax()",
        "OppiTests/FooTests/baz()",
        "OppiE2ETests/ChatE2ETests/testSendMesage",
      ],
      ["watch"],
      types,
    );
    expect(plan.errors).toEqual([
      "unknown --test 'ChatRoutesUITest'",
      "unknown --test 'server/tests/../../etc.test.ts'",
      "unknown --profile 'watch' (iphone, ipad, duo)",
      "--test 'OppiTests/FooTest': OppiTests declares no type FooTest",
      "--test 'OppiTests/BarTests/bax()': BarTests declares no test bax()",
      "--test 'OppiTests/FooTests/baz()': FooTests declares no test baz()",
      "--test 'OppiUITests/ChatRouteUITests': OppiUITests declares no type ChatRouteUITests",
      "--test 'OppiE2ETests/ChatE2ETests/testSendMesage': ChatE2ETests declares no test testSendMesage",
    ]);
  });

  test("every E2E step must run at least one test", () => {
    const plan = planGate("/wt", ["OppiE2ETests/ChatE2ETests/testSend", "e2e-group:gate"], [], types);
    expect(plan.lanes.find((lane) => lane.name === "e2e")?.steps.map((step) => step.requireTests)).toEqual([true, true]);
  });

  test("a sim-pool run that executed zero tests is detected from its log", () => {
    const dir = mkdtempSync(join(tmpdir(), "batch-gate-"));
    try {
      const run = (log: string) => {
        writeFileSync(join(dir, "run.log"), log);
        writeFileSync(join(dir, "s.json"), JSON.stringify({ log_path: join(dir, "run.log") }));
        return executedTests(`noise\nArtifact: ${join(dir, "s.json")}\n`);
      };
      expect(run("✔ Test run with 12 tests in 2 suites passed after 1.0 seconds.\n")).toBe(12);
      expect(run("Test Suite 'Selected tests' passed at 2026-10-22 10:00:00.000.\n\t Executed 3 tests, with 0 failures (0 unexpected) in 9.0 (9.1) seconds\n")).toBe(3);
      expect(run("Test Suite 'Selected tests' passed at 2026-10-22 10:00:00.000.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds\n")).toBe(0);
      expect(executedTests("no artifact line")).toBe(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
