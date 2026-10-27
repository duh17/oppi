import { describe, expect, it } from "vitest";

import { catalogViolations, nameRuleViolations } from "../scripts/check-telemetry.ts";
import { EVENT_DEFS, type EventDef, type TagDef } from "../src/telemetry/catalog.js";
import { validateEvent } from "../src/telemetry/validate.js";
import { telemetryUploadsEnabledFromEnv } from "../src/types.js";

const TAGS: Record<string, TagDef> = {
  status: { kind: "enum", values: ["ok", "error"], description: "Outcome." },
  tool: { kind: "name", description: "Tool name." },
};

function catalogWith(event: EventDef, tags: Record<string, TagDef> = TAGS): string[] {
  return catalogViolations({ "app.thing": event }, tags);
}

describe("telemetry catalog invariants", () => {
  it("holds for the shipped catalog", () => {
    expect(catalogViolations()).toEqual([]);
  });

  it("rejects fields whose name and unit disagree", () => {
    const problems = catalogWith({
      description: "x",
      group: "ux",
      fields: { duration: "ms", payload: "bytes", items_ms: "count", loadMs: "ms" },
      tags: { status: {}, tool: {} },
    });
    expect(problems).toEqual(
      expect.arrayContaining([
        'app.thing: ms field "duration" must end "_ms"',
        'app.thing: bytes field "payload" must end "_bytes"',
        'app.thing: count field "items_ms" must not end "_ms"',
        'app.thing: field "loadMs" is not snake_case',
      ]),
    );
  });

  it("rejects ambiguous tag keys, unknown keys, and narrowing outside the vocabulary", () => {
    const problems = catalogWith(
      {
        description: "x",
        group: "ux",
        fields: { duration_ms: "ms" },
        tags: {
          status: { values: ["ok", "success"] },
          tool: { values: ["bash"] },
          extra: {},
          path: {},
        },
      },
      { ...TAGS, path: { kind: "name", description: "Stream or route." } },
    );
    expect(problems).toEqual(
      expect.arrayContaining([
        'tag "path" is ambiguous: use stream, load_path, model_path, or path_pattern',
        'app.thing: narrows "status" to "success", which is not in its vocabulary',
        'app.thing: narrows "tool", which is not an enum',
        'app.thing: tag "extra" is not in the vocabulary',
      ]),
    );
  });

  it("rejects SLOs, emit rules, and storage that reference what the event lacks", () => {
    const problems = catalogViolations(
      {
        "server.thing": {
          description: "x",
          group: "server",
          fields: { duration_ms: "ms", hit: "bool", bytes_sent_bytes: "bytes" },
          tags: { status: {} },
          emit: [{ field: "missing_ms", min: 1 }],
          storage: { aggregate: { duration_ms: "sum" } },
          slo: [
            { field: "latency_ms", tm99: 10, label: "A" },
            { field: "hit", tm99: 1, label: "B" },
            { field: "duration_ms", tm99: 10, label: "C", where: { status: ["cached"] } },
          ],
        },
      },
      { status: TAGS.status! },
    );
    expect(problems).toEqual([
      'server.thing: emit rule on unknown field "missing_ms"',
      'server.thing: aggregate storage drops field "hit"; give it sum or max',
      'server.thing: aggregate storage drops field "bytes_sent_bytes"; give it sum or max',
      'server.thing: SLO on unknown field "latency_ms"',
      'server.thing: SLO on bool field "hit"',
      'server.thing: SLO on "duration_ms" filters "status" on "cached", which it never has',
    ]);
  });

  it("rejects empty enums and buckets that do not ascend to an open end", () => {
    const problems = catalogWith(
      { description: "x", group: "ux", fields: {}, tags: { status: {}, size: {}, tool: {} } },
      {
        ...TAGS,
        status: { kind: "enum", values: [], description: "Outcome." },
        size: {
          kind: "bucket",
          source: "bytes",
          buckets: [
            { name: "small", below: 10 },
            { name: "mid", below: 5 },
            { name: "big", below: 20 },
          ],
          description: "Size.",
        },
      },
    );
    expect(problems).toEqual(
      expect.arrayContaining([
        'tag "status" has no values',
        'bucket tag "size": edges must ascend',
        'bucket tag "size": the last bucket must be open-ended',
      ]),
    );
  });

  it("refuses every event recorded under the other origin", () => {
    for (const name of Object.keys(EVENT_DEFS)) {
      const origin = name.startsWith("app.") ? "server" : "app";
      expect(validateEvent(origin, name, {}, {})).toEqual({ ok: false, reason: "wrong_origin" });
    }
  });

  it("parses OPPI_TELEMETRY_MODE consistently", () => {
    expect(telemetryUploadsEnabledFromEnv(undefined)).toBe(true);
    expect(telemetryUploadsEnabledFromEnv("internal")).toBe(true);
    expect(telemetryUploadsEnabledFromEnv("PUBLIC")).toBe(false);
    expect(telemetryUploadsEnabledFromEnv("unknown-mode")).toBe(false);
  });

  describe("name location rules", () => {
    const rule = (id: string, source: string, needs: string[] = ["."]) => ({
      id,
      source,
      needs,
      description: "x",
    });

    it("holds for the shipped rules", () => {
      expect(nameRuleViolations()).toEqual([]);
    });

    it("rejects regex constructs ICU and JavaScript do not share", () => {
      const problems = nameRuleViolations([
        rule("lookbehind", "(?<=a)b"),
        rule("named", "(?<host>x)y"),
        rule("inline_flag", "(?i)host"),
        rule("property", "^\\p{L}+$"),
        rule("backref", "(x)\\k<a>"),
        rule("lookahead_ok", "^(?=a)b$"),
        rule("group_ok", "^(?:ab)+$"),
      ]);
      expect(problems).toEqual([
        'name rule "lookbehind" uses lookbehind or named group (?<, which is not portable to Swift (ICU)',
        'name rule "named" uses lookbehind or named group (?<, which is not portable to Swift (ICU)',
        'name rule "inline_flag" uses inline flag (?i, which is not portable to Swift (ICU)',
        'name rule "inline_flag" is not a valid regular expression',
        'name rule "property" uses Unicode property \\p{, which is not portable to Swift (ICU)',
        'name rule "backref" uses named backreference \\k<, which is not portable to Swift (ICU)',
      ]);
    });

    it("rejects duplicate ids, empty needs, and letter-only single needs", () => {
      const problems = nameRuleViolations([
        rule("a", "x"),
        rule("a", "y"),
        rule("no_needs", "z", []),
        rule("letter", "q", ["q"]),
        rule("broken", "(", ["."]),
      ]);
      expect(problems).toEqual([
        'name rule "a" is declared twice',
        'name rule "no_needs" has no needs prefilter',
        'name rule "letter": single-character need "q" must not be a letter',
        'name rule "broken" is not a valid regular expression',
      ]);
    });
  });
});
