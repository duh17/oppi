import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { Harness, createRegistry } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableSqlExplorer, parseSqliteJson } from "../plugins/sql-explorer/server.js";
import { makeTempDir } from "./harness/temp-dir.js";
import { toolArguments, toolNamed } from "./helpers/tool-arguments.js";

const harnesses = new Set<Harness>();
afterEach(async () => {
  await Promise.all([...harnesses].map((harness) => harness.close(context)));
  harnesses.clear();
  vi.restoreAllMocks();
});

function seedSales(path: string, extraRows = 0): void {
  const db = new DatabaseSync(path);
  db.exec(`
    CREATE TABLE sales (name TEXT, amount INTEGER);
    INSERT INTO sales VALUES ('apples', 12), ('bananas', 9), ('cherries', 4);
  `);
  if (extraRows > 0) {
    db.exec("BEGIN");
    for (let index = 0; index < extraRows; index += 1) {
      db.exec(`INSERT INTO sales VALUES ('row-${index}', ${index})`);
    }
    db.exec("COMMIT");
  }
  db.close();
}

function seedClosedWal(path: string): void {
  const db = new DatabaseSync(path);
  db.exec("PRAGMA journal_mode=WAL");
  db.exec(`
    CREATE TABLE sales (name TEXT, amount INTEGER);
    INSERT INTO sales VALUES ('apples', 12), ('bananas', 9), ('cherries', 4);
  `);
  db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  db.close();
  expect(existsSync(`${path}-shm`)).toBe(false);
  expect(existsSync(`${path}-wal`)).toBe(false);
}

function tool(name: string, args: Record<string, unknown>): FauxResponseStep {
  return fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return JSON.stringify(content);
  return content
    .flatMap((part) =>
      part && typeof part === "object" && "text" in part && typeof part.text === "string"
        ? [part.text]
        : [],
    )
    .join("");
}

async function fixture(responses: FauxResponseStep[], wrapExec?: (env: NodeExecutionEnv) => void) {
  const dir = makeTempDir("oppi-sql-explorer-");
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  faux.setResponses(responses);
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const env = new NodeExecutionEnv({ cwd: dir });
  wrapExec?.(env);
  const registry = createRegistry();
  registry.install(DurableSqlExplorer);
  const storage = await openNodeSqliteStorage(join(dir, "store.sqlite"));
  const harness = await Harness.open(
    storage,
    { models, registry, env: () => env, settings: { compaction: { enabled: false } } },
    context,
  );
  harnesses.add(harness);
  const root = await harness.root(context, {
    agent: {
      model: { provider: "faux", modelId: "faux-1" },
      cwd: dir,
      extensions: [DurableSqlExplorer],
    },
  });
  return { dir, env, harness, root };
}

async function prompt(root: Awaited<ReturnType<typeof fixture>>["root"]): Promise<void> {
  const submission = await root.submit({ type: "input", content: "query the db" }, context);
  expect((await submission.wait(context)).status).toBe("done");
  await root.waitForIdle(context);
}

async function lastToolResult(root: Awaited<ReturnType<typeof fixture>>["root"]) {
  const messages = (await root.context(context)).messages;
  const result = messages.findLast((message) => message.role === "toolResult");
  expect(result).toBeDefined();
  return result!;
}

async function lastToolText(root: Awaited<ReturnType<typeof fixture>>["root"]): Promise<string> {
  return textOf((await lastToolResult(root)).content);
}

describe("durable SQLite explorer", { timeout: 20_000 }, () => {
  it("queries a real database through env.exec and answers with a markdown table", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT name, amount FROM sales ORDER BY amount DESC",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    const exec = vi.spyOn(f.env, "exec");
    await prompt(f.root);

    expect(exec.mock.calls[0]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "sales.db",
      "SELECT name, amount FROM sales ORDER BY amount DESC",
    ]);

    const text = await lastToolText(f.root);
    expect(text).toMatch(
      /^sales\.db · 3 row\(s\) · \d+ms\n\n\| name \| amount \|\n\| --- \| --- \|\n/,
    );
    expect(text).toContain("| apples | 12 |\n| bananas | 9 |\n| cherries | 4 |");
    // The phone renders the row's output as Markdown only when the result says so.
    expect((await lastToolResult(f.root)).details).toEqual({
      expandedText: text,
      presentationFormat: "markdown",
    });
  });

  it("refuses ATTACH under sqlite3 -safe", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "ATTACH DATABASE 'other.db' AS other",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect((await lastToolResult(f.root)).isError).toBe(true);
    expect(existsSync(join(f.dir, "other.db"))).toBe(false);
  });

  it("fails write statements against a read-only database", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "INSERT INTO sales VALUES ('dates', 1)",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect(await lastToolText(f.root)).toMatch(/readonly/i);
  });

  it("shows the first rows of a larger result and says how many it left out", async () => {
    const f = await fixture([
      tool("sqlite_query", { path: "sales.db", sql: "SELECT name, amount FROM sales" }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"), 250);
    await prompt(f.root);
    const text = await lastToolText(f.root);
    expect(text).toContain("253 row(s)");
    // The header and rule, then the first hundred rows.
    expect(text.split("\n").filter((line) => line.startsWith("| "))).toHaveLength(102);
    expect(text).toContain("… 153 more row(s) not shown.");
  });

  it("returns a missing-binary error when sqlite3 cannot be spawned", async () => {
    const f = await fixture(
      [tool("sqlite_query", { path: "sales.db", sql: "SELECT 1" }), fauxAssistantMessage("DONE")],
      (env) => {
        const original = env.exec.bind(env);
        vi.spyOn(env, "exec").mockImplementation((command, options, execContext) =>
          original(
            Array.isArray(command) && command[0] === "sqlite3"
              ? ["sqlite3-not-installed", ...command.slice(1)]
              : command,
            options,
            execContext,
          ),
        );
      },
    );
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect(await lastToolText(f.root)).toMatch(/sqlite3 is not available/i);
  });

  it("passes a path with spaces through argv without a shell", async () => {
    const f = await fixture([
      tool("sqlite_schema", { path: "my sales.db" }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "my sales.db"));
    const exec = vi.spyOn(f.env, "exec");
    await prompt(f.root);
    expect(exec.mock.calls[0]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "my sales.db",
      "SELECT name, type, sql FROM sqlite_schema ORDER BY type, name",
    ]);
    expect(await lastToolText(f.root)).toContain("CREATE TABLE sales");
  });

  it("queries and inspects schema of a closed WAL database as an immutable snapshot", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT name, amount FROM sales ORDER BY amount DESC",
      }),
      fauxAssistantMessage("queried"),
      tool("sqlite_schema", { path: "sales.db" }),
      fauxAssistantMessage("DONE"),
    ]);
    seedClosedWal(join(f.dir, "sales.db"));
    const exec = vi.spyOn(f.env, "exec");
    await prompt(f.root);

    expect(exec.mock.calls[0]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "sales.db",
      "SELECT name, amount FROM sales ORDER BY amount DESC",
    ]);
    expect(exec.mock.calls[1]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "file:sales.db?immutable=1",
      "SELECT name, amount FROM sales ORDER BY amount DESC",
    ]);
    const queryText = await lastToolText(f.root);
    expect(queryText).toContain("apples");
    expect(queryText).toContain("immutable snapshot of the main file");
    expect(queryText).toContain("| apples | 12 |");

    await prompt(f.root);
    const schemaText = await lastToolText(f.root);
    expect(schemaText).toContain("| name | type | sql |");
    expect(schemaText).toContain("CREATE TABLE sales");
    expect(schemaText).toContain("immutable snapshot of the main file");
  });

  it("opens a closed WAL database whose path contains a space and a hash", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "my sales#1.db",
        sql: "SELECT name, amount FROM sales",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedClosedWal(join(f.dir, "my sales#1.db"));
    const exec = vi.spyOn(f.env, "exec");
    await prompt(f.root);
    expect(exec.mock.calls[0]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "my sales#1.db",
      "SELECT name, amount FROM sales",
    ]);
    expect(exec.mock.calls[1]?.[0]).toEqual([
      "sqlite3",
      "-readonly",
      "-safe",
      "-noinit",
      "-json",
      "--",
      "file:my sales%231.db?immutable=1",
      "SELECT name, amount FROM sales",
    ]);
    expect((await lastToolResult(f.root)).isError).toBeFalsy();
    expect(await lastToolText(f.root)).toContain("apples");
  });

  it("does not create files when the database path is missing", async () => {
    const f = await fixture([
      tool("sqlite_query", { path: "missing.db", sql: "SELECT 1" }),
      fauxAssistantMessage("DONE"),
    ]);
    await prompt(f.root);
    const result = await lastToolResult(f.root);
    expect(result.isError).toBe(true);
    const text = textOf(result.content);
    expect(text).toContain("unable to open database file");
    expect(text).not.toContain("immutable=1");
    expect(existsSync(join(f.dir, "missing.db"))).toBe(false);
    expect(existsSync(join(f.dir, "missing.db-shm"))).toBe(false);
    expect(existsSync(join(f.dir, "missing.db-wal"))).toBe(false);
  });

  it("keeps a SQL error that echoes the open-failure phrase instead of reading a stale snapshot", async () => {
    const table = "unable to open database file";
    const f = await fixture([
      tool("sqlite_query", { path: "live.db", sql: `SELECT note FROM "${table}"` }),
      fauxAssistantMessage("DONE"),
    ]);
    // The main file still has the table; the open writer's uncheckpointed WAL has dropped it.
    const writer = new DatabaseSync(join(f.dir, "live.db"));
    try {
      writer.exec("PRAGMA journal_mode=WAL");
      writer.exec("PRAGMA wal_autocheckpoint=0");
      writer.exec(
        `CREATE TABLE "${table}" (note TEXT); INSERT INTO "${table}" VALUES ('stale-row')`,
      );
      writer.exec("PRAGMA wal_checkpoint(TRUNCATE)");
      writer.exec(`DROP TABLE "${table}"`);
      const exec = vi.spyOn(f.env, "exec");
      await prompt(f.root);

      const result = await lastToolResult(f.root);
      expect(result.isError).toBe(true);
      const text = textOf(result.content);
      expect(text).toContain(`no such table: ${table}`);
      expect(text).not.toContain("stale-row");
      expect(text).not.toContain("immutable snapshot");
      expect(exec).toHaveBeenCalledTimes(1);
    } finally {
      writer.close();
    }
  });

  it("fails a query whose sqlite3 output is over the cap", async () => {
    const f = await fixture([
      tool("sqlite_query", { path: "sales.db", sql: "SELECT hex(zeroblob(200000)) AS blob" }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    const result = await lastToolResult(f.root);
    expect(result.isError).toBe(true);
    expect(textOf(result.content)).toMatch(/truncated/i);
  });

  it("keeps duplicate JOIN column names and order", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT * FROM a JOIN b ON a.id = b.id",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    const db = new DatabaseSync(join(f.dir, "sales.db"));
    db.exec(`
      CREATE TABLE a (id INTEGER, name TEXT);
      CREATE TABLE b (id INTEGER, name TEXT);
      INSERT INTO a VALUES (1, 'left');
      INSERT INTO b VALUES (1, 'right');
    `);
    db.close();
    await prompt(f.root);
    const text = await lastToolText(f.root);
    expect(text).toContain(
      "| id | name | id | name |\n| --- | --- | --- | --- |\n| 1 | left | 1 | right |",
    );
  });

  it("keeps Inf and -Inf from overflow as text", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT 1e999 AS a, -1e999 AS b, 'Inf' AS c, 1 AS d",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect((await lastToolResult(f.root)).isError).toBeFalsy();
    expect(await lastToolText(f.root)).toContain(
      "| a | b | c | d |\n| --- | --- | --- | --- |\n| Inf | -Inf | Inf | 1 |",
    );
  });

  it("keeps integers beyond 2^53 as exact text", async () => {
    const f = await fixture([
      tool("sqlite_query", { path: "sales.db", sql: "SELECT v FROM n" }),
      fauxAssistantMessage("DONE"),
    ]);
    const db = new DatabaseSync(join(f.dir, "sales.db"));
    db.exec("CREATE TABLE n (v INTEGER); INSERT INTO n VALUES (9223372036854775807);");
    db.close();
    await prompt(f.root);
    const text = await lastToolText(f.root);
    expect(text).toContain("9223372036854775807");
    expect(text).not.toContain("9223372036854776000");
  });

  it("writes a blob, CR/LF text, pipes, and NULL vs empty into one table row", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT blob, text, empty, missing FROM t",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    const db = new DatabaseSync(join(f.dir, "sales.db"));
    db.exec(`
      CREATE TABLE t (blob BLOB, text TEXT, empty TEXT, missing TEXT);
      INSERT INTO t VALUES (x'00412c0a22ff', char(13) || '|' || '"' || char(10) || '\\', '', NULL);
    `);
    db.close();
    await prompt(f.root);
    const text = await lastToolText(f.root);
    // One physical line per row: the line breaks, the pipe, and the backslash are written out.
    expect(text).toContain('| \u0000A,\\n"\u00ff | \\r\\|"\\n\\\\ |  | NULL |');
  });

  it("reports a zero-row query without claiming an empty schema", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT name, amount FROM sales WHERE 0",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    const text = await lastToolText(f.root);
    expect(text).toMatch(/0 row/);
    expect(text).not.toContain("0 columns");
    expect(text).not.toContain("| ---");
  });

  it("fails closed on malformed sqlite3 JSON", async () => {
    const f = await fixture(
      [tool("sqlite_query", { path: "sales.db", sql: "SELECT 1" }), fauxAssistantMessage("DONE")],
      (env) => {
        const original = env.exec.bind(env);
        vi.spyOn(env, "exec").mockImplementation((command, options, execContext) => {
          if (Array.isArray(command) && command[0] === "sqlite3") {
            options?.onOutput?.("{not-json", execContext, { stream: "stdout" });
            return Promise.resolve({ ok: true, value: { exitCode: 0 } });
          }
          return original(command, options, execContext);
        });
      },
    );
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect((await lastToolResult(f.root)).isError).toBe(true);
  });

  it("rejects multiple statements", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT name FROM sales; SELECT amount FROM sales",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    const result = await lastToolResult(f.root);
    expect(result.isError).toBe(true);
    expect(textOf(result.content)).toBe("Run one statement per query.");
  });

  it("accepts a trailing semicolon and comment, and a semicolon inside a string", async () => {
    const f = await fixture([
      tool("sqlite_query", {
        path: "sales.db",
        sql: "SELECT ';' AS semi; -- done",
      }),
      fauxAssistantMessage("DONE"),
    ]);
    seedSales(join(f.dir, "sales.db"));
    await prompt(f.root);
    expect((await lastToolResult(f.root)).isError).toBeFalsy();
    expect(await lastToolText(f.root)).toContain("| semi |\n| --- |\n| ; |");
  });
});

describe("parseSqliteJson", () => {
  it("treats empty output as zero rows without a schema", () => {
    expect(parseSqliteJson("")).toEqual({ ok: true, columns: [], rows: [] });
    expect(parseSqliteJson("   \n")).toEqual({ ok: true, columns: [], rows: [] });
    expect(parseSqliteJson("[]")).toEqual({ ok: true, columns: [], rows: [] });
  });

  it("rejects a second top-level value as multiple statements", () => {
    expect(parseSqliteJson('[{"1":1}]\n[{"2":2}]\n')).toEqual({
      ok: false,
      error: "Run one statement per query.",
    });
  });

  it("fails closed on malformed sqlite3 JSON", () => {
    const samples = [
      "{not-json",
      '[{"a":1}',
      '[{"a":1,}]',
      '[{"a":true}]',
      '[{"a":[1]}]',
      '[{"a":"\\u00"}]',
      '[{"a":"\n"}]',
      '[{"a":1}] x',
    ];
    for (const sample of samples) {
      const parsed = parseSqliteJson(sample);
      expect(parsed.ok, sample).toBe(false);
      if (!parsed.ok) expect(parsed.error).not.toBe("Run one statement per query.");
    }
  });
});

// Argument shapes models sent these tools in recorded durable sessions.
describe("SQLite explorer arguments", () => {
  it("take the recorded shapes and reject a field the tool does not have", () => {
    const schema = toolNamed(DurableSqlExplorer.tools, "sqlite_schema");
    const query = toolNamed(DurableSqlExplorer.tools, "sqlite_query");
    expect(toolArguments(schema, { path: "/tmp/session.sqlite" })).toEqual({
      path: "/tmp/session.sqlite",
    });
    for (const args of [
      { path: "/tmp/session.sqlite", sql: "SELECT name, type FROM sqlite_master" },
      {
        path: "/tmp/state.db",
        sql: "SELECT status, COUNT(*) AS sessions FROM sessions GROUP BY status",
      },
    ])
      expect(toolArguments(query, args)).toEqual(args);
    expect(() =>
      toolArguments(query, { path: "/tmp/state.db", sql: "SELECT 1", limit: 10 }),
    ).toThrow("limit: unknown field");
  });
});
