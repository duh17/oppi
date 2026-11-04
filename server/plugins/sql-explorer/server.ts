import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { obj, oneOf, opt, str } from "@earendil-works/pi-schema";
import {
  defineTool,
  type ToolExecutionApi,
  type ToolExecutionResult,
} from "@earendil-works/pi-durable";
import type { Context, JsonValue } from "@earendil-works/chord";
import {
  actionBar,
  dataTable,
  defineExtension,
  defineFacet,
  DurableUI,
  Extensions,
  oppiHost,
  surface,
  type DataTableFields,
  type Surface,
  type SurfaceActionInvocation,
  type SurfaceActionReturn,
  type SurfacePublisher,
  type SurfaceView,
} from "oppi/v1";

const QUERY_TIMEOUT_SECONDS = 15;
const QUERY_OUTPUT_MAX_BYTES = 256 * 1024;
const WIDGET_MAX_ROWS = 200;
const WIDGET_MAX_COLUMNS = 32;
const WIDGET_MAX_CELL_CHARS = 200;
/**
 * The panel's own caps. One surface has a single 64 KiB wire budget for the whole card, so a cell
 * is shorter than the widget's and a page that still would not fit loses its trailing rows here,
 * where paging can reach them, instead of losing the card.
 */
const PANEL_MAX_CELL_CHARS = 80;
const PANEL_MAX_TITLE_CHARS = 200;
/** The host's surface cap (`EXTENSION_UI_SURFACE_MAX_BYTES`) and the share kept for its chrome. */
const PANEL_MAX_SURFACE_BYTES = 64 * 1024;
/** Header, column titles, action bar, and fallback words: measured generously, never exact. */
const PANEL_CHROME_BYTES = 16 * 1024;
const PANEL_ROWS_BYTES = PANEL_MAX_SURFACE_BYTES - PANEL_CHROME_BYTES;
const CHART_MAX_LABELS = 48;
const CHART_MAX_SERIES = 8;
const MODEL_PREVIEW_ROWS = 12;
const WIDGET_KEY = "data";
const WIDGET_ID = "sql-explorer:data";
const WIDGET_SLOT = "widget:data";
/** The surface's rows a fallback keeps before it stops being worth reading. */
const FALLBACK_ROWS = 8;
/** `fallback.text`'s cap on the wire; a longer fallback drops the whole surface. */
const FALLBACK_MAX_CHARS = 2000;
/** One page of results: the table cap is what a single run can show. */
const PAGE_ROWS = WIDGET_MAX_ROWS;
/** A schema row action's own read: enough rows to recognise the table. */
const PREVIEW_ROWS = 50;
const SNAPSHOT_SHORT = "read-only snapshot";
const SURFACE_ID = "sql-explorer";
const ROWS_SECTION = "rows";
const ACTIONS_SECTION = "actions";
const ACTION_RUN_AGAIN = "runAgain";
const ACTION_NEXT = "next";
const ACTION_PREVIOUS = "previous";
const ACTION_BACK = "back";
const ACTION_PREVIEW = "preview";
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

/**
 * A cell as the panel draws it: the surface caps a cell and counts characters, not code units, so
 * a long value is shortened here first and the rows get whatever budget is left.
 */
function panelCell(value: Cell): Cell {
  if (typeof value !== "string") return value;
  const chars = Array.from(value);
  if (chars.length <= PANEL_MAX_CELL_CHARS) return value;
  return `${chars.slice(0, PANEL_MAX_CELL_CHARS - 1).join("")}…`;
}

/** Every cell at the panel's cap, and whether any value was shortened to get there. */
function panelCells(rows: Cell[][]): { rows: Cell[][]; clipped: boolean } {
  let clipped = false;
  const next = rows.map((row) =>
    row.map((cell) => {
      const panel = panelCell(cell);
      if (panel !== cell) clipped = true;
      return panel;
    }),
  );
  return { rows: next, clipped };
}

const UTF8 = new TextEncoder();

/** Bytes a text spends on the wire: the surface cap counts UTF-8 bytes, not characters. */
function wireBytes(text: string): number {
  return UTF8.encode(text).length;
}

/** One row's cells keyed by column id, in column order: the shape the dataTable draws. */
function rowCells(columnCount: number, row: Cell[]): Record<string, Cell> {
  return Object.fromEntries(
    Array.from({ length: columnCount }, (_, index) => [`c${index}`, row[index] ?? null]),
  );
}

function cellText(value: Cell): string {
  if (value === null) return "";
  return typeof value === "number" ? String(value) : value;
}

/** What one scan of a statement found: whether a second follows it, and where its text ends. */
interface SqlScan {
  /** A second statement follows the first, so the query is refused whole. */
  multiple: boolean;
  /** Offset past the last significant character; only `;`, comments, and space follow it. */
  bodyEnd: number;
}

/**
 * One quote-, bracket-, and comment-aware pass over `sql`. Every question about where a statement
 * starts and ends is answered here, so a `;` in a string, an identifier, or a comment never counts
 * as the statement's own.
 */
function scanStatement(sql: string): SqlScan {
  let i = 0;
  let seen = false;
  let ended = false;
  let bodyEnd = 0;
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
      bodyEnd = i;
      continue;
    }
    if (ch === "[") {
      i += 1;
      skipUntil((next) => next === "]");
      if (i < sql.length) i += 1;
      seen = true;
      ended = false;
      bodyEnd = i;
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
    if (ended && seen) return { multiple: true, bodyEnd };
    seen = true;
    ended = false;
    i += 1;
    bodyEnd = i;
  }
  return { multiple: false, bodyEnd };
}

/** True when `sql` has a second statement after a non-trailing semicolon. */
function hasMultipleStatements(sql: string): boolean {
  return scanStatement(sql).multiple;
}

/**
 * The statement without its trailing semicolon and whatever comments follow it: inside the paging
 * wrapper's parentheses sqlite3 reads that `;` as the end of the inner query and fails the rest.
 */
function statementBody(sql: string): string {
  const body = sql.slice(0, scanStatement(sql).bodyEnd).trim();
  return body.length > 0 ? body : sql.trim();
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
): { columns: string[]; rows: Cell[][]; truncated: boolean; cellsClipped: boolean } {
  let truncated = false;
  // Whether a value the host draws got shortened, as opposed to rows the reader can page to.
  let cellsClipped = false;
  let nextColumns = columns.map((column) => {
    const clipped = clipCell(column);
    if (clipped !== column) cellsClipped = true;
    return typeof clipped === "string" ? clipped : String(column);
  });
  if (nextColumns.length > WIDGET_MAX_COLUMNS) {
    nextColumns = nextColumns.slice(0, WIDGET_MAX_COLUMNS);
    cellsClipped = true;
  }
  let nextRows = rows.map((row) => {
    const clipped = nextColumns.map((_, index) => {
      const cell = clipCell(row[index] ?? null);
      if (typeof row[index] === "string" && cell !== row[index]) cellsClipped = true;
      return cell;
    });
    if (row.length > nextColumns.length) cellsClipped = true;
    return clipped;
  });
  if (nextRows.length > WIDGET_MAX_ROWS) {
    nextRows = nextRows.slice(0, WIDGET_MAX_ROWS);
    truncated = true;
  }
  truncated ||= cellsClipped;
  return { columns: nextColumns, rows: nextRows, truncated, cellsClipped };
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

/**
 * The two lines sqlite3 prints when it cannot open the database itself. Match whole
 * lines: SQL errors can echo the same phrase (`no such table: unable to open database
 * file`), and retrying those against the main file could turn a failed query into a
 * stale read.
 */
const SQLITE_CANTOPEN_LINES = [
  /^Parse error in \d+(?:st|nd|rd|th) command line argument: unable to open database file \(14\)$/m,
  /^Error: unable to open database ".*": unable to open database file$/m,
];
const IMMUTABLE_SNAPSHOT_NOTE =
  "The database was read as an immutable snapshot of the main file (WAL mode without a -shm file), so writes made while reading or WAL frames not yet checkpointed are not visible.";

/** SQLite URI encoding: `%`, `?`, and `#` must be escaped; `/` and relative paths stay. */
function sqliteImmutableUri(path: string): string {
  let encoded = "";
  for (const ch of path) {
    encoded += ch === "%" ? "%25" : ch === "?" ? "%3F" : ch === "#" ? "%23" : ch;
  }
  return `file:${encoded}?immutable=1`;
}

type SqliteRun = {
  stdout: string;
  stderr: string;
  error?: string;
  elapsedMs: number;
  immutableSnapshot?: boolean;
};

async function runSqlite(
  env: ToolExecutionApi["env"],
  path: string,
  sql: string,
  context: Context,
): Promise<SqliteRun> {
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

  const started = Date.now();
  const finish = (ran: Omit<SqliteRun, "elapsedMs">): SqliteRun => ({
    ...ran,
    elapsedMs: Date.now() - started,
  });
  const invoke = async (database: string): Promise<SqliteRun & { cantOpen: boolean }> => {
    let stdout = "";
    let stderr = "";
    let truncated = false;
    const result = await env.exec(
      [...SQLITE_ARGV, "--", database, trimmedSql],
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
    if (!result.ok) {
      const message = result.error.message;
      if (result.error.code === "timeout") {
        return {
          stdout,
          stderr,
          error: `sqlite3 timed out after ${QUERY_TIMEOUT_SECONDS}s.`,
          elapsedMs: 0,
          cantOpen: false,
        };
      }
      if (result.error.code === "shell_unavailable" || missingSqliteMessage(message)) {
        return {
          stdout,
          stderr,
          error: `sqlite3 is not available in this environment. ${message}`,
          elapsedMs: 0,
          cantOpen: false,
        };
      }
      return { stdout, stderr, error: message, elapsedMs: 0, cantOpen: false };
    }
    if (result.value.exitCode !== 0) {
      const detail = stderr.trim() || stdout.trim() || `sqlite3 exited ${result.value.exitCode}`;
      return {
        stdout,
        stderr,
        error: detail,
        elapsedMs: 0,
        cantOpen: SQLITE_CANTOPEN_LINES.some((line) => line.test(detail)),
      };
    }
    if (truncated) {
      return {
        stdout,
        stderr,
        error: `Query output exceeded ${QUERY_OUTPUT_MAX_BYTES} bytes and was truncated.`,
        elapsedMs: 0,
        cantOpen: false,
      };
    }
    return { stdout, stderr, elapsedMs: 0, cantOpen: false };
  };

  const first = await invoke(trimmedPath);
  // `file://host/...` reads `host` as a URI authority, so `//localhost/tmp/x.db` would
  // reopen `/tmp/x.db` under the requested path. Leave `//` paths with their first error.
  if (!first.cantOpen || trimmedPath.startsWith("//")) return finish(first);
  // Read-only connections cannot create the -shm a WAL database needs; immutable=1
  // reads the main file as a snapshot instead. Retry once; keep the original error.
  const retry = await invoke(sqliteImmutableUri(trimmedPath));
  if (retry.error) return finish(first);
  return finish({ ...retry, immutableSnapshot: true });
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

// --- the results panel ------------------------------------------------------------------------
//
// `sqlite_query` and `sqlite_schema` publish one persistent strip surface for their Session: the
// file and what the last run cost, the rows as a `dataTable`, and an `actionBar` whose actions
// re-run or page the same statement in the handler, with no model turn. Surfaces live in the
// Session's memory (`SessionSurfaces`), so a server restart clears the panel until the next query
// publishes one again.

/** One run's display rows, already clipped to the surface's caps. */
interface ResultView {
  columns: string[];
  rows: Cell[][];
  elapsedMs: number;
  /** More rows exist past this page: the read asked for one row more than it shows. */
  hasMore: boolean;
  /** A cell or a column was clipped to the surface's cap. */
  clipped: boolean;
  /** The database could not be opened for writing, so it was read as a snapshot. */
  immutableSnapshot: boolean;
  /** Per row, the schema object a "Preview" row action reads; rows without one offer nothing. */
  previews?: Array<string | undefined>;
  /** Rows this page's read returned that the surface's byte budget could not hold. */
  droppedRows?: number;
}

/** What the panel shows: the last run, or the failure it ended in. */
interface ExplorerState {
  /** The database path as the model wrote it. */
  path: string;
  /** The statement the view came from: "Run again" and paging re-run it, never the model. */
  sql: string;
  /** Rows skipped by paging, 0 for the query's own first page. */
  offset: number;
  kind: "results" | "schema";
  view?: ResultView;
  /** The sqlite or JSON error this run ended in, in the card's own words. */
  failure?: string;
  /** The schema a "Preview" opened from, restored by "Back to schema". */
  schema?: { sql: string; view: ResultView };
}

/** One statement against one database file, runnable long after the tool call that made it. */
type Run = (sql: string) => Promise<SqliteRun>;

type ViewRun = { view: ResultView } | { failure: string };

/** Every action any state of this panel offers, with the role that state gives it. */
function actionTable(
  state: ExplorerState,
): Record<string, { title: string; role?: "primary" | "secondary" | "destructive" }> {
  const previewing = state.schema !== undefined;
  return {
    [ACTION_RUN_AGAIN]: { title: "Run again", role: previewing ? "secondary" : "primary" },
    [ACTION_NEXT]: { title: `Next ${PAGE_ROWS} rows` },
    [ACTION_PREVIOUS]: { title: `Previous ${PAGE_ROWS} rows` },
    [ACTION_BACK]: { title: "Back to schema", ...(previewing ? { role: "primary" as const } : {}) },
    [ACTION_PREVIEW]: { title: "Preview" },
  };
}

/** A card's words are capped on the wire; a longer one would drop the surface. */
function clipTitle(text: string): string {
  const chars = Array.from(text);
  return chars.length <= PANEL_MAX_TITLE_CHARS
    ? text
    : `${chars.slice(0, PANEL_MAX_TITLE_CHARS - 1).join("")}…`;
}

/** What the run was: rows, how long it took, and whether it read a snapshot. */
function surfaceSubtitle(state: ExplorerState): string {
  if (state.failure !== undefined) return "Query failed";
  const view = state.view;
  if (!view) return "";
  const dropped = view.droppedRows ?? 0;
  const parts = [
    // A page the byte budget shortened says so here, so the count is never a silent lie.
    dropped > 0
      ? `${view.rows.length} of ${view.rows.length + dropped} rows`
      : `${view.rows.length} row${view.rows.length === 1 ? "" : "s"}`,
    `${view.elapsedMs}ms`,
  ];
  if (state.offset > 0) parts.push(`from row ${state.offset + 1}`);
  if (view.immutableSnapshot) parts.push(SNAPSHOT_SHORT);
  return parts.join(" · ");
}

/**
 * The words a client without composites reads instead: the file, the count, the columns, and the
 * first rows — enough to answer "what came back?" without the grid.
 */
function surfaceFallback(state: ExplorerState): string {
  const lines = [clipTitle(fileName(state.path))];
  const subtitle = surfaceSubtitle(state);
  if (subtitle) lines.push(subtitle);
  if (state.failure !== undefined) lines.push("The query failed.", state.failure);
  const view = state.view;
  if (view && view.columns.length > 0) {
    lines.push(view.columns.join(" | "));
    // The notes come before the rows: a wide row can fill this text's own cap, and a reader who
    // never reached them would take the page for the whole result.
    if (view.droppedRows) lines.push(`… ${view.droppedRows} more row(s) did not fit the panel.`);
    if (view.clipped) lines.push("Some values are shortened to fit the panel.");
    for (const row of view.rows.slice(0, FALLBACK_ROWS)) lines.push(row.map(cellText).join(" | "));
    if (view.rows.length > FALLBACK_ROWS)
      lines.push(`… ${view.rows.length - FALLBACK_ROWS} more row(s)`);
  }
  const text = lines.join("\n");
  return text.length <= FALLBACK_MAX_CHARS ? text : `${text.slice(0, FALLBACK_MAX_CHARS - 1)}…`;
}

/** A column the host right-aligns: every filled cell is a number it can draw exactly. */
function numericColumn(rows: Cell[][], index: number): boolean {
  let sawNumber = false;
  for (const row of rows) {
    const cell = row[index];
    if (cell === null) continue;
    const text = cellText(cell);
    if (text === "") continue;
    if (exactNumber(text) === undefined) return false;
    sawNumber = true;
  }
  return sawNumber;
}

/** The card's own state: the rows, nothing at all, or the error the run ended in. */
function tableState(state: ExplorerState): NonNullable<DataTableFields["state"]> {
  if (state.failure !== undefined)
    return { kind: "failure", title: "Query failed", message: clipTitle(state.failure) };
  if ((state.view?.rows.length ?? 0) === 0) {
    // A page past the last row is not an empty query: the words say which one happened.
    if (state.kind === "schema")
      return {
        kind: "empty",
        title: "No rows",
        message: "This database has no schema objects.",
      };
    if (state.offset > 0)
      return { kind: "empty", title: "No more rows", message: "No rows past this point." };
    return { kind: "empty", title: "No rows", message: "The query returned no rows." };
  }
  return { kind: "content" };
}

/**
 * The rows a page can afford, measured the way the host measures the surface: the wire bytes of
 * the row payload, against the budget the chrome leaves. A page that would not fit loses trailing
 * rows — reachable by paging — and the caller keeps the count for `hasMore` and the offset.
 */
function budgetRows(columnCount: number, rows: Cell[][]): Cell[][] {
  let bytes = 0;
  let kept = 0;
  for (const row of rows) {
    const cost = wireBytes(JSON.stringify({ id: `r${kept}`, cells: rowCells(columnCount, row) }));
    // The first row is always kept: a card with one row still says what the query returned.
    if (kept > 0 && bytes + cost > PANEL_ROWS_BYTES) break;
    bytes += cost;
    kept += 1;
  }
  return kept === rows.length ? rows : rows.slice(0, kept);
}

/** One run's rows, clipped to the surface's caps and its byte budget. */
function rowsView(
  parsed: { columns: string[]; rows: Cell[][] },
  elapsedMs: number,
  immutableSnapshot: boolean,
): ResultView {
  const clipped = clipTable(parsed.columns, parsed.rows);
  const cells = panelCells(clipped.rows);
  const rows = budgetRows(clipped.columns.length, cells.rows);
  const droppedRows = cells.rows.length - rows.length;
  return {
    columns: clipped.columns,
    rows,
    elapsedMs,
    // Whatever the read returned past the rows on screen is one "next", whether the budget or
    // the page cap left it out; paging continues from the rows this page actually showed.
    hasMore: parsed.rows.length > rows.length,
    clipped: clipped.cellsClipped || cells.clipped,
    immutableSnapshot,
    ...(droppedRows > 0 ? { droppedRows } : {}),
  };
}

/** A schema as (name, type, sql), with the tables and views a "Preview" tap can read. */
function schemaView(
  parsed: { columns: string[]; rows: Cell[][] },
  elapsedMs: number,
  immutableSnapshot: boolean,
): ResultView {
  // The CREATE statements stay legible: they are clipped at the surface's own cell cap, not the
  // panel's shorter one, because a schema row is the one place that text is worth reading.
  const clipped = clipTable(
    [parsed.columns[0] ?? "name", parsed.columns[1] ?? "type", parsed.columns[2] ?? "sql"],
    parsed.rows.map((row) => [row[0] ?? null, row[1] ?? null, row[2] ?? null]),
  );
  const rows = budgetRows(clipped.columns.length, clipped.rows);
  const droppedRows = clipped.rows.length - rows.length;
  return {
    columns: clipped.columns,
    rows,
    elapsedMs,
    hasMore: false,
    clipped: clipped.cellsClipped,
    immutableSnapshot,
    previews: rows.map((row) => {
      const type = cellText(row[1] ?? null);
      return type === "table" || type === "view" ? cellText(row[0] ?? null) : undefined;
    }),
    ...(droppedRows > 0 ? { droppedRows } : {}),
  };
}

/**
 * Rows past the first page, read from the same statement. sqlite3's CLI takes no bound
 * parameters, and the statement is the model's own (already refused if it holds a second one), so
 * the offset is the only text this adds: the query's plan and limits stay its own.
 */
export function pagedSql(sql: string, offset: number): string {
  return `SELECT * FROM (\n${statementBody(sql)}\n) LIMIT ${PAGE_ROWS + 1} OFFSET ${offset}`;
}

/** A table or view's own rows, for the schema's "Preview" row action. */
function previewSql(name: string): string {
  return `SELECT * FROM ${quoteIdentifier(name)} LIMIT ${PREVIEW_ROWS}`;
}

/** An identifier from the database, quoted back to it: `"` is the only character to double. */
function quoteIdentifier(name: string): string {
  return `"${name.replaceAll('"', '""')}"`;
}

/** The surface for one state: the file, its rows, and what the user can do next. */
function renderExplorer(state: ExplorerState): SurfaceView {
  const view = state.view;
  const actions = state.schema ? [ACTION_BACK, ACTION_RUN_AGAIN] : [ACTION_RUN_AGAIN];
  if (view?.hasMore) actions.push(ACTION_NEXT);
  if (state.offset > 0) actions.push(ACTION_PREVIOUS);
  const table = actionTable(state);
  const columns = (view?.columns ?? []).map((title, index) => ({
    id: `c${index}`,
    title,
    ...(view && numericColumn(view.rows, index) ? { kind: "number" as const } : {}),
  }));
  return {
    header: { title: clipTitle(fileName(state.path)), subtitle: surfaceSubtitle(state) },
    sections: [
      dataTable({
        id: ROWS_SECTION,
        header: { title: state.kind === "schema" ? "Schema objects" : "Results" },
        state: tableState(state),
        columns,
        rows: (view?.rows ?? []).map((row, index) => ({
          id: `r${index}`,
          cells: rowCells(columns.length, row),
          ...(view?.previews?.[index] ? { actions: [ACTION_PREVIEW] } : {}),
        })),
        fallback: { text: surfaceFallback(state) },
      }),
      actionBar({
        id: ACTIONS_SECTION,
        header: { title: state.failure === undefined ? "Actions" : "Try again" },
        actions,
        fallback: { text: actions.map((id) => table[id]?.title ?? id).join(" · ") },
      }),
    ],
  };
}

/** One page of a statement's own rows, or the failure the read ended in. */
async function readRows(run: Run, sql: string, offset: number): Promise<ViewRun> {
  const ran = await run(offset > 0 ? pagedSql(sql, offset) : sql);
  if (ran.error) return { failure: ran.error };
  const parsed = parseSqliteJson(ran.stdout);
  if (!parsed.ok) return { failure: parsed.error };
  return { view: rowsView(parsed, ran.elapsedMs, ran.immutableSnapshot === true) };
}

/** The schema, as the panel shows it. */
async function readSchema(run: Run): Promise<ViewRun> {
  const ran = await run(SCHEMA_SQL);
  if (ran.error) return { failure: ran.error };
  const parsed = parseSqliteJson(ran.stdout);
  if (!parsed.ok) return { failure: parsed.error };
  return { view: schemaView(parsed, ran.elapsedMs, ran.immutableSnapshot === true) };
}

/** The state a read leaves: its rows, or the failure instead of them. */
function outcomeState(base: ExplorerState, outcome: ViewRun): ExplorerState {
  if ("failure" in outcome)
    return { ...base, view: undefined, failure: clipTitle(outcome.failure) };
  return { ...base, view: outcome.view, failure: undefined };
}

/** The same view at another page: a schema is one read, so only results page. */
async function rerun(run: Run, state: ExplorerState, offset: number): Promise<ExplorerState> {
  const base: ExplorerState = { ...state, offset };
  if (state.kind === "schema") return outcomeState(base, await readSchema(run));
  return outcomeState(base, await readRows(run, state.sql, offset));
}

/** How far one page of this state moved: a page the byte budget shortened ends where it showed. */
function pageRows(state: ExplorerState): number {
  return state.view && state.view.rows.length > 0 ? state.view.rows.length : PAGE_ROWS;
}

/** The schema object a "Preview" tap names, from the row id the dataTable gave it. */
function previewName(state: ExplorerState, rowId: string | undefined): string | undefined {
  const match = rowId === undefined ? null : /^r(\d+)$/.exec(rowId);
  if (!match?.[1]) return undefined;
  return state.view?.previews?.[Number(match[1])];
}

/**
 * One panel, published into the Session's surface loop and ready to answer its own actions. Each
 * publish builds a fresh panel, so the state it shows brings its own fallback words and action
 * roles, and the host rebinds this handler set to whatever it now offers.
 */
function explorerPanel(run: Run, first: ExplorerState): Surface<ExplorerState> {
  const panel = surface<ExplorerState>({
    id: SURFACE_ID,
    title: clipTitle(fileName(first.path)),
    empty: { title: "No rows", message: "The query returned no rows." },
    actions: actionTable(first),
    fallback: surfaceFallback(first),
    view: renderExplorer,
  });

  const republish = (
    invocation: SurfaceActionInvocation<ExplorerState>,
    next: ExplorerState,
  ): SurfaceActionReturn => {
    if (!publishExplorer(run, invocation.ctx.surfaces, next))
      return {
        error: {
          compositeId: invocation.compositeId,
          message: "The panel could not show this page.",
        },
      };
    return { patch: {} };
  };

  panel.action(ACTION_RUN_AGAIN, async (state, invocation) =>
    republish(invocation, await rerun(run, state, state.offset)),
  );
  panel.action(ACTION_NEXT, async (state, invocation) =>
    republish(invocation, await rerun(run, state, state.offset + pageRows(state))),
  );
  panel.action(ACTION_PREVIOUS, async (state, invocation) =>
    republish(invocation, await rerun(run, state, Math.max(0, state.offset - PAGE_ROWS))),
  );
  panel.action(ACTION_BACK, (state, invocation) => {
    const saved = state.schema;
    if (!saved)
      return { error: { compositeId: invocation.compositeId, message: "The schema is gone." } };
    return republish(invocation, {
      path: state.path,
      kind: "schema",
      sql: saved.sql,
      offset: 0,
      view: saved.view,
    });
  });
  panel.action(ACTION_PREVIEW, async (state, invocation) => {
    const name = previewName(state, invocation.rowId);
    if (!name)
      return {
        error: { compositeId: invocation.compositeId, message: "This row has nothing to preview." },
      };
    const sql = previewSql(name);
    // A preview keeps the schema it came from, so "Back to schema" shows the rows the tap came
    // from rather than a second reading of a database that may have changed under it.
    const opened: ExplorerState = {
      path: state.path,
      kind: "results",
      sql,
      offset: 0,
      ...(state.kind === "schema" && state.view
        ? { schema: { sql: state.sql, view: state.view } }
        : {}),
    };
    return republish(invocation, outcomeState(opened, await readRows(run, sql, 0)));
  });
  return panel;
}

/**
 * Publish one panel state, or report that the host refused it. A render problem (a surface over
 * the wire cap, a rule the state broke) is never the tool call's failure: the caller falls back to
 * the v1 widget, which is what the query's own rows always fitted in.
 */
function publishExplorer(run: Run, publisher: SurfacePublisher, state: ExplorerState): boolean {
  try {
    explorerPanel(run, state).publish({ surfaces: publisher }, state);
    return true;
  } catch {
    return false;
  }
}

/**
 * The Session's surface loop, when this call runs inside one. A bare pi-durable Harness (this
 * plugin loaded without Oppi's server around it) has no host bound at all, and a conversation
 * whose Session is not live has no loop: both publish the v1 widget instead.
 */
function surfacePublisher(env: ToolExecutionApi["env"]): SurfacePublisher | undefined {
  try {
    return oppiHost().surfaces(env);
  } catch {
    return undefined;
  }
}

interface DataWidget {
  title: string;
  subtitle: string;
  lines: string[];
  blocks: JsonValue[];
}

/** The v1 lines a client without `nativeSurface` shows: header, columns, then the first rows. */
function widgetLines(title: string, subtitle: string, columns: string[], rows: Cell[][]): string[] {
  return [
    title,
    subtitle,
    columns.join(" | "),
    ...rows.slice(0, FALLBACK_ROWS).map((row) => row.map(cellText).join(" | ")),
  ];
}

/** The conversation's `data` widget: the chart alone beside the surface, or the whole v1 panel. */
function dataWidget(state: ExplorerState, table: TableBlock, blocks: JsonValue[]): DataWidget {
  const title = fileName(state.path);
  const subtitle = surfaceSubtitle(state);
  return {
    title,
    subtitle,
    lines: widgetLines(title, subtitle, table.columns, table.rows),
    blocks,
  };
}

/**
 * Write the conversation's `data` widget slot, or clear it: an explicit empty widget is how the
 * slot is emptied, so a session that had this plugin's old table panel replaces it with the
 * surface's own projection instead of showing both. The chart is still a v1 widget beside the
 * surface until `chart` lands (slice 5), and only the tool call writes it: an action has no task
 * of its own to commit from. A paging tap therefore leaves the chart on the page it drew.
 */
async function commitDataWidget(
  api: ToolExecutionApi,
  context: Context,
  write: DataWidget | undefined,
): Promise<void> {
  await api.commit(async (tx) => {
    const ui = await tx.doc(DurableUI, api.conversationId);
    ui.notifications[WIDGET_SLOT] = write
      ? {
          id: WIDGET_ID,
          method: "setWidget",
          widgetKey: WIDGET_KEY,
          widgetLines: write.lines,
          ...PROVENANCE,
          nativeSurface: {
            version: 1,
            id: `widget:${WIDGET_KEY}`,
            source: "widget",
            presentation: { style: "surfacePanel", title: write.title, subtitle: write.subtitle },
            blocks: write.blocks,
            fallback: { lines: write.lines },
          },
        }
      : {
          id: WIDGET_ID,
          method: "setWidget",
          widgetKey: WIDGET_KEY,
          widgetLines: [],
          ...PROVENANCE,
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
  args: { path: string; sql: string; chart?: ChartSpec; kind: ExplorerState["kind"] },
  api: ToolExecutionApi,
  context: Context,
): Promise<ToolExecutionResult> {
  const publisher = surfacePublisher(api.env);
  // A tap runs later, outside this call: its read must not be cancelled by this call's context.
  const run: Run = (sql) => runSqlite(api.env, args.path, sql, BACKGROUND_CONTEXT);
  const ran = await runSqlite(api.env, args.path, args.sql, context);
  const failed = async (message: string): Promise<ToolExecutionResult> => {
    const state: ExplorerState = {
      path: args.path,
      kind: args.kind,
      sql: args.sql,
      offset: 0,
      failure: clipTitle(message),
    };
    // A chart from an earlier run would contradict the failure card beside it, and a card the
    // host refused leaves the v1 panel it drew before untouched.
    if (publisher && publishExplorer(run, publisher, state))
      await commitDataWidget(api, context, undefined);
    return toolError(message);
  };
  if (ran.error) return failed(ran.error);
  const parsed = parseSqliteJson(ran.stdout);
  if (!parsed.ok) return failed(parsed.error);
  const { columns, rows, table } = tableFrom(parsed.columns, parsed.rows);
  const chart = args.chart ? chartFrom(args.chart, columns, rows) : undefined;
  const snapshot = ran.immutableSnapshot === true;
  const state: ExplorerState = {
    path: args.path,
    kind: args.kind,
    sql: args.sql,
    offset: 0,
    view:
      args.kind === "schema"
        ? schemaView(parsed, ran.elapsedMs, snapshot)
        : rowsView(parsed, ran.elapsedMs, snapshot),
  };
  if (publisher && publishExplorer(run, publisher, state)) {
    await commitDataWidget(
      api,
      context,
      chart ? dataWidget(state, table, [chart as unknown as JsonValue]) : undefined,
    );
  } else {
    // No surface loop to project into, or a surface the host refused: the v1 widget is the only
    // panel there is, and a render problem must never turn the query itself into a failure.
    await commitDataWidget(
      api,
      context,
      dataWidget(state, table, [table, ...(chart ? [chart] : [])] as unknown as JsonValue[]),
    );
  }
  return toolOk(
    formatPreview(table.columns, table.rows, table.truncated === true, [
      `${fileName(args.path)} · ${table.rows.length} row(s) · ${ran.elapsedMs}ms`,
      ...(snapshot ? [IMMUTABLE_SNAPSHOT_NOTE] : []),
      ...(args.chart && !chart ? ["Chart omitted: the result has no numeric series."] : []),
    ]),
  );
}

const sqliteSchema = defineTool({
  name: "sqlite_schema",
  description:
    "Inspect a SQLite database schema (tables, views, indexes, and their SQL). Read-only. " +
    "Publishes the schema to the database panel, where a table or view can be previewed.",
  parameters: obj({
    path: str({ description: "Path to the SQLite database file." }),
  }),
  replay: "safe",
  execute: (args, api, context) =>
    executeQuery({ path: args.path, sql: SCHEMA_SQL, kind: "schema" }, api, context),
});

const sqliteQuery = defineTool({
  name: "sqlite_query",
  description:
    "Run a read-only SQL query against a SQLite file. Publishes the rows to the database panel " +
    "and, when chart.kind is set, a bar, line, or pie chart of the numeric columns.",
  parameters: obj({
    path: str({ description: "Path to the SQLite database file." }),
    sql: str({ description: "Read-only SQL. Writes, ATTACH, and shell commands fail." }),
    chart: opt(
      obj({
        kind: oneOf(["bar", "line", "pie"]),
        title: opt(str()),
      }),
    ),
  }),
  replay: "safe",
  execute: (args, api, context) => executeQuery({ ...args, kind: "results" }, api, context),
});

export const DurableSqlExplorer = defineExtension({
  name: "sql-explorer",
  runtimes: ["host", "sandbox"],
  tools: [sqliteSchema, sqliteQuery],
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableSqlExplorer));
