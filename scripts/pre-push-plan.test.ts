import { describe, expect, test } from "bun:test";
import { planForPaths } from "./pre-push-plan";

describe("pre-push gate planning", () => {
  test.each([
    ["docs only", ["README.md", "docs/usage.md"], ["none", "none", false]],
    ["server source", ["server/src/server.ts"], ["changed", "none", false]],
    ["server tests", ["server/tests/server.test.ts"], ["changed", "none", false]],
    ["server config", ["server/vitest.config.ts"], ["full", "none", false]],
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
