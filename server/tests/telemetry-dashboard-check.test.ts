import { describe, expect, it } from "vitest";

import {
  alertRuleSql,
  dashboardSql,
  dashboardViolations,
  seriesLiteralViolations,
  sqlCatalogViolations,
  sqlPrepareViolations,
} from "../scripts/check-telemetry.ts";
import {
  BEGIN_MARKER,
  END_MARKER,
  withGeneratedTables,
} from "../scripts/generate-telemetry-docs.ts";

const WINDOW = "AND ts_ms BETWEEN $__from AND $__to";

describe("dashboard SQL against the catalog", () => {
  it("holds for the shipped dashboards and alert rules", () => {
    expect(dashboardViolations()).toEqual([]);
  });

  it("rejects the stale catch-up filter value nothing emits", () => {
    const sql = `SELECT ts_ms FROM events WHERE name = 'app.catchup'
      AND COALESCE(json_extract(tags_json, '$.result'), '') = 'cache_seeded' ${WINDOW}`;
    expect(sqlCatalogViolations("panel", sql)).toEqual([
      'panel: tag "result" is compared with "cache_seeded", which app.catchup never has',
    ]);
  });

  it("checks every literal of an IN list and a NOT IN list against the tag's values for that event", () => {
    const sql = `SELECT 1 FROM events WHERE name = 'app.catchup'
      AND json_extract(tags_json, '$.result') NOT IN ('no_gap', 'cache_seeded')
      AND json_extract(tags_json, '$.result') IN ('applied', 'delivered')`;
    // `delivered` is a catalog result, but not one app.catchup has.
    expect(sqlCatalogViolations("panel", sql)).toEqual([
      'panel: tag "result" is compared with "cache_seeded", which app.catchup never has',
      'panel: tag "result" is compared with "delivered", which app.catchup never has',
    ]);
  });

  it("honors a value set an event narrows", () => {
    const sql = `SELECT 1 FROM events WHERE name = 'server.turn'
      AND json_extract(tags_json, '$.error_kind') = 'connection'`;
    expect(sqlCatalogViolations("panel", sql)).toEqual([
      'panel: tag "error_kind" is compared with "connection", which server.turn never has',
    ]);
  });

  it("rejects an unknown event and keys the named event does not carry", () => {
    const sql = `SELECT json_extract(fields_json, '$.value') AS v,
        json_extract(tags_json, '$.lane') AS lane
      FROM events WHERE name = 'app.ttft'`;
    expect(sqlCatalogViolations("panel", sql)).toEqual([
      'panel: field "value" is not carried by app.ttft',
      'panel: tag "lane" is not carried by app.ttft',
    ]);
    expect(
      sqlCatalogViolations("panel", "SELECT 1 FROM events WHERE name = 'chat.ttft_ms'"),
    ).toEqual(['panel: event "chat.ttft_ms" is not in the catalog']);
    expect(
      sqlCatalogViolations("panel", "SELECT json_extract(tags_json, '$.status') FROM events"),
    ).toEqual(['panel: reads tags_json "status" without naming an event']);
  });

  it("accepts keys carried by any event a multi-event query names, and open-vocabulary tag values", () => {
    const sql = `SELECT
        SUM(CASE WHEN name = 'server.turn' AND json_extract(tags_json, '$.status') = 'error' THEN 1 ELSE 0 END),
        AVG(CASE WHEN name = 'server.turn_ttft' THEN json_extract(fields_json, '$.duration_ms') END)
      FROM events WHERE name IN ('server.turn', 'server.turn_ttft')
        AND json_extract(tags_json, '$.provider') = 'whatever-provider'`;
    expect(sqlCatalogViolations("panel", sql)).toEqual([]);
  });

  it("collects SQL from nested rows, both query keys, and template variables", () => {
    const found = dashboardSql("d.json", {
      templating: { list: [{ name: "provider", query: "SELECT 1", definition: "SELECT 2" }] },
      panels: [
        {
          title: "top",
          targets: [{ refId: "A", rawQueryText: "SELECT 3", queryText: "SELECT 3" }],
        },
        {
          title: "row",
          panels: [{ title: "nested", targets: [{ refId: "B", rawQueryText: "SELECT 4" }] }],
        },
      ],
    });
    expect(found.map((source) => source.sql)).toEqual([
      "SELECT 3",
      "SELECT 3",
      "SELECT 4",
      "SELECT 1",
      "SELECT 2",
    ]);
  });

  it("extracts folded alert rule queries and stops at the next key", () => {
    const yaml = [
      "      model:",
      "        queryType: table",
      "        rawQueryText: >-",
      "          SELECT COUNT(*) AS value",
      "          FROM events WHERE name = 'server.ws_ping_timeout'",
      "      - refId: B",
    ].join("\n");
    expect(alertRuleSql("alerts.yml", yaml).map((source) => source.sql)).toEqual([
      "SELECT COUNT(*) AS value FROM events WHERE name = 'server.ws_ping_timeout'",
    ]);
  });

  it("rejects SQL the importer's schema cannot run, such as a pre-v2 table", () => {
    const problems = sqlPrepareViolations([
      { where: "legacy", sql: "SELECT value FROM chat_metric_samples WHERE metric = 'x'" },
      { where: "typo", sql: "SELECT ts_msec FROM events" },
      {
        where: "ok",
        sql: "SELECT json_extract(fields_json, '$.duration_ms') FROM events WHERE name IN (${route:sqlstring}) AND ts_ms BETWEEN $__from AND ${__to}",
      },
    ]);
    expect(problems).toHaveLength(2);
    expect(problems[0]).toContain("legacy: no such table: chat_metric_samples");
    expect(problems[1]).toContain("typo: no such column: ts_msec");
  });
});

describe("review script series literals", () => {
  it("rejects events and event.field series the catalog does not have", () => {
    const source = `const a = "app.session_load.duration_ms"; const b = "app.session_load.latency_ms";
      const c = "server.turn_error"; const d = "server.log";`;
    expect(seriesLiteralViolations("review.ts", source)).toEqual([
      'review.ts: "app.session_load.latency_ms" names a field app.session_load does not have',
      'review.ts: "server.turn_error" names an event the catalog does not have',
      'review.ts: "server.log" names an event the catalog does not have',
    ]);
  });
});

describe("generated docs tables", () => {
  it("replaces only the text between the markers, and reports a page without them", () => {
    const page = `intro\n${BEGIN_MARKER}\nold table\n${END_MARKER}\noutro\n`;
    const next = withGeneratedTables(page, "NEW");
    expect(next).toBe(`intro\n${BEGIN_MARKER}\n\nNEW\n\n${END_MARKER}\noutro\n`);
    expect(withGeneratedTables(next!, "NEW")).toBe(next);
    expect(withGeneratedTables("no markers here")).toBeNull();
  });
});
