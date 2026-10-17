import { Type } from "typebox";
import {
  defineExtension,
  defineTool,
  type ToolExecutionApi,
  type ToolExecutionResult,
} from "@earendil-works/pi-durable";
import type { Context, JsonValue } from "@earendil-works/chord";
import { DurableUI } from "oppi/durable";

const QUERY_TIMEOUT_SECONDS = 15;
const QUERY_OUTPUT_MAX_BYTES = 256 * 1024;
const WIDGET_MAX_ROWS = 200;
const WIDGET_MAX_COLUMNS = 32;
const WIDGET_MAX_CELL_CHARS = 200;
const CHART_MAX_LABELS = 48;
const CHART_MAX_SERIES = 8;
const MODEL_PREVIEW_ROWS = 12;
const WIDGET_KEY = "data";
const WIDGET_SLOT = "widget:data";
const SCHEMA_SQL = "SELECT name, type, sql FROM sqlite_schema ORDER BY type, name";
const SQLITE3 = "sqlite3";
const SQLITE_ARGV = [SQLITE3, "-readonly", "-safe", "-noinit", "-json"] as const;
const PROVENANCE = {
  extensionScopeId: "repo:sql-explorer",
  extensionDisplayName: "Data",
} as const;

type Cell = string | number | null;
type ChartKind = "bar" | "line" | "pie";
type ChartSpec = { kind: ChartKind; title?: string };
type TableBlock = {
  type: "table";
  id: string;
  columns: string[];
  rows: Cell[][];
  truncated?: boolean;
};
type ChartBlock = {
  type: "chart";
  id: string;
  kind: ChartKind;
  title?: string;
  labels: string[];
  series: Array<{ name?: string; values: number[] }>;
  truncated?: boolean;
};

function fileName(path: string): string {
  const trimmed = path.replace(/[/\\]+$/, "");
  const slash = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return (slash >= 0 ? trimmed.slice(slash + 1) : trimmed) || path;
}

function clipCell(value: Cell): Cell {
  if (typeof value !== "string") return value;
  return value.length > WIDGET_MAX_CELL_CHARS ? value.slice(0, WIDGET_MAX_CELL_CHARS) : value;
}

function cellText(value: Cell): string {
  if (value === null) return "";
  return typeof value === "number" ? String(value) : value;
}

/** True when `sql` has a second statement after a non-trailing semicolon. */
function hasMultipleStatements(sql: string): boolean {
  let i = 0;
  let seen = false;
  let ended = false;
  const skipUntil = (pred: (ch: string) => boolean): void => {
    while (i < sql.length) {
      const next = sql[i];
      if (next === undefined || pred(next)) break;
      i += 1;
    }
  };
  while (i < sql.length) {
    const ch = sql[i];
    if (ch === undefined) break;
    if (ch === "'" || ch === '"' || ch === "`") {
      const quote = ch;
      i += 1;
      while (i < sql.length) {
        if (sql[i] === quote) {
          if (sql[i + 1] === quote) {
            i += 2;
            continue;
          }
          i += 1;
          break;
        }
        i += 1;
      }
      seen = true;
      ended = false;
      continue;
    }
    if (ch === "[") {
      i += 1;
      skipUntil((next) => next === "]");
      if (i < sql.length) i += 1;
      seen = true;
      ended = false;
      continue;
    }
    if (ch === "-" && sql[i + 1] === "-") {
      skipUntil((next) => next === "\n");
      continue;
    }
    if (ch === "/" && sql[i + 1] === "*") {
      i += 2;
      while (i < sql.length && !(sql[i] === "*" && sql[i + 1] === "/")) i += 1;
      i = Math.min(i + 2, sql.length);
      continue;
    }
    if (ch === ";") {
      ended = true;
      i += 1;
      continue;
    }
    if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") {
      i += 1;
      continue;
    }
    if (ended && seen) return true;
    seen = true;
    ended = false;
    i += 1;
  }
  return false;
}

const MALFORMED_SQLITE_JSON = "sqlite3 JSON output is malformed.";

class SqliteJsonScanError extends Error {
  override name = "SqliteJsonScanError";
}

function failSqliteJson(message = MALFORMED_SQLITE_JSON): never {
  throw new SqliteJsonScanError(message);
}

function isJsonWs(ch: string | undefined): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r";
}

function isDigit(ch: string | undefined): boolean {
  return ch !== undefined && ch >= "0" && ch <= "9";
}

function jsonValueStarts(ch: string | undefined): boolean {
  return (
    ch === "{" ||
    ch === "[" ||
    ch === '"' ||
    ch === "-" ||
    ch === "t" ||
    ch === "f" ||
    ch === "n" ||
    isDigit(ch)
  );
}

export type SqliteJsonParse =
  { ok: true; columns: string[]; rows: Cell[][] } | { ok: false; error: string };

/** Ordered sqlite3 -json scanner: duplicate keys stay columns; number tokens stay source text. */
export function parseSqliteJson(text: string): SqliteJsonParse {
  try {
    return { ok: true, ...scanSqliteJson(text) };
  } catch (caught) {
    if (caught instanceof SqliteJsonScanError) return { ok: false, error: caught.message };
    throw caught;
  }
}

function scanSqliteJson(text: string): { columns: string[]; rows: Cell[][] } {
  let i = 0;
  const skipWs = (): void => {
    while (isJsonWs(text[i])) i += 1;
  };
  const peek = (): string | undefined => text[i];
  const eat = (expected: string): void => {
    if (text[i] !== expected) failSqliteJson();
    i += 1;
  };
  const parseString = (): string => {
    eat('"');
    let out = "";
    while (i < text.length) {
      const ch = text[i];
      if (ch === undefined) break;
      if (ch === '"') {
        i += 1;
        return out;
      }
      if (ch === "\\") {
        i += 1;
        const esc = text[i];
        if (esc === undefined) failSqliteJson();
        i += 1;
        switch (esc) {
          case '"':
          case "\\":
          case "/":
            out += esc;
            break;
          case "b":
            out += "\b";
            break;
          case "f":
            out += "\f";
            break;
          case "n":
            out += "\n";
            break;
          case "r":
            out += "\r";
            break;
          case "t":
            out += "\t";
            break;
          case "u": {
            const hex = text.slice(i, i + 4);
            if (hex.length < 4 || !/^[0-9a-fA-F]{4}$/.test(hex)) failSqliteJson();
            out += String.fromCharCode(Number.parseInt(hex, 16));
            i += 4;
            break;
          }
          default:
            failSqliteJson();
        }
        continue;
      }
      if (ch.charCodeAt(0) < 0x20) failSqliteJson();
      out += ch;
      i += 1;
    }
    failSqliteJson();
  };
  const isValueDelim = (ch: string | undefined): boolean =>
    ch === "," || ch === "}" || ch === "]" || isJsonWs(ch);
  const takeInf = (): boolean => {
    if (text.startsWith("Inf", i) && isValueDelim(text[i + 3])) {
      i += 3;
      return true;
    }
    return false;
  };
  const parseNumber = (): string => {
    const start = i;
    if (peek() === "-") i += 1;
    if (takeInf()) return text.slice(start, i);
    const lead = peek();
    if (lead === "0") {
      i += 1;
    } else if (lead !== undefined && lead >= "1" && lead <= "9") {
      while (isDigit(text[i])) i += 1;
    } else {
      failSqliteJson();
    }
    if (peek() === ".") {
      i += 1;
      if (!isDigit(peek())) failSqliteJson();
      while (isDigit(text[i])) i += 1;
    }
    const exp = peek();
    if (exp === "e" || exp === "E") {
      i += 1;
      if (peek() === "+" || peek() === "-") i += 1;
      if (!isDigit(peek())) failSqliteJson();
      while (isDigit(text[i])) i += 1;
    }
    return text.slice(start, i);
  };
  const parseNull = (): null => {
    if (text.slice(i, i + 4) !== "null") failSqliteJson();
    i += 4;
    return null;
  };
  const parseValue = (): Cell => {
    skipWs();
    const ch = peek();
    if (ch === '"') return parseString();
    if (ch === "I") {
      if (takeInf()) return "Inf";
      failSqliteJson();
    }
    if (ch === "-" || isDigit(ch)) return parseNumber();
    if (ch === "n") return parseNull();
    failSqliteJson();
  };
  const parseObject = (): Array<{ key: string; value: Cell }> => {
    eat("{");
    skipWs();
    const pairs: Array<{ key: string; value: Cell }> = [];
    if (peek() === "}") {
      i += 1;
      return pairs;
    }
    while (i < text.length) {
      skipWs();
      if (peek() !== '"') failSqliteJson();
      const key = parseString();
      skipWs();
      eat(":");
      pairs.push({ key, value: parseValue() });
      skipWs();
      const sep = peek();
      if (sep === ",") {
        i += 1;
        continue;
      }
      if (sep === "}") {
        i += 1;
        return pairs;
      }
      failSqliteJson();
    }
    failSqliteJson();
  };
  const parseArray = (): Array<Array<{ key: string; value: Cell }>> => {
    eat("[");
    skipWs();
    const objects: Array<Array<{ key: string; value: Cell }>> = [];
    if (peek() === "]") {
      i += 1;
      return objects;
    }
    while (i < text.length) {
      skipWs();
      if (peek() !== "{") failSqliteJson();
      objects.push(parseObject());
      skipWs();
      const sep = peek();
      if (sep === ",") {
        i += 1;
        continue;
      }
      if (sep === "]") {
        i += 1;
        return objects;
      }
      failSqliteJson();
    }
    failSqliteJson();
  };

  skipWs();
  if (i >= text.length) return { columns: [], rows: [] };
  if (peek() !== "[") failSqliteJson();
  const objects = parseArray();
  skipWs();
  if (i < text.length) {
    if (jsonValueStarts(peek())) failSqliteJson("Run one statement per query.");
    failSqliteJson();
  }
  const first = objects[0];
  if (!first) return { columns: [], rows: [] };
  const columns = first.map((pair) => pair.key);
  const rows = objects.map((object) => {
    if (object.length !== columns.length) failSqliteJson();
    return object.map((pair) => pair.value);
  });
  return { columns, rows };
}

function clipTable(
  columns: string[],
  rows: Cell[][],
): { columns: string[]; rows: Cell[][]; truncated: boolean } {
  let truncated = false;
  let nextColumns = columns.map((column) => {
    const clipped = clipCell(column);
    if (clipped !== column) truncated = true;
    return typeof clipped === "string" ? clipped : String(column);
  });
  if (nextColumns.length > WIDGET_MAX_COLUMNS) {
    nextColumns = nextColumns.slice(0, WIDGET_MAX_COLUMNS);
    truncated = true;
  }
  let nextRows = rows.map((row) => {
    const clipped = nextColumns.map((_, index) => {
      const cell = clipCell(row[index] ?? null);
      if (typeof row[index] === "string" && cell !== row[index]) truncated = true;
      return cell;
    });
    if (row.length > nextColumns.length) truncated = true;
    return clipped;
  });
  if (nextRows.length > WIDGET_MAX_ROWS) {
    nextRows = nextRows.slice(0, WIDGET_MAX_ROWS);
    truncated = true;
  }
  return { columns: nextColumns, rows: nextRows, truncated };
}

/** Integers that do not round-trip through JS number stay out of charts. */
function exactNumber(value: string): number | undefined {
  const trimmed = value.trim();
  if (trimmed === "") return undefined;
  if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(trimmed)) return undefined;
  const n = Number(trimmed);
  if (!Number.isFinite(n)) return undefined;
  if (/^[+-]?\d+$/.test(trimmed)) {
    try {
      if (BigInt(trimmed) !== BigInt(n)) return undefined;
    } catch {
      return undefined;
    }
  }
  return n;
}

function chartFrom(spec: ChartSpec, columns: string[], rows: Cell[][]): ChartBlock | undefined {
  if (rows.length === 0 || columns.length === 0) return undefined;
  const numericIndexes = columns.flatMap((_, index) => {
    let sawNumber = false;
    for (const row of rows) {
      const cell = row[index];
      if (cell === null) continue;
      const text = cellText(cell);
      if (text === "") continue;
      const n = exactNumber(text);
      if (n === undefined) return [];
      sawNumber = true;
    }
    return sawNumber ? [index] : [];
  });
  const labelIndex = columns.findIndex((_, index) => !numericIndexes.includes(index));
  const resolvedLabel = labelIndex >= 0 ? labelIndex : 0;
  const valueIndexes = numericIndexes.filter((index) => index !== resolvedLabel);
  if (valueIndexes.length === 0) return undefined;

  let truncated = rows.length > CHART_MAX_LABELS || valueIndexes.length > CHART_MAX_SERIES;
  const usedRows = rows.slice(0, CHART_MAX_LABELS);
  const usedIndexes = valueIndexes.slice(0, spec.kind === "pie" ? 1 : CHART_MAX_SERIES);
  const labels = usedRows.map((row) => {
    const text = cellText(row[resolvedLabel] ?? null);
    if (text.length > WIDGET_MAX_CELL_CHARS) {
      truncated = true;
      return text.slice(0, WIDGET_MAX_CELL_CHARS);
    }
    return text;
  });
  const series = usedIndexes.map((index) => ({
    name: columns[index],
    values: usedRows.map((row) => {
      const cell = row[index];
      if (cell === null) return 0;
      return exactNumber(cellText(cell)) ?? 0;
    }),
  }));
  const block: ChartBlock = {
    type: "chart",
    id: "chart",
    kind: spec.kind,
    labels,
    series,
  };
  if (spec.title) block.title = spec.title;
  if (truncated) block.truncated = true;
  return block;
}

function formatPreview(
  columns: string[],
  rows: Cell[][],
  truncated: boolean,
  extra: string[],
): string {
  const lines = [...extra];
  if (columns.length > 0) {
    lines.push(columns.join(" | "));
    for (const row of rows.slice(0, MODEL_PREVIEW_ROWS)) {
      lines.push(row.map(cellText).join(" | "));
    }
    if (rows.length > MODEL_PREVIEW_ROWS) {
      lines.push(`… ${rows.length - MODEL_PREVIEW_ROWS} more row(s)`);
    }
  }
  if (truncated) lines.push("Result truncated.");
  return lines.join("\n");
}

function missingSqliteMessage(message: string): boolean {
  const lower = message.toLowerCase();
  return (
    lower.includes("enoent") ||
    lower.includes("not found") ||
    lower.includes("no such program") ||
    lower.includes("cannot find")
  );
}

async function runSqlite(
  api: ToolExecutionApi,
  path: string,
  sql: string,
  context: Context,
): Promise<{ stdout: string; stderr: string; error?: string; elapsedMs: number }> {
  const env = api.env;
  if (!env)
    return {
      stdout: "",
      stderr: "",
      error: "No execution environment is available.",
      elapsedMs: 0,
    };
  const trimmedPath = path.trim();
  const trimmedSql = sql.trim();
  if (!trimmedPath) return { stdout: "", stderr: "", error: "path is required.", elapsedMs: 0 };
  if (!trimmedSql) return { stdout: "", stderr: "", error: "sql is required.", elapsedMs: 0 };
  if (hasMultipleStatements(trimmedSql)) {
    return { stdout: "", stderr: "", error: "Run one statement per query.", elapsedMs: 0 };
  }

  let stdout = "";
  let stderr = "";
  let truncated = false;
  const started = Date.now();
  const result = await env.exec(
    [...SQLITE_ARGV, "--", trimmedPath, trimmedSql],
    {
      timeout: QUERY_TIMEOUT_SECONDS,
      onOutput: (text, _ctx, info) => {
        if (truncated) return;
        const target = info.stream === "stderr" ? "stderr" : "stdout";
        const current = target === "stderr" ? stderr : stdout;
        const next =
          current.length + text.length > QUERY_OUTPUT_MAX_BYTES
            ? current + text.slice(0, Math.max(0, QUERY_OUTPUT_MAX_BYTES - current.length))
            : current + text;
        if (target === "stderr") stderr = next;
        else stdout = next;
        if (current.length + text.length > QUERY_OUTPUT_MAX_BYTES) truncated = true;
      },
    },
    context,
  );
  const elapsedMs = Date.now() - started;
  if (!result.ok) {
    const message = result.error.message;
    if (result.error.code === "timeout") {
      return {
        stdout,
        stderr,
        error: `sqlite3 timed out after ${QUERY_TIMEOUT_SECONDS}s.`,
        elapsedMs,
      };
    }
    if (result.error.code === "shell_unavailable" || missingSqliteMessage(message)) {
      return {
        stdout,
        stderr,
        error: `sqlite3 is not available in this environment. ${message}`,
        elapsedMs,
      };
    }
    return { stdout, stderr, error: message, elapsedMs };
  }
  if (result.value.exitCode !== 0) {
    const detail = stderr.trim() || stdout.trim() || `sqlite3 exited ${result.value.exitCode}`;
    return { stdout, stderr, error: detail, elapsedMs };
  }
  if (truncated) {
    return {
      stdout,
      stderr,
      error: `Query output exceeded ${QUERY_OUTPUT_MAX_BYTES} bytes and was truncated.`,
      elapsedMs,
    };
  }
  return { stdout, stderr, elapsedMs };
}

function tableFrom(
  columns: string[],
  rows: Cell[][],
): { columns: string[]; rows: Cell[][]; table: TableBlock } {
  const clipped = clipTable(columns, rows);
  const table: TableBlock = {
    type: "table",
    id: "result",
    columns: clipped.columns,
    rows: clipped.rows,
  };
  if (clipped.truncated) table.truncated = true;
  return { columns: clipped.columns, rows: clipped.rows, table };
}

async function publish(
  api: ToolExecutionApi,
  context: Context,
  path: string,
  table: TableBlock,
  elapsedMs: number,
  chart?: ChartBlock,
): Promise<void> {
  const title = fileName(path);
  const subtitle = `${table.rows.length} row${table.rows.length === 1 ? "" : "s"} · ${elapsedMs}ms`;
  const fallback = [
    title,
    subtitle,
    table.columns.join(" | "),
    ...table.rows.slice(0, 8).map((row) => row.map(cellText).join(" | ")),
  ];
  const blocks: JsonValue[] = [table as unknown as JsonValue];
  if (chart) blocks.push(chart as unknown as JsonValue);
  await api.commit(async (tx) => {
    const ui = await tx.doc(DurableUI, api.conversationId);
    ui.notifications[WIDGET_SLOT] = {
      id: "sql-explorer:data",
      method: "setWidget",
      widgetKey: WIDGET_KEY,
      widgetLines: fallback,
      ...PROVENANCE,
      nativeSurface: {
        version: 1,
        id: `widget:${WIDGET_KEY}`,
        source: "widget",
        presentation: { style: "surfacePanel", title, subtitle },
        blocks,
        fallback: { lines: fallback },
      },
    };
  }, context);
}

function toolError(text: string): ToolExecutionResult {
  return { isError: true, output: [{ type: "text", text }] };
}

function toolOk(text: string): ToolExecutionResult {
  return { output: [{ type: "text", text }] };
}

async function executeQuery(
  args: { path: string; sql: string; chart?: ChartSpec },
  api: ToolExecutionApi,
  context: Context,
): Promise<ToolExecutionResult> {
  const ran = await runSqlite(api, args.path, args.sql, context);
  if (ran.error) return toolError(ran.error);
  const parsed = parseSqliteJson(ran.stdout);
  if (!parsed.ok) return toolError(parsed.error);
  const { columns, rows, table } = tableFrom(parsed.columns, parsed.rows);
  const chart = args.chart ? chartFrom(args.chart, columns, rows) : undefined;
  await publish(api, context, args.path, table, ran.elapsedMs, chart);
  return toolOk(
    formatPreview(table.columns, table.rows, table.truncated === true, [
      `${fileName(args.path)} · ${table.rows.length} row(s) · ${ran.elapsedMs}ms`,
      ...(args.chart && !chart ? ["Chart omitted: the result has no numeric series."] : []),
    ]),
  );
}

const sqliteSchema = defineTool({
  name: "sqlite_schema",
  description:
    "Inspect a SQLite database schema (tables, views, indexes, and their SQL). Read-only. " +
    "Updates the Data widget with a table of the schema.",
  parameters: Type.Object({
    path: Type.String({ description: "Path to the SQLite database file." }),
  }),
  replay: "safe",
  execute: (args, api, context) => executeQuery({ path: args.path, sql: SCHEMA_SQL }, api, context),
});

const sqliteQuery = defineTool({
  name: "sqlite_query",
  description:
    "Run a read-only SQL query against a SQLite file. Updates the Data widget with a native " +
    "table and, when chart.kind is set, a bar, line, or pie chart of numeric columns.",
  parameters: Type.Object({
    path: Type.String({ description: "Path to the SQLite database file." }),
    sql: Type.String({ description: "Read-only SQL. Writes, ATTACH, and shell commands fail." }),
    chart: Type.Optional(
      Type.Object({
        kind: Type.Union([Type.Literal("bar"), Type.Literal("line"), Type.Literal("pie")]),
        title: Type.Optional(Type.String()),
      }),
    ),
  }),
  replay: "safe",
  execute: (args, api, context) => executeQuery(args, api, context),
});

export const DurableSqlExplorer = defineExtension({
  name: "sql-explorer",
  tools: [sqliteSchema, sqliteQuery],
});

export default DurableSqlExplorer;
