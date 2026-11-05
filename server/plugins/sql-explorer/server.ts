import { obj, str } from "@earendil-works/pi-schema";
import {
  defineTool,
  type ToolExecutionApi,
  type ToolExecutionResult,
} from "@earendil-works/pi-durable";
import type { Context } from "@earendil-works/chord";
import { defineExtension, defineFacet, Extensions } from "oppi/v1";

const QUERY_TIMEOUT_SECONDS = 15;
const QUERY_OUTPUT_MAX_BYTES = 256 * 1024;
/** What one result shows, for the person reading the tool row and for the model alike. */
const RESULT_MAX_ROWS = 100;
const RESULT_MAX_COLUMNS = 32;
const RESULT_MAX_CELL_CHARS = 500;
const SCHEMA_SQL = "SELECT name, type, sql FROM sqlite_schema ORDER BY type, name";
const SQLITE3 = "sqlite3";
const SQLITE_ARGV = [SQLITE3, "-readonly", "-safe", "-noinit", "-json"] as const;

type Cell = string | number | null;

function fileName(path: string): string {
  const trimmed = path.replace(/[/\\]+$/, "");
  const slash = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return (slash >= 0 ? trimmed.slice(slash + 1) : trimmed) || path;
}

/**
 * True when `sql` has a second statement after a non-trailing semicolon. One quote-, bracket-, and
 * comment-aware pass, so a `;` in a string, an identifier, or a comment never counts as the
 * statement's own.
 */
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

/** The result as it is shown: columns and rows cut to the caps, and whether any cell was cut. */
function clipTable(
  columns: string[],
  rows: Cell[][],
): { columns: string[]; rows: Cell[][]; cellsClipped: boolean } {
  let cellsClipped = false;
  const clipped = (value: Cell): Cell => {
    if (typeof value !== "string" || value.length <= RESULT_MAX_CELL_CHARS) return value;
    cellsClipped = true;
    return value.slice(0, RESULT_MAX_CELL_CHARS);
  };
  const shownColumns = columns.slice(0, RESULT_MAX_COLUMNS);
  if (shownColumns.length < columns.length) cellsClipped = true;
  return {
    columns: shownColumns.map((column) => String(clipped(column))),
    rows: rows
      .slice(0, RESULT_MAX_ROWS)
      .map((row) => shownColumns.map((_, index) => clipped(row[index] ?? null))),
    cellsClipped,
  };
}

/** One markdown table cell: backslashes and pipes escaped, line breaks written out, NULL spelled. */
function markdownCell(value: Cell): string {
  if (value === null) return "NULL";
  const text = typeof value === "number" ? String(value) : value;
  return text
    .replace(/\\/g, "\\\\")
    .replace(/\|/g, "\\|")
    .replace(/\r/g, "\\r")
    .replace(/\n/g, "\\n");
}

function markdownTable(columns: string[], rows: Cell[][]): string {
  const line = (cells: string[]): string => `| ${cells.join(" | ")} |`;
  return [
    line(columns.map(markdownCell)),
    line(columns.map(() => "---")),
    ...rows.map((cells) => line(cells.map(markdownCell))),
  ].join("\n");
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

function toolError(text: string): ToolExecutionResult {
  return { isError: true, output: [{ type: "text", text }] };
}

function toolOk(text: string): ToolExecutionResult {
  return { output: [{ type: "text", text }] };
}

/**
 * One statement against one database file, answered as the tool's result: a line saying what ran,
 * then the rows as a markdown table, which the tool row shows like any other tool output.
 */
async function executeQuery(
  args: { path: string; sql: string },
  api: ToolExecutionApi,
  context: Context,
): Promise<ToolExecutionResult> {
  const ran = await runSqlite(api.env, args.path, args.sql, context);
  if (ran.error) return toolError(ran.error);
  const parsed = parseSqliteJson(ran.stdout);
  if (!parsed.ok) return toolError(parsed.error);
  const shown = clipTable(parsed.columns, parsed.rows);
  const lines = [
    `${fileName(args.path)} · ${parsed.rows.length} row(s) · ${ran.elapsedMs}ms`,
    ...(ran.immutableSnapshot === true ? [IMMUTABLE_SNAPSHOT_NOTE] : []),
  ];
  if (shown.columns.length > 0) lines.push("", markdownTable(shown.columns, shown.rows));
  if (parsed.rows.length > shown.rows.length)
    lines.push(
      "",
      `… ${parsed.rows.length - shown.rows.length} more row(s) not shown. Narrow the query with WHERE, LIMIT, or OFFSET.`,
    );
  if (shown.cellsClipped)
    lines.push(
      "",
      `Values past ${RESULT_MAX_CELL_CHARS} characters and columns past ${RESULT_MAX_COLUMNS} were cut.`,
    );
  return toolOk(lines.join("\n"));
}

const sqliteSchema = defineTool({
  name: "sqlite_schema",
  description:
    "Inspect a SQLite database schema (tables, views, indexes, and their SQL). Read-only. " +
    "Returns one row per object as a markdown table.",
  parameters: obj({
    path: str({ description: "Path to the SQLite database file." }),
  }),
  replay: "safe",
  execute: (args, api, context) => executeQuery({ path: args.path, sql: SCHEMA_SQL }, api, context),
});

const sqliteQuery = defineTool({
  name: "sqlite_query",
  description:
    "Run a read-only SQL query against a SQLite file. Returns the rows as a markdown table, " +
    `the first ${RESULT_MAX_ROWS} rows at most.`,
  parameters: obj({
    path: str({ description: "Path to the SQLite database file." }),
    sql: str({ description: "Read-only SQL. Writes, ATTACH, and shell commands fail." }),
  }),
  replay: "safe",
  execute: (args, api, context) => executeQuery(args, api, context),
});

export const DurableSqlExplorer = defineExtension({
  name: "sql-explorer",
  runtimes: ["host", "sandbox"],
  tools: [sqliteSchema, sqliteQuery],
});

/** The plugin facet. */
export default defineFacet((_host, self) => self.contribute(Extensions, DurableSqlExplorer));
