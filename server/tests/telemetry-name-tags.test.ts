import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

import { NAME_LOCATION_RULES } from "../src/telemetry/catalog.js";
import { looksLikeLocation, sanitizeNameTag } from "../src/telemetry/validate.js";

/** The one accept/reject list; the Swift test reads the same file. */
const FIXTURE = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      "..",
      "..",
      "protocol",
      "telemetry-name-tags.json",
    ),
    "utf8",
  ),
) as { accept: string[]; reject: string[]; routeAccept: string[]; routeReject: string[] };

describe("name tag sanitizing", () => {
  it.each(FIXTURE.accept)("keeps the identifier %j", (value) => {
    expect(sanitizeNameTag(value)).toBe(value);
  });

  it.each(FIXTURE.reject)("stores %j as unknown", (value) => {
    expect(sanitizeNameTag(value)).toBe("unknown");
  });

  it.each(FIXTURE.routeAccept)("lets a route tag keep the template %j", (value) => {
    expect(sanitizeNameTag(value, true)).toBe(value);
    expect(sanitizeNameTag(value)).toBe("unknown");
  });

  it.each(FIXTURE.routeReject)("a route allowance does not excuse %j", (value) => {
    expect(sanitizeNameTag(value, true)).toBe("unknown");
  });

  it("applies every catalog rule, and only the absolute-path rule is route-exempt", () => {
    expect(NAME_LOCATION_RULES.map((rule) => rule.id)).toEqual([
      "url_scheme",
      "home_path",
      "absolute_path",
      "localhost",
      "private_host_suffix",
      "ipv4",
      "ipv6",
      "host_port",
      "user_at_host",
    ]);
    expect(NAME_LOCATION_RULES.filter((rule) => rule.exemptForRoute).map((r) => r.id)).toEqual([
      "absolute_path",
    ]);
    expect(looksLikeLocation("/workspaces/:workspaceId", true)).toBe(false);
  });
});
