// exported-entitlements.ts — verify the signed entitlements of an exported Oppi IPA.
//
// Distribution signing rewrites entitlements (aps-environment development -> production)
// and the provisioning profile decides which capabilities survive. This reads what the
// exported bundles are actually signed with, so a missing capability fails the release
// before upload instead of silently shipping.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";

export type Entitlements = Record<string, unknown>;

export const APS_ENVIRONMENT = "aps-environment";
export const APP_GROUPS = "com.apple.security.application-groups";
export const TIME_SENSITIVE = "com.apple.developer.usernotifications.time-sensitive";

const APP_GROUP_VARIABLE = "$(APP_GROUP_IDENTIFIER)";

export type ExpectedEntitlements = {
  appGroup: string;
};

/** Convert a plist (XML or binary) to a JS object with plutil. */
export function parsePlist(plist: string | Buffer): Entitlements {
  const result = spawnSync("plutil", ["-convert", "json", "-o", "-", "-"], {
    input: plist,
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`plutil could not parse entitlements: ${(result.stderr || "").trim()}`);
  }
  return JSON.parse(result.stdout) as Entitlements;
}

/** The App Group the app and notification extension entitlements files declare. */
export function expectedEntitlements(appleDir: string): ExpectedEntitlements {
  const projectYml = fs.readFileSync(path.join(appleDir, "project.yml"), "utf-8");
  const variable = projectYml.match(/^\s*APP_GROUP_IDENTIFIER:\s*(\S+)\s*$/m)?.[1];
  if (!variable) throw new Error("APP_GROUP_IDENTIFIER not found in project.yml");

  const groupFor = (entitlementsPath: string): string => {
    const groups = parsePlist(fs.readFileSync(path.join(appleDir, entitlementsPath)))[APP_GROUPS];
    if (!Array.isArray(groups) || groups.length !== 1 || typeof groups[0] !== "string") {
      throw new Error(`${entitlementsPath} must declare exactly one App Group`);
    }
    return groups[0] === APP_GROUP_VARIABLE ? variable : groups[0];
  };

  const appGroup = groupFor("Oppi/Resources/Oppi.entitlements");
  const extensionGroup = groupFor("OppiNotificationService/OppiNotificationService.entitlements");
  if (appGroup !== extensionGroup) {
    throw new Error(`App (${appGroup}) and notification extension (${extensionGroup}) App Groups differ`);
  }
  return { appGroup };
}

/** Human-readable failures; empty when the exported entitlements are correct. */
export function entitlementFailures(
  app: Entitlements,
  notificationService: Entitlements,
  expected: ExpectedEntitlements,
): string[] {
  const failures: string[] = [];
  const hasGroup = (e: Entitlements) =>
    Array.isArray(e[APP_GROUPS]) && (e[APP_GROUPS] as unknown[]).includes(expected.appGroup);

  if (app[APS_ENVIRONMENT] !== "production") {
    failures.push(`Oppi.app ${APS_ENVIRONMENT} is ${JSON.stringify(app[APS_ENVIRONMENT])}, expected "production"`);
  }
  if (!hasGroup(app)) {
    failures.push(`Oppi.app ${APP_GROUPS} is ${JSON.stringify(app[APP_GROUPS])}, expected to include "${expected.appGroup}"`);
  }
  if (!hasGroup(notificationService)) {
    failures.push(
      `notification service extension ${APP_GROUPS} is ${JSON.stringify(notificationService[APP_GROUPS])}, expected to include "${expected.appGroup}"`,
    );
  }
  if (app[TIME_SENSITIVE] !== true) {
    failures.push(`Oppi.app ${TIME_SENSITIVE} is ${JSON.stringify(app[TIME_SENSITIVE])}, expected true`);
  }
  return failures;
}

function signedEntitlements(bundlePath: string): Entitlements {
  if (!fs.existsSync(bundlePath)) throw new Error(`${bundlePath} not found in the exported IPA`);
  const result = spawnSync("codesign", ["-d", "--entitlements", "-", "--xml", bundlePath], {
    encoding: "buffer",
  });
  if (result.status !== 0) {
    throw new Error(`codesign failed for ${bundlePath}: ${result.stderr.toString().trim()}`);
  }
  // `--entitlements -` writes to stdout; `--xml` forces the XML plist (the `:-` form is
  // deprecated). codesign's "Executable=..." chatter goes to stderr.
  return parsePlist(result.stdout);
}

/**
 * Unzip the exported .ipa under `exportPath` and assert the signed entitlements.
 * Throws with every failed assertion; returns the entitlements it checked.
 */
export function verifyExportedIpa(
  exportPath: string,
  appleDir: string,
): { app: Entitlements; notificationService: Entitlements; expected: ExpectedEntitlements } {
  const ipas = fs.readdirSync(exportPath).filter((name) => name.endsWith(".ipa"));
  if (ipas.length !== 1) {
    throw new Error(`expected exactly one .ipa in ${exportPath}, found ${ipas.length}`);
  }
  const expected = expectedEntitlements(appleDir);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "oppi-ipa-"));
  try {
    const unzip = spawnSync("unzip", ["-q", path.join(exportPath, ipas[0]), "-d", tmp], {
      encoding: "utf8",
    });
    if (unzip.status !== 0) throw new Error(`unzip failed: ${(unzip.stderr || "").trim()}`);

    const appPath = path.join(tmp, "Payload", "Oppi.app");
    const app = signedEntitlements(appPath);
    const notificationService = signedEntitlements(
      path.join(appPath, "PlugIns", "OppiNotificationService.appex"),
    );
    const failures = entitlementFailures(app, notificationService, expected);
    if (failures.length > 0) {
      throw new Error(
        `Exported IPA entitlement check failed:\n${failures.map((f) => `  - ${f}`).join("\n")}`,
      );
    }
    return { app, notificationService, expected };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
