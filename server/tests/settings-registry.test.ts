import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import {
  SERVER_SETTING_DEFINITIONS,
  SettingValidationError,
  validateSetting,
} from "../src/settings/registry.js";

interface FixtureSetting {
  key: string;
  scope: string;
  storage: string;
  type: string;
  default: unknown;
  validation: string;
  revisioned: boolean;
}

/** The hand-maintained copy the clients read; this test keeps it and the registry in step. */
const FIXTURE = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "..", "..", "protocol", "settings.json"),
    "utf8",
  ),
) as { settings: FixtureSetting[] };

describe("settings registry and protocol/settings.json", () => {
  it("lists exactly the registered keys", () => {
    expect(FIXTURE.settings.map((setting) => setting.key).sort()).toEqual(
      SERVER_SETTING_DEFINITIONS.map((definition) => definition.key).sort(),
    );
  });

  it.each(SERVER_SETTING_DEFINITIONS.map((definition) => [definition.key, definition] as const))(
    "%s matches its fixture row",
    (key, definition) => {
      const row = FIXTURE.settings.find((setting) => setting.key === key);
      expect(row).toBeDefined();
      expect(row).toMatchObject({
        scope: definition.scope,
        storage: definition.storage,
        revisioned: definition.revisioned,
      });
      expect(row?.default).toEqual(definition.default);
      expect(row?.type).not.toBe("");
      expect(row?.validation).not.toBe("");
    },
  );
});

describe("registry validation", () => {
  it("accepts auto-title models only as provider/id and clears with null", () => {
    expect(validateSetting("autoTitle", { enabled: true, model: " anthropic/haiku " })).toEqual({
      enabled: true,
      model: "anthropic/haiku",
    });
    expect(validateSetting("autoTitle", { model: null })).toEqual({ model: null });
    for (const model of ["haiku", "/haiku", "anthropic/", "", "  ", 7]) {
      expect(() => validateSetting("autoTitle", { model })).toThrow(SettingValidationError);
    }
    expect(() => validateSetting("autoTitle", { enabled: "yes" })).toThrow(SettingValidationError);
    expect(() => validateSetting("autoTitle", [])).toThrow(SettingValidationError);
  });
});
