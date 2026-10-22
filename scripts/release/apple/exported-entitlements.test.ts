import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import {
  APP_GROUPS,
  APS_ENVIRONMENT,
  TIME_SENSITIVE,
  entitlementFailures,
  expectedEntitlements,
} from "./exported-entitlements";

const appleDir = resolve(import.meta.dir, "../../../clients/apple");
const expected = { appGroup: "group.oppi" };
const goodApp = {
  [APS_ENVIRONMENT]: "production",
  [APP_GROUPS]: ["group.oppi"],
  [TIME_SENSITIVE]: true,
};
const goodExtension = { [APP_GROUPS]: ["group.oppi"] };

describe("exported IPA entitlement assertions", () => {
  test("reads the App Group from the checked-in entitlements, resolving the build variable", () => {
    expect(expectedEntitlements(appleDir).appGroup).toBe("group.oppi");
  });

  test("accepts a correctly signed app and extension", () => {
    expect(entitlementFailures(goodApp, goodExtension, expected)).toEqual([]);
  });

  test("names each missing or wrong entitlement", () => {
    const failures = entitlementFailures(
      { [APS_ENVIRONMENT]: "development", [APP_GROUPS]: ["group.other"] },
      {},
      expected,
    );
    expect(failures).toHaveLength(4);
    expect(failures.join("\n")).toContain("Oppi.app aps-environment");
    expect(failures.join("\n")).toContain("Oppi.app com.apple.security.application-groups");
    expect(failures.join("\n")).toContain("notification service extension");
    expect(failures.join("\n")).toContain("Oppi.app com.apple.developer.usernotifications.time-sensitive");
  });
});
