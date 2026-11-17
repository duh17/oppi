import { describe, expect, test } from "bun:test";
import { debugConditionLines, type FileChange, parseHunks, planForPaths, releaseCompileReason } from "./pre-push-plan";

describe("pre-push gate planning", () => {
  test.each([
    ["docs only", ["README.md", "docs/usage.md"], ["none", "none", false]],
    ["server source", ["server/src/server.ts"], ["changed", "none", false]],
    ["server tests", ["server/tests/server.test.ts"], ["changed", "none", false]],
    ["server config", ["server/vitest.config.ts"], ["full", "none", false]],
    ["Bun lane pin", ["server/.bun-version"], ["full", "none", false]],
    // The plugin host evaluates plugins at runtime, out of Vitest's import graph.
    ["server plugin", ["server/plugins/x/server.ts"], ["full", "none", false]],
    ["iOS app", ["clients/apple/Oppi/App/OppiApp.swift"], ["none", "unit", false]],
    ["iOS unit tests", ["clients/apple/OppiTests/Network/APIClientTests.swift"], ["none", "unit", false]],
    ["iOS E2E", ["clients/apple/OppiE2ETests/ReleaseGateE2ETests.swift"], ["none", "all", false]],
    ["accessibility id guard", ["scripts/ax-id-guard.ts", "scripts/ax-id-baseline.json"], ["none", "unit", false]],
    ["document edit guard", ["scripts/document-edit-guard.ts"], ["none", "unit", false]],
    ["warnings ratchet", ["scripts/apple-warnings.ts", "scripts/apple-warnings.test.ts"], ["none", "unit", true]],
    ["warnings baseline", ["scripts/apple-warnings-baseline.json"], ["none", "unit", false]],
    ["protocol", ["protocol/server-messages.json"], ["full", "unit", false]],
    ["server protocol model", ["server/src/types/protocol.ts"], ["full", "unit", false]],
    ["server session protocol model", ["server/src/types/session.ts"], ["full", "unit", false]],
    ["server icon protocol model", ["server/src/types/icon.ts"], ["full", "unit", false]],
    ["server git protocol type", ["server/src/types/git.ts"], ["full", "unit", false]],
    ["server shared protocol type", ["server/src/types/shared.ts"], ["full", "unit", false]],
    ["server thinking levels protocol type", ["server/src/thinking-levels.ts"], ["full", "unit", false]],
    ["Apple protocol model", ["clients/apple/OppiCore/Models/ServerMessage.swift"], ["full", "unit", false]],
    ["shared Apple source", ["clients/apple/Shared/SharedConstants.swift"], ["none", "unit", false]],
    ["Apple project", ["clients/apple/project.yml"], ["none", "all", false]],
    ["Apple package pins", ["clients/apple/Package.resolved"], ["none", "all", false]],
    ["Apple xcconfig", ["clients/apple/Base.xcconfig"], ["none", "unit", false]],
    ["architecture guard", ["server/scripts/check-architecture-boundaries.ts"], ["full", "unit", false]],
    ["gate policy", [".githooks/pre-push"], ["none", "none", true]],
    ["heavy-job semaphore", ["scripts/heavy.sh"], ["none", "none", true]],
    ["heavy-job semaphore test", ["scripts/heavy.test.ts"], ["none", "none", true]],
    ["gate allowlist", [".gitignore"], ["none", "none", true]],
    ["unknown fails closed", ["tools/release.ts"], ["full", "unit", false]],
    // batch-gate is executable gate code: it keeps the fail-closed lanes of an unknown path and
    // also runs its own self-test (the hook's run_self_test), which only harness=true triggers.
    ["batch gate", ["scripts/batch-gate.ts"], ["full", "unit", true]],
    ["batch gate test", ["scripts/batch-gate.test.ts"], ["full", "unit", true]],
  ] as const)("classifies %s", (_name, paths, expected) => {
    const plan = planForPaths(paths);
    expect([plan.server, plan.apple, plan.harness]).toEqual(expected);
  });

  test("takes the strongest union for mixed changes", () => {
    const plan = planForPaths([
      "server/src/server.ts",
      "server/package-lock.json",
      "clients/apple/Oppi/App/OppiApp.swift",
      "clients/apple/OppiUITests/LaunchTests.swift",
    ]);

    expect(plan.server).toBe("full");
    expect(plan.apple).toBe("all");
  });

  test.each([
    ["architecture doc", ["dev/architecture-client.md"], true],
    ["nested testing doc", ["dev/testing/apple.md"], true],
    ["doc budgets", ["dev/doc-budgets.json"], true],
    ["docs guard", ["scripts/dev-docs-guard.ts"], true],
    ["testing data beside the docs", ["dev/testing/lane-budgets.json"], false],
    ["public docs", ["docs/usage.md", "README.md"], false],
    ["server source", ["server/src/server.ts"], false],
  ] as const)("runs the dev docs guard for %s: %p", (_name, paths, expected) => {
    expect(planForPaths(paths).docs).toBe(expected);
  });

  test("a docs guard change runs its tests in the harness lane and no product lane", () => {
    const plan = planForPaths(["scripts/dev-docs-guard.ts", "scripts/dev-docs-guard.test.ts"]);
    expect([plan.server, plan.apple, plan.harness, plan.docs]).toEqual(["none", "none", true, true]);
  });

  test("deduplicates and sorts paths for deterministic cache input", () => {
    const plan = planForPaths(["server/src/z.ts", "server/src/a.ts", "server/src/z.ts"]);
    expect(plan.changedPaths).toEqual(["server/src/a.ts", "server/src/z.ts"]);
  });
});

describe("Release compile rule", () => {
  const file = (lines: string[]) => `${lines.join("\n")}\n`;
  /** Lines 3-7 are one DEBUG chain; 6 is Release-only. */
  const chained = file(["struct A {", "  var b = 1", "#if DEBUG", "  var harness = 1", "#else", "  var shipped = 2", "#endif", "  var c = 3", "}"]);
  const plain = file(["struct A {", "  var b = 1", "  var c = 3", "}"]);
  const APP = "clients/apple/Oppi/App/A.swift";
  const edit = (line: number, before = chained, after = chained): FileChange => ({ before, after, hunks: [{ oldStart: line, oldCount: 1, newStart: line, newCount: 1 }] });
  const reason = (changed: string[], changes: Record<string, FileChange[] | undefined> = {}, addedOrDeleted: string[] = []) =>
    releaseCompileReason(changed, new Set(addedOrDeleted), (path) => (path in changes ? changes[path] : [edit(2, plain, plain)]));

  test.each([
    ["project", "clients/apple/project.yml"],
    ["package pins", "clients/apple/Package.resolved"],
    ["xcconfig", "clients/apple/Base.xcconfig"],
    ["entitlements", "clients/apple/Oppi/Resources/Oppi.entitlements"],
    ["Info.plist", "clients/apple/Oppi/Resources/Info.plist"],
    ["Xcode pin", "clients/apple/scripts/xcode-toolchain.txt"],
  ])("compiles Release when a build input changes: %s", (_name, path) => {
    expect(reason([path])).toContain(path);
  });

  test("an edit outside every DEBUG chain compiles the same in Release, even in a file that has one", () => {
    expect(reason([APP], { [APP]: [edit(2), edit(8)] })).toBeNull();
    expect(reason(["clients/apple/OppiCore/Models/X.swift"])).toBeNull();
  });

  test.each([
    ["the Debug side", 4],
    ["the Release-only side", 6],
    ["a directive", 5],
  ])("an edit on %s of a DEBUG chain compiles Release", (_name, line) => {
    expect(reason([APP], { [APP]: [edit(line)] })).toContain("DEBUG condition");
  });

  test("adding or removing a DEBUG chain compiles Release", () => {
    const wrap = { oldStart: 2, oldCount: 0, newStart: 3, newCount: 5 };
    expect(reason([APP], { [APP]: [{ before: plain, after: chained, hunks: [wrap] }] })).toContain("DEBUG condition");
    const unwrap = { oldStart: 3, oldCount: 5, newStart: 2, newCount: 0 };
    expect(reason([APP], { [APP]: [{ before: chained, after: plain, hunks: [unwrap] }] })).toContain("DEBUG condition");
  });

  test("a chain counts when any condition names DEBUG, and a chain nested in one is inside it", () => {
    expect([...debugConditionLines(file(["#if os(iOS)", "a", "#elseif DEBUG", "b", "#endif", "c"]))]).toEqual([1, 2, 3, 4, 5]);
    expect([...debugConditionLines(file(["#if !DEBUG", "#if os(iOS)", "a", "#endif", "#endif"]))]).toEqual([1, 2, 3, 4, 5]);
    expect([...debugConditionLines(file(["#if os(iOS)", "a", "#endif", "let DEBUGGER = 1 // #if DEBUG"]))]).toEqual([]);
  });

  test("a DEBUG chain in a test target or the harness does not count", () => {
    expect(reason(["clients/apple/OppiTests/ATests.swift"], { "clients/apple/OppiTests/ATests.swift": [edit(4)] })).toBeNull();
    expect(reason(["clients/apple/OppiDebugHarness/Stage.swift"], { "clients/apple/OppiDebugHarness/Stage.swift": [edit(4)] })).toBeNull();
  });

  test("an unreadable app source change compiles Release", () => {
    expect(reason([APP], { [APP]: undefined })).toContain("could not be read");
  });

  test("a file moved out of the harness Release excludes compiles Release", () => {
    const harness = "clients/apple/OppiDebugHarness/Fixtures/Stage.swift";
    expect(reason(["clients/apple/Oppi/Stage.swift"], {}, [harness, "clients/apple/Oppi/Stage.swift"])).toContain(harness);
  });

  test("reads git's -U0 hunk headers, a count of 1 left out", () => {
    expect(parseHunks("diff --git a/x b/x\n@@ -5 +5,2 @@ func f()\n-a\n+b\n+c\n@@ -9,0 +11 @@\n+d\n")).toEqual([
      { oldStart: 5, oldCount: 1, newStart: 5, newCount: 2 },
      { oldStart: 9, oldCount: 0, newStart: 11, newCount: 1 },
    ]);
  });
});
