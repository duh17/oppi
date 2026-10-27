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
 *
 * Extension point: add a `Check` to `CHECKS` for each further consumer. The
 * Grafana dashboards and importer SQL (every event, field, tag key, and tag
 * literal they reference exists in the catalog) and the generated event tables
 * in `dev/telemetry.md` belong here.
 */

import { readFileSync } from "node:fs";

import {
  EVENT_DEFS,
  TAG_DEFS,
  eventOrigin,
  fieldSpec,
  type EventDef,
  type FieldUnit,
  type TagDef,
} from "../src/telemetry/catalog.ts";
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

const CHECKS: Check[] = [
  { name: "catalog", run: () => catalogViolations() },
  { name: "generated-swift", run: generatedSwiftViolations },
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
