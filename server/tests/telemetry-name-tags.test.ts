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

  it("exempts only the absolute-path rule for route tags", () => {
    expect(NAME_LOCATION_RULES.filter((rule) => rule.exemptForRoute).map((r) => r.id)).toEqual([
      "absolute_path",
    ]);
    expect(looksLikeLocation("/workspaces/:workspaceId", true)).toBe(false);
  });

  describe("the needs prefilter", () => {
    const compiled = NAME_LOCATION_RULES.map((rule) => ({
      id: rule.id,
      regex: new RegExp(rule.source, rule.ignoreCase ? "i" : ""),
      needs: rule.needs.map((need) => need.toLowerCase()),
    }));
    const holdsNeed = (needs: string[], value: string): boolean =>
      needs.some((need) => value.toLowerCase().includes(need));

    /** Every string a rule matches must hold one of its needs, or the prefilter would hide a location. */
    const sweep = (values: Iterable<string>): void => {
      for (const value of values) {
        for (const rule of compiled) {
          if (rule.regex.test(value)) {
            expect(
              holdsNeed(rule.needs, value),
              `${rule.id} matches ${JSON.stringify(value)}`,
            ).toBe(true);
          }
        }
      }
    };

    it("never hides a value a rule matches: the shared fixture", () => {
      sweep([...FIXTURE.accept, ...FIXTURE.reject, ...FIXTURE.routeAccept, ...FIXTURE.routeReject]);
    });

    it("never hides a value a rule matches: a deterministic fuzz sweep", () => {
      const alphabet = [..."aAfF0159:./~@-_ lLoOcCaAhHsStT"].concat([
        "localhost",
        "::",
        ".ts.net",
        "://",
      ]);
      let seed = 0x2545f491;
      const next = (): number => {
        seed = (seed * 1664525 + 1013904223) >>> 0;
        return seed;
      };
      const values: string[] = [];
      for (let i = 0; i < 4000; i += 1) {
        const length = 1 + (next() % 9);
        let value = "";
        for (let j = 0; j < length; j += 1) value += alphabet[next() % alphabet.length]!;
        values.push(value);
      }
      sweep(values);
    });

    it("leaves plain identifiers to the prefilter alone", () => {
      for (const value of ["bash", "user_native", "chat", "queueSync-initial", "gpt-4"]) {
        expect(looksLikeLocation(value)).toBe(false);
        expect(compiled.some((rule) => holdsNeed(rule.needs, value))).toBe(false);
      }
    });
  });
});
