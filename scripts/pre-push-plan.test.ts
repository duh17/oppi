import { describe, expect, test } from "bun:test";
import { planForPaths } from "./pre-push-plan";

describe("pre-push gate planning", () => {
  test.each([
    ["docs only", ["README.md", "docs/architecture.md"], ["none", "none", false, false]],
    ["server source", ["server/src/server.ts"], ["changed", "none", false, false]],
    ["server tests", ["server/tests/server.test.ts"], ["changed", "none", false, false]],
    ["server config", ["server/vitest.config.ts"], ["full", "none", false, false]],
    ["iOS app", ["clients/apple/Oppi/App/OppiApp.swift"], ["none", "unit", false, false]],
    ["iOS unit tests", ["clients/apple/OppiTests/Network/APIClientTests.swift"], ["none", "unit", false, false]],
    ["iOS E2E", ["clients/apple/OppiE2ETests/ReleaseGateE2ETests.swift"], ["none", "all", false, false]],
    ["Mac", ["clients/apple/OppiMac/OppiMacApp.swift"], ["none", "none", true, false]],
    ["protocol", ["protocol/server-messages.json"], ["full", "unit", true, false]],
    ["server protocol model", ["server/src/types/protocol.ts"], ["full", "unit", true, false]],
    ["server session protocol model", ["server/src/types/session.ts"], ["full", "unit", true, false]],
    ["server icon protocol model", ["server/src/types/icon.ts"], ["full", "unit", true, false]],
    ["server git protocol type", ["server/src/types/git.ts"], ["full", "unit", true, false]],
    ["server shared protocol type", ["server/src/types/shared.ts"], ["full", "unit", true, false]],
    ["server thinking levels protocol type", ["server/src/thinking-levels.ts"], ["full", "unit", true, false]],
    ["Apple protocol model", ["clients/apple/OppiCore/Models/ServerMessage.swift"], ["full", "unit", true, false]],
    ["shared Apple source", ["clients/apple/Shared/SharedConstants.swift"], ["none", "unit", true, false]],
    ["Mac tests", ["clients/apple/OppiMacTests/MacAPIClientTests.swift"], ["none", "none", true, false]],
    ["Apple project", ["clients/apple/project.yml"], ["none", "all", true, false]],
    ["Apple xcconfig", ["clients/apple/Base.xcconfig"], ["none", "unit", true, false]],
    ["Mac scheme", ["clients/apple/Oppi.xcodeproj/xcshareddata/xcschemes/OppiMac.xcscheme"], ["none", "all", true, false]],
    ["architecture guard", ["server/scripts/check-architecture-boundaries.ts"], ["full", "unit", true, false]],
    ["gate policy", [".githooks/pre-push"], ["none", "none", false, true]],
    ["CI path detector", ["scripts/detect-ci-relevant-paths.sh"], ["none", "none", false, true]],
    ["gate allowlist", [".gitignore"], ["none", "none", false, true]],
    ["server gate policy", ["server/testing-policy.json"], ["full", "none", false, true]],
    ["unknown fails closed", ["tools/release.ts"], ["full", "unit", true, false]],
  ] as const)("classifies %s", (_name, paths, expected) => {
    const plan = planForPaths(paths);
    expect([plan.server, plan.apple, plan.mac, plan.harness]).toEqual(expected);
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
    expect(plan.mac).toBe(false);
  });

  test("deduplicates and sorts paths for deterministic cache input", () => {
    const plan = planForPaths(["server/src/z.ts", "server/src/a.ts", "server/src/z.ts"]);
    expect(plan.changedPaths).toEqual(["server/src/a.ts", "server/src/z.ts"]);
  });
});
