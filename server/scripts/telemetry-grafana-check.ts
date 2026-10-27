#!/usr/bin/env bun

/**
 * Live dashboard check: run every panel query of the provisioned dashboards
 * against a running Grafana and report errors and empty panels. A dev tool, not
 * part of `npm run check`; `check-telemetry.ts` is the static counterpart.
 *
 *   cd server && npm run telemetry:grafana:check
 *   npm run telemetry:grafana:check -- --days 14 oppi-server-health
 *
 * Template variables are resolved the way Grafana would, in dashboard order, so
 * chained variables (`${route}` built from `${provider:sqlstring}`) work: a query
 * variable runs its own SQL and takes every value (the dropdowns default to All),
 * a custom variable takes its options. `$__from`, `$__to`, and `$__interval_ms`
 * expand to the selected window and a one-minute interval.
 *
 * Exit code: 1 when any query errors or Grafana cannot be read; empty panels do
 * not fail the run, they are listed separately for a human to judge (an empty
 * panel is right when the source has no such events).
 *
 * Environment (defaults match docker-compose.telemetry.yml):
 *   OPPI_GRAFANA_URL             default http://localhost:${OPPI_GRAFANA_PORT:-13001}
 *   OPPI_GRAFANA_ADMIN_USER      default admin
 *   OPPI_GRAFANA_ADMIN_PASSWORD  default admin
 */

const DATASOURCE = { uid: "oppi-telemetry-sqlite", type: "frser-sqlite-datasource" };
const DEFAULT_UIDS = ["oppi-release-preflight", "oppi-server-health", "oppi-model-routing"];

interface Target {
  refId?: string;
  rawQueryText?: string;
  queryText?: string;
  queryType?: string;
  timeColumns?: string[];
}
interface Panel {
  title?: string;
  type?: string;
  targets?: Target[];
  panels?: Panel[];
}
interface TemplateVariable {
  name: string;
  type: string;
  query?: string | { rawQueryText?: string };
  options?: Array<{ value: string }>;
  current?: { value?: unknown };
}
interface Frame {
  data?: { values?: unknown[][] };
}
interface QueryResult {
  error?: string;
  frames?: Frame[];
}

function parseArgs(argv: string[]): { days: number; uids: string[] } {
  let days = 7;
  const uids: string[] = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]!;
    if (arg === "--days") {
      days = Number(argv[++i]);
      if (!(days > 0)) throw new Error(`Invalid --days: ${argv[i]}`);
    } else if (arg.startsWith("-")) {
      throw new Error(`Unknown argument: ${arg}`);
    } else uids.push(arg);
  }
  return { days, uids: uids.length > 0 ? uids : DEFAULT_UIDS };
}

const { days, uids } = parseArgs(process.argv.slice(2));
const baseUrl = (
  process.env.OPPI_GRAFANA_URL ?? `http://localhost:${process.env.OPPI_GRAFANA_PORT ?? "13001"}`
).replace(/\/+$/, "");
const credentials = `${process.env.OPPI_GRAFANA_ADMIN_USER ?? "admin"}:${process.env.OPPI_GRAFANA_ADMIN_PASSWORD ?? "admin"}`;
const headers = {
  Authorization: `Basic ${btoa(credentials)}`,
  "Content-Type": "application/json",
};
const to = Date.now();
const from = to - days * 86_400_000;

function flatten(panels: Panel[]): Panel[] {
  return panels.flatMap((panel) => [panel, ...flatten(panel.panels ?? [])]);
}

function expand(sql: string, variables: Record<string, string[]>): string {
  let out = sql
    .replaceAll("${__from}", String(from))
    .replaceAll("$__from", String(from))
    .replaceAll("${__to}", String(to))
    .replaceAll("$__to", String(to))
    .replaceAll("${__interval_ms}", "60000")
    .replaceAll("$__interval_ms", "60000");
  for (const [name, values] of Object.entries(variables)) {
    const quoted = values.map((value) => `'${value.replaceAll("'", "''")}'`).join(",");
    // Function replacers: a value containing `$&` must not be read as a pattern.
    out = out
      .replaceAll(`\${${name}:sqlstring}`, () => quoted)
      .replaceAll(`\${${name}:csv}`, () => values.join(","))
      .replaceAll(`\${${name}}`, () => values[0] ?? "")
      .replaceAll(`$${name}`, () => values[0] ?? "");
  }
  return out;
}

async function runQuery(sql: string, target: Target): Promise<QueryResult> {
  const response = await fetch(`${baseUrl}/api/ds/query`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      from: String(from),
      to: String(to),
      queries: [
        {
          refId: "A",
          datasource: DATASOURCE,
          queryType: target.queryType ?? "table",
          rawQueryText: sql,
          queryText: sql,
          timeColumns: target.timeColumns ?? [],
        },
      ],
    }),
  });
  const body = (await response.json()) as { results?: { A?: QueryResult }; message?: string };
  if (!response.ok && !body.results?.A) {
    return { error: `HTTP ${response.status}: ${body.message ?? "no body"}` };
  }
  return body.results?.A ?? { error: "no result for refId A" };
}

const rowCount = (result: QueryResult): number =>
  (result.frames ?? []).reduce((n, frame) => n + (frame.data?.values?.[0]?.length ?? 0), 0);

const eventNames = (sql: string): string =>
  [...new Set(sql.match(/'(?:app|server)\.[a-z_]+'/g) ?? [])].join(" ");

async function resolveVariables(list: TemplateVariable[]): Promise<Record<string, string[]>> {
  const variables: Record<string, string[]> = {};
  for (const variable of list) {
    let values: string[];
    if (variable.type === "query") {
      const raw =
        typeof variable.query === "string" ? variable.query : (variable.query?.rawQueryText ?? "");
      const result = await runQuery(expand(raw, variables), {});
      if (result.error) throw new Error(`template variable ${variable.name}: ${result.error}`);
      values = (result.frames?.[0]?.data?.values?.[0] ?? []).map(String);
    } else if (variable.type === "custom") {
      values = (variable.options ?? []).map((o) => o.value).filter((v) => v !== "$__all");
    } else {
      values = [String(variable.current?.value ?? "")];
    }
    variables[variable.name] = values.length > 0 ? values : ["__none__"];
  }
  return variables;
}

let errors = 0;
let empties = 0;
console.log(`Grafana ${baseUrl}, window ${days} d`);

for (const uid of uids) {
  const response = await fetch(`${baseUrl}/api/dashboards/uid/${uid}`, { headers });
  if (!response.ok) {
    console.log(`\n== ${uid}\n  ERR   cannot read dashboard: HTTP ${response.status}`);
    errors += 1;
    continue;
  }
  const { dashboard } = (await response.json()) as {
    dashboard: { title: string; panels?: Panel[]; templating?: { list?: TemplateVariable[] } };
  };

  let variables: Record<string, string[]>;
  try {
    variables = await resolveVariables(dashboard.templating?.list ?? []);
  } catch (err) {
    console.log(`\n== ${dashboard.title}\n  ERR   ${err instanceof Error ? err.message : err}`);
    errors += 1;
    continue;
  }

  let ok = 0;
  const failed: string[] = [];
  const empty: string[] = [];
  for (const panel of flatten(dashboard.panels ?? [])) {
    for (const target of panel.targets ?? []) {
      const raw = target.rawQueryText ?? target.queryText ?? "";
      if (!raw) continue;
      const label = `${panel.title ?? "(untitled)"}${target.refId ? ` [${target.refId}]` : ""}`;
      const result = await runQuery(expand(raw, variables), target);
      if (result.error) failed.push(`ERR   ${label}: ${String(result.error).slice(0, 200)}`);
      else if (rowCount(result) === 0) empty.push(`EMPTY ${label}  ${eventNames(raw)}`);
      else ok += 1;
    }
  }
  errors += failed.length;
  empties += empty.length;
  console.log(`\n== ${dashboard.title}: ok=${ok} errors=${failed.length} empty=${empty.length}`);
  for (const line of failed) console.log(`  ${line}`);
  for (const line of empty) console.log(`  ${line}`);
}

console.log(`\n${errors} query errors, ${empties} empty panels`);
process.exit(errors > 0 ? 1 : 0);
