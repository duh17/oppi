#!/usr/bin/env bun

/**
 * Telemetry drift check, part of `npm run check`.
 *
 *   bun server/scripts/check-telemetry.ts
 *
 * Every consumer of the telemetry catalog (`server/src/telemetry/catalog.ts`)
 * must agree with it. Each check below returns violations; any violation
 * fails the run.
 *
 * - catalog: naming, unit suffixes, one meaning per tag key, narrowed values,
 *   bucket edges, emit rules, storage, and SLOs are internally consistent.
 * - generated-swift: TelemetryCatalog.generated.swift matches the generator.
 * - generated-docs: the event tables of dev/telemetry.md match the generator.
 * - dashboards: every panel query and template-variable query of the Grafana
 *   dashboards, and every provisioned alert rule query, is valid SQL against the
 *   importer's schema, names only catalog events, and reads only `fields_json`
 *   and `tags_json` keys the named events carry. A tag compared with a literal
 *   (`json_extract(tags_json, '$.result') = 'cache_seeded'`, `IN (...)`) must
 *   compare with a value the catalog allows for that tag. A query is checked
 *   against the union of the events it names, so a key valid for one event of a
 *   multi-event query passes; single-event queries are exact.
 * - review-script: every event and `<event>.<field>` series literal in
 *   telemetry-review.ts exists in the catalog.
 * - importer: the importer reads the file names the event writer produces.
 *
 * Extension point: add a `Check` to `CHECKS` for each further consumer.
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";

import {
  EVENT_DEFS,
  TAG_DEFS,
  eventOrigin,
  fieldSpec,
  type EventDef,
  type FieldUnit,
  type TagDef,
} from "../src/telemetry/catalog.ts";
import { telemetryEventFileName } from "../src/telemetry/event-writer.ts";
import { DOCS_PATH, withGeneratedTables } from "./generate-telemetry-docs.ts";
import { GENERATED_SWIFT_PATH, generateSwift } from "./generate-telemetry-catalog.ts";

interface Check {
  name: string;
  run(): string[];
}

const SNAKE_CASE = /^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/;
const EVENT_NAME = /^(?:app|server)\.[a-z][a-z0-9]*(?:_[a-z0-9]+)*$/;
const TAG_VALUE = /^[a-z0-9][a-z0-9_-]*$/;

const UNIT_SUFFIX: Partial<Record<FieldUnit, string>> = {
  ms: "_ms",
  bytes: "_bytes",
  mb: "_mb",
  pct: "_pct",
  ratio: "_ratio",
  usd_micros: "_usd_micros",
};
const ALL_SUFFIXES = Object.values(UNIT_SUFFIX);

/**
 * Keys that carried two or more meanings before the catalog, or that are IDs or
 * numbers. Each meaning now has its own key (see dev/telemetry.md, "Tag
 * vocabulary"); reintroducing one of these would bring the ambiguity back.
 */
const RETIRED_TAG_KEYS: Record<string, string> = {
  path: "use stream, load_path, model_path, or path_pattern",
  level: "use stream",
  lane: "use stream",
  mode: "use audio_mode or playback_mode",
  category: "use audio_category or error_kind",
  source: "use trigger, playback_source, load_source, or origin_surface",
  outcome: "use status or result",
  success: "use status",
  stage: "use phase or reason",
  fail_reason: "use error_kind",
  provider_id: "use stt_provider",
  host: "never store a host; use host_kind",
  kind: "use media_kind, run_kind, or another specific key",
  type: "use message_type",
  event: "use notification",
  code: "use close_code",
  error: "use error_kind",
  session_id: "sessionId is a record field, never a tag",
  workspace_id: "workspaceId is a record field, never a tag",
};

function checkField(event: string, key: string, unit: FieldUnit): string[] {
  const problems: string[] = [];
  if (!SNAKE_CASE.test(key)) problems.push(`${event}: field "${key}" is not snake_case`);
  const suffix = UNIT_SUFFIX[unit];
  if (suffix) {
    if (!key.endsWith(suffix))
      problems.push(`${event}: ${unit} field "${key}" must end "${suffix}"`);
    else {
      const otherSuffix = ALL_SUFFIXES.find(
        (candidate) =>
          candidate !== suffix && candidate!.length > suffix.length && key.endsWith(candidate!),
      );
      if (otherSuffix) problems.push(`${event}: ${unit} field "${key}" ends with "${otherSuffix}"`);
    }
  } else {
    const wrong = ALL_SUFFIXES.find((candidate) => key.endsWith(candidate!));
    if (wrong) problems.push(`${event}: ${unit} field "${key}" must not end "${wrong}"`);
  }
  return problems;
}

function checkTagVocabulary(tags: Readonly<Record<string, TagDef>>): string[] {
  const problems: string[] = [];
  for (const [key, def] of Object.entries(tags)) {
    if (!SNAKE_CASE.test(key)) problems.push(`tag "${key}" is not snake_case`);
    if (RETIRED_TAG_KEYS[key]) problems.push(`tag "${key}" is ambiguous: ${RETIRED_TAG_KEYS[key]}`);
    if (!def.description.trim())
      problems.push(`tag "${key}" has no description of its one meaning`);
    if (def.kind === "enum") {
      if (def.values.length === 0) problems.push(`tag "${key}" has no values`);
      if (new Set(def.values).size !== def.values.length) {
        problems.push(`tag "${key}" lists a value twice`);
      }
      for (const value of def.values) {
        if (!TAG_VALUE.test(value))
          problems.push(`tag "${key}" value "${value}" is not lower_snake`);
      }
    }
    if (def.kind === "bucket") {
      if (def.buckets.length === 0) problems.push(`bucket tag "${key}" has no buckets`);
      let previous = -Infinity;
      def.buckets.forEach((bucket, index) => {
        const last = index === def.buckets.length - 1;
        if (!TAG_VALUE.test(bucket.name)) {
          problems.push(`bucket tag "${key}" name "${bucket.name}" is not lower_snake`);
        }
        if (last && bucket.below !== undefined) {
          problems.push(`bucket tag "${key}": the last bucket must be open-ended`);
        }
        if (!last) {
          if (bucket.below === undefined) {
            problems.push(`bucket tag "${key}": only the last bucket may be open-ended`);
          } else if (bucket.below <= previous) {
            problems.push(`bucket tag "${key}": edges must ascend`);
          } else previous = bucket.below;
        }
      });
    }
  }
  return problems;
}

function allowedValues(
  tags: Readonly<Record<string, TagDef>>,
  event: EventDef,
  key: string,
): readonly string[] | undefined {
  const def = tags[key];
  if (!def || def.kind === "name") return undefined;
  if (def.kind === "bucket") return def.buckets.map((bucket) => bucket.name);
  return event.tags?.[key]?.values ?? def.values;
}

function checkWhere(
  tags: Readonly<Record<string, TagDef>>,
  name: string,
  event: EventDef,
  context: string,
  where: Readonly<Record<string, readonly string[]>> | undefined,
): string[] {
  const problems: string[] = [];
  for (const [key, values] of Object.entries(where ?? {})) {
    if (!event.tags?.[key]) {
      problems.push(`${name}: ${context} filters on tag "${key}", which the event does not carry`);
      continue;
    }
    const allowed = allowedValues(tags, event, key);
    if (values.length === 0) problems.push(`${name}: ${context} filter on "${key}" is empty`);
    for (const value of values) {
      if (allowed && !allowed.includes(value)) {
        problems.push(`${name}: ${context} filters "${key}" on "${value}", which it never has`);
      }
    }
  }
  return problems;
}

function checkEvent(
  tags: Readonly<Record<string, TagDef>>,
  name: string,
  event: EventDef,
): string[] {
  const problems: string[] = [];
  if (!EVENT_NAME.test(name)) problems.push(`event "${name}" is not <app|server>.<snake_case>`);
  if (!event.description.trim()) problems.push(`${name}: no description`);

  for (const [key, def] of Object.entries(event.fields)) {
    problems.push(...checkField(name, key, fieldSpec(def).unit));
  }

  for (const [key, use] of Object.entries(event.tags ?? {})) {
    const def = tags[key];
    if (!def) {
      problems.push(`${name}: tag "${key}" is not in the vocabulary`);
      continue;
    }
    if (event.fields[key]) problems.push(`${name}: "${key}" is both a field and a tag`);
    if (use.values) {
      if (def.kind !== "enum") problems.push(`${name}: narrows "${key}", which is not an enum`);
      else {
        if (use.values.length === 0) problems.push(`${name}: narrows "${key}" to no values`);
        for (const value of use.values) {
          if (!def.values.includes(value)) {
            problems.push(
              `${name}: narrows "${key}" to "${value}", which is not in its vocabulary`,
            );
          }
        }
      }
    }
  }

  for (const rule of event.emit ?? []) {
    if (!event.fields[rule.field]) {
      problems.push(`${name}: emit rule on unknown field "${rule.field}"`);
    }
    if (rule.min === undefined && rule.max === undefined) {
      problems.push(`${name}: emit rule on "${rule.field}" has no bound`);
    }
    problems.push(...checkWhere(tags, name, event, "emit rule", rule.where));
  }

  if (event.storage) {
    if (eventOrigin(name) !== "server") problems.push(`${name}: only server events aggregate`);
    const fields = Object.keys(event.fields);
    const aggregated = Object.keys(event.storage.aggregate);
    for (const field of fields) {
      if (!aggregated.includes(field)) {
        problems.push(`${name}: aggregate storage drops field "${field}"; give it sum or max`);
      }
    }
    for (const field of aggregated) {
      if (!fields.includes(field)) problems.push(`${name}: aggregates unknown field "${field}"`);
    }
  }

  for (const slo of event.slo ?? []) {
    const field = event.fields[slo.field];
    if (!field) {
      problems.push(`${name}: SLO on unknown field "${slo.field}"`);
      continue;
    }
    if (fieldSpec(field).unit === "bool")
      problems.push(`${name}: SLO on bool field "${slo.field}"`);
    if (!(slo.tm99 > 0)) problems.push(`${name}: SLO on "${slo.field}" needs a positive tm99`);
    if (!slo.label.trim()) problems.push(`${name}: SLO on "${slo.field}" has no label`);
    problems.push(...checkWhere(tags, name, event, `SLO on "${slo.field}"`, slo.where));
  }
  return problems;
}

/** Every catalog invariant violation; empty means the catalog is consistent. */
export function catalogViolations(
  events: Readonly<Record<string, EventDef>> = EVENT_DEFS,
  tags: Readonly<Record<string, TagDef>> = TAG_DEFS,
): string[] {
  const problems = checkTagVocabulary(tags);
  const sloLabels = new Map<string, string>();
  for (const [name, event] of Object.entries(events)) {
    problems.push(...checkEvent(tags, name, event));
    for (const slo of event.slo ?? []) {
      const previous = sloLabels.get(slo.label);
      if (previous) problems.push(`SLO label "${slo.label}" is used by ${previous} and ${name}`);
      sloLabels.set(slo.label, name);
    }
  }
  const used = new Set(Object.values(events).flatMap((event) => Object.keys(event.tags ?? {})));
  for (const key of Object.keys(tags)) {
    if (!used.has(key)) problems.push(`tag "${key}" is in the vocabulary but no event uses it`);
  }
  return problems;
}

function generatedSwiftViolations(): string[] {
  let current = "";
  try {
    current = readFileSync(GENERATED_SWIFT_PATH, "utf8");
  } catch {
    return [`${GENERATED_SWIFT_PATH} is missing`];
  }
  return current === generateSwift()
    ? []
    : [
        "TelemetryCatalog.generated.swift is stale. Run: bun server/scripts/generate-telemetry-catalog.ts",
      ];
}

function generatedDocsViolations(): string[] {
  const page = readFileSync(DOCS_PATH, "utf8");
  const next = withGeneratedTables(page);
  if (next === null) return [`${DOCS_PATH} is missing the telemetry-catalog begin/end markers`];
  return next === page
    ? []
    : [
        "dev/telemetry.md event tables are stale. Run: bun server/scripts/generate-telemetry-docs.ts",
      ];
}

// ── Dashboards, alert rules, importer, review script ──

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const DASHBOARD_DIR = join(serverRoot, "docker/grafana/dashboards");
const ALERT_RULES_PATH = join(serverRoot, "docker/grafana/provisioning/alerting/alert-rules.yml");
const IMPORTER_PATH = join(serverRoot, "scripts/manual/telemetry-import-sqlite.mjs");
const REVIEW_SCRIPT_PATH = join(serverRoot, "scripts/telemetry-review.ts");

const JSON_KEY = /json_extract\(\s*(fields_json|tags_json)\s*,\s*'\$\.([A-Za-z0-9_]+)'\s*\)/g;
const NAME_EQUALS = /\bname\s*(?:=|!=|<>)\s*'([^']*)'/g;
const NAME_IN = /\bname\s+(?:NOT\s+)?IN\s*\(([^)]*)\)/gi;
const TAG_READ = String.raw`json_extract\(\s*tags_json\s*,\s*'\$\.(?<key>[A-Za-z0-9_]+)'\s*\)`;
/** What closes a COALESCE/NULLIF/TRIM around a tag read: parentheses and default literals. */
const TAG_WRAPPER = String.raw`(?:\s*(?:\)|,\s*'[^']*'|,\s*\d+))*`;
/** Function calls that open a wrapped tag read: `COALESCE(NULLIF(TRIM(json_extract(...` */
const FUNCTION_OPENERS = String.raw`(?:[A-Za-z_]+\(\s*)*`;
const COMPARISON = String.raw`\s*(?<op>=|!=|<>|NOT\s+IN|IN|NOT\s+LIKE|LIKE)\s*(?<lits>\([^)]*\)|'[^']*')`;
/** `<tag read> [AS] alias`: a CTE or subquery column that carries a tag under another name. */
const TAG_ALIAS = new RegExp(
  `${TAG_READ}(?<wrapper>${TAG_WRAPPER})\\s+(?:AS\\s+)?(?<alias>[A-Za-z_][A-Za-z0-9_]*)`,
  "gi",
);
/** Words that can follow a tag read and are not a column alias. */
const NOT_ALIASES = new Set(
  `select from where and or not in is like glob regexp match between group order by having limit offset
  union intersect except then else end when case as asc desc null on join left right inner outer cross
  using window over filter collate escape isnull notnull cast within returning`.split(/\s+/),
);

const quoted = (text: string): string[] => [...text.matchAll(/'([^']*)'/g)].map((m) => m[1]!);

/** Tag values the catalog allows for `key` on `event`; undefined when any value is allowed. */
function tagValues(
  tags: Readonly<Record<string, TagDef>>,
  event: EventDef,
  key: string,
): readonly string[] | undefined {
  return allowedValues(tags, event, key);
}

/**
 * Violations of one SQL text: unknown events, field or tag keys the named
 * events do not carry, and tag literals the catalog does not allow.
 */
export function sqlCatalogViolations(
  where: string,
  sql: string,
  events: Readonly<Record<string, EventDef>> = EVENT_DEFS,
  tags: Readonly<Record<string, TagDef>> = TAG_DEFS,
): string[] {
  const problems: string[] = [];
  const named = new Set<string>();
  for (const match of sql.matchAll(NAME_EQUALS)) named.add(match[1]!);
  for (const match of sql.matchAll(NAME_IN))
    for (const value of quoted(match[1]!)) named.add(value);

  const known: Array<[string, EventDef]> = [];
  for (const name of named) {
    const event = Object.hasOwn(events, name) ? events[name] : undefined;
    if (event) known.push([name, event]);
    else problems.push(`${where}: event "${name}" is not in the catalog`);
  }
  const eventList = [...named].join(", ");

  for (const match of sql.matchAll(JSON_KEY)) {
    const [, column, key] = match;
    const carried = known.some(([, event]) =>
      column === "fields_json" ? key! in event.fields : key! in (event.tags ?? {}),
    );
    if (known.length === 0 && named.size === 0) {
      problems.push(`${where}: reads ${column} "${key}" without naming an event`);
    } else if (!carried && known.length > 0) {
      problems.push(
        `${where}: ${column === "fields_json" ? "field" : "tag"} "${key}" is not carried by ${eventList}`,
      );
    }
  }

  for (const { key, operator, literals, synthetic } of tagComparisons(sql)) {
    const carriers = known.filter(([, event]) => key in (event.tags ?? {}));
    if (carriers.length === 0) continue; // already reported as an unknown tag key
    const perEvent = carriers.map(([, event]) => tagValues(tags, event, key));
    if (perEvent.some((values) => values === undefined)) continue; // open vocabulary
    const allowed = [...new Set(perEvent.flatMap((values) => values!))];
    for (const literal of literals) {
      if (synthetic.includes(literal)) continue;
      const matches = /LIKE$/i.test(operator)
        ? allowed.some((value) => likeMatches(literal, value))
        : allowed.includes(literal);
      if (!matches) {
        problems.push(
          `${where}: tag "${key}" is compared with "${literal}", which ${eventList} never has`,
        );
      }
    }
  }
  return problems;
}

interface TagComparison {
  key: string;
  operator: string;
  literals: string[];
  /** Default literals the query itself puts in the column (`COALESCE(<tag>, 'untagged') AS runtime`). */
  synthetic: string[];
}

/** SQLite `LIKE` (case-insensitive for ASCII; `%` any run, `_` one character) against one value. */
function likeMatches(pattern: string, value: string): boolean {
  const source = [...pattern]
    .map((char) =>
      char === "%" ? ".*" : char === "_" ? "." : char.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"),
    )
    .join("");
  return new RegExp(`^${source}$`, "is").test(value);
}

/**
 * A way SQL names a tag: the `json_extract` read itself (possibly wrapped in
 * COALESCE/NULLIF/TRIM), or an alias a CTE or subquery gave it.
 */
interface Operand {
  source: string;
  keyOf: (groups: Record<string, string | undefined>) => string;
  synthetic: string[];
}

/**
 * Every comparison of a tag with literals, however the SQL names the tag:
 *   - `<tag> = 'x'`, `<tag> IN ('x', 'y')`, `<tag> LIKE 'x%'`;
 *   - `'x' = <tag>` (literal on the left);
 *   - `CASE <tag> WHEN 'x' THEN ... WHEN 'y' THEN ... END`;
 * where `<tag>` is `json_extract(tags_json, '$.k')` or an alias
 * (`json_extract(...) AS k`, or the same without `AS`) used in a later
 * `WHERE k = 'x'` or `CASE WHEN k IN (...)`. An alias that names two different
 * tags in one text is ambiguous and skipped.
 */
function tagComparisons(sql: string): TagComparison[] {
  const operands: Operand[] = [
    {
      source: `${FUNCTION_OPENERS}${TAG_READ}${TAG_WRAPPER}`,
      keyOf: (groups) => groups.key!,
      synthetic: [],
    },
  ];

  const aliasKeys = new Map<string, Set<string>>();
  const aliasDefaults = new Map<string, string[]>();
  for (const match of sql.matchAll(TAG_ALIAS)) {
    const alias = match.groups!.alias!.toLowerCase();
    if (NOT_ALIASES.has(alias)) continue;
    const keys = aliasKeys.get(alias) ?? new Set<string>();
    keys.add(match.groups!.key!);
    aliasKeys.set(alias, keys);
    aliasDefaults.set(alias, [
      ...(aliasDefaults.get(alias) ?? []),
      ...quoted(match.groups!.wrapper ?? ""),
    ]);
  }
  for (const [alias, keys] of aliasKeys) {
    if (keys.size !== 1) continue;
    const [key] = [...keys];
    operands.push({
      source: `(?<![A-Za-z0-9_'"$.])(?:[A-Za-z_][A-Za-z0-9_]*\\.)?${alias}\\b`,
      keyOf: () => key!,
      synthetic: aliasDefaults.get(alias) ?? [],
    });
  }

  const found: TagComparison[] = [];
  for (const operand of operands) {
    const add = (
      groups: Record<string, string | undefined>,
      operator: string,
      literals: string[],
    ): void => {
      found.push({ key: operand.keyOf(groups), operator, literals, synthetic: operand.synthetic });
    };

    for (const match of sql.matchAll(new RegExp(`${operand.source}${COMPARISON}`, "gi"))) {
      add(match.groups ?? {}, match.groups!.op!, quoted(match.groups!.lits!));
    }

    for (const match of sql.matchAll(
      new RegExp(`'(?<lit>[^']*)'\\s*(?<op>=|!=|<>)\\s*${operand.source}`, "gi"),
    )) {
      add(match.groups ?? {}, match.groups!.op!, [match.groups!.lit!]);
    }

    for (const match of sql.matchAll(new RegExp(`\\bCASE\\s+${operand.source}`, "gi"))) {
      const rest = sql.slice(match.index + match[0].length);
      const end = rest.search(/\bEND\b/i);
      const span = end === -1 ? rest : rest.slice(0, end);
      const literals = [...span.matchAll(/\bWHEN\s+'([^']*)'/gi)].map((m) => m[1]!);
      if (literals.length > 0) add(match.groups ?? {}, "=", literals);
    }
  }
  return found;
}

interface SqlSource {
  where: string;
  sql: string;
}

/** Every SQL text of a dashboard: panel targets (nested rows included) and template variables. */
export function dashboardSql(file: string, dashboard: unknown): SqlSource[] {
  const found: SqlSource[] = [];
  const visit = (panels: unknown[]): void => {
    for (const panel of panels as Array<Record<string, unknown>>) {
      for (const target of (panel.targets as Array<Record<string, unknown>> | undefined) ?? []) {
        for (const key of ["rawQueryText", "queryText"]) {
          if (typeof target[key] === "string") {
            found.push({
              where: `${file}: "${String(panel.title ?? "")}" [${String(target.refId ?? "?")}] ${key}`,
              sql: target[key] as string,
            });
          }
        }
      }
      if (Array.isArray(panel.panels)) visit(panel.panels);
    }
  };
  const root = dashboard as {
    panels?: unknown[];
    templating?: { list?: Array<Record<string, unknown>> };
  };
  visit(root.panels ?? []);
  for (const variable of root.templating?.list ?? []) {
    for (const key of ["query", "definition"]) {
      if (typeof variable[key] === "string") {
        found.push({
          where: `${file}: variable "${String(variable.name)}" ${key}`,
          sql: variable[key] as string,
        });
      }
    }
  }
  return found;
}

/** `rawQueryText: >-` blocks of the provisioned alert rules (no YAML dependency: the blocks are indented text). */
export function alertRuleSql(file: string, yaml: string): SqlSource[] {
  const found: SqlSource[] = [];
  const lines = yaml.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const header = /^(\s*)rawQueryText:\s*>-?\s*$/.exec(lines[i]!);
    if (!header) continue;
    const indent = header[1]!.length;
    const body: string[] = [];
    for (let j = i + 1; j < lines.length; j += 1) {
      const line = lines[j]!;
      if (line.trim() !== "" && line.length - line.trimStart().length <= indent) break;
      body.push(line.trim());
    }
    found.push({ where: `${file}: alert query at line ${i + 1}`, sql: body.join(" ") });
  }
  return found;
}

/** Grafana macros and variables replaced by plain values so SQLite can prepare the text. */
function expandForPrepare(sql: string): string {
  return sql
    .replace(/\$\{[A-Za-z_]+:sqlstring\}/g, "'x'")
    .replace(/\$\{[A-Za-z_]+:csv\}/g, "x")
    .replace(/\$\{?__(?:from|to|interval_ms)\}?/g, "1000");
}

/** Schema as the importer builds it: run it once against an empty directory. */
function importerSchemaDb(): { db: DatabaseSync; cleanup: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "oppi-check-telemetry-"));
  const dbPath = join(dir, "telemetry.db");
  execFileSync(
    process.execPath,
    [
      IMPORTER_PATH,
      "--telemetry-dir",
      join(dir, "empty"),
      "--db",
      dbPath,
      "--integrity-check",
      "never",
    ],
    { stdio: "pipe" },
  );
  const db = new DatabaseSync(dbPath);
  return {
    db,
    cleanup: () => {
      db.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/** SQL texts that SQLite cannot prepare against the importer's schema (unknown table or column, syntax). */
export function sqlPrepareViolations(sources: readonly SqlSource[]): string[] {
  const { db, cleanup } = importerSchemaDb();
  try {
    const problems: string[] = [];
    for (const source of sources) {
      try {
        db.prepare(expandForPrepare(source.sql));
      } catch (err) {
        problems.push(`${source.where}: ${err instanceof Error ? err.message : String(err)}`);
      }
    }
    return problems;
  } finally {
    cleanup();
  }
}

export function dashboardViolations(): string[] {
  const sources: SqlSource[] = [];
  for (const file of readdirSync(DASHBOARD_DIR)
    .filter((name) => name.endsWith(".json"))
    .sort()) {
    sources.push(
      ...dashboardSql(file, JSON.parse(readFileSync(join(DASHBOARD_DIR, file), "utf8"))),
    );
  }
  sources.push(...alertRuleSql("alert-rules.yml", readFileSync(ALERT_RULES_PATH, "utf8")));
  if (sources.length === 0) return ["no dashboard or alert SQL found"];
  return [
    ...sources.flatMap((source) => sqlCatalogViolations(source.where, source.sql)),
    ...sqlPrepareViolations(sources),
  ];
}

const SERIES_LITERAL = /"((?:app|server)\.[a-z0-9_]+)(?:\.([a-z0-9_]+))?"/g;

/** Event and `<event>.<field>` string literals of a script must exist in the catalog. */
export function seriesLiteralViolations(
  where: string,
  source: string,
  events: Readonly<Record<string, EventDef>> = EVENT_DEFS,
): string[] {
  const problems: string[] = [];
  for (const match of source.matchAll(SERIES_LITERAL)) {
    const [literal, name, field] = match;
    const event = Object.hasOwn(events, name!) ? events[name!] : undefined;
    if (!event) problems.push(`${where}: ${literal} names an event the catalog does not have`);
    else if (field !== undefined && !(field in event.fields)) {
      problems.push(`${where}: ${literal} names a field ${name} does not have`);
    }
  }
  return problems;
}

function reviewScriptViolations(): string[] {
  return seriesLiteralViolations("telemetry-review.ts", readFileSync(REVIEW_SCRIPT_PATH, "utf8"));
}

function importerViolations(): string[] {
  const source = readFileSync(IMPORTER_PATH, "utf8");
  const problems: string[] = [];
  for (const origin of ["app", "server"] as const) {
    const prefix = telemetryEventFileName(origin, 0).replace(/\d{4}-\d{2}-\d{2}\.jsonl$/, "");
    if (!source.includes(`startsWith("${prefix}")`)) {
      problems.push(`importer does not read ${origin} event files (prefix "${prefix}")`);
    }
  }
  return problems;
}

const CHECKS: Check[] = [
  { name: "catalog", run: () => catalogViolations() },
  { name: "generated-swift", run: generatedSwiftViolations },
  { name: "generated-docs", run: generatedDocsViolations },
  { name: "dashboards", run: dashboardViolations },
  { name: "review-script", run: reviewScriptViolations },
  { name: "importer", run: importerViolations },
];

function main(): void {
  let failed = false;
  for (const check of CHECKS) {
    let problems: string[];
    try {
      problems = check.run();
    } catch (err) {
      problems = [err instanceof Error ? err.message : String(err)];
    }
    for (const problem of problems) console.error(`telemetry ${check.name}: ${problem}`);
    if (problems.length > 0) failed = true;
  }
  if (failed) process.exit(1);
  console.log(`telemetry: ${CHECKS.map((check) => check.name).join(", ")} ok`);
}

if (import.meta.main) {
  main();
}
