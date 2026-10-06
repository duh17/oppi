import { mkdtempSync, rmSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import { createCliConfigStorage } from "../src/cli/connection-config.js";
import {
  withLocalApiInterceptor,
  type LocalApiInterceptedRequest,
} from "../src/cli/local-api-client.js";
import { runCli } from "../src/cli/runner.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

const tempDirs: string[] = [];
const servers: HttpServer[] = [];

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))),
  );
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

function pairedDataDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-hooks-"));
  tempDirs.push(dir);
  createCliConfigStorage(dir).ensurePaired();
  return dir;
}

type Seen = { method?: string; url?: string; body: string };

/** A local API that records what reached it and answers `agent get <id>` for any id. */
async function fakeServer(
  dataDir: string,
  options: { delayMs?: (id: string) => number } = {},
): Promise<Seen[]> {
  const seen: Seen[] = [];
  const server = createHttpServer((req, res) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => (body += String(chunk)));
    req.on("end", () => {
      seen.push({ method: req.method, url: req.url, body });
      const id = decodeURIComponent(req.url?.split("/").pop() ?? "");
      setTimeout(
        () => {
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(
            JSON.stringify({
              agent: { id, name: `Agent ${id}`, status: "active", version: 1 },
            }),
          );
        },
        options.delayMs?.(id) ?? 0,
      );
    });
  });
  servers.push(server);
  await listenOnLocalApiFixture(server, dataDir);
  return seen;
}

const hostOptions = { forceJson: true, captureHuman: true } as const;

describe("local API interceptor", () => {
  it("sees every request with method, path, and body, and can deny a write before it is sent", async () => {
    const dataDir = pairedDataDir();
    const seen = await fakeServer(dataDir);
    const intercepted: LocalApiInterceptedRequest[] = [];
    const interceptor = (request: LocalApiInterceptedRequest): void => {
      intercepted.push(request);
      if (request.method !== "GET") {
        throw Object.assign(new Error("denied by test"), { code: "request_denied" });
      }
    };

    const read = await withLocalApiInterceptor(interceptor, () =>
      runCli(["agent", "get", "a1"], { dataDir, ...hostOptions }),
    );
    expect(read.json).toMatchObject({ ok: true, data: { agent: { id: "a1" } } });

    const write = await withLocalApiInterceptor(interceptor, () =>
      runCli(["agent", "archive", "a1"], { dataDir, ...hostOptions }),
    );
    expect(write.ok).toBe(false);
    expect(write.json).toMatchObject({ ok: false, error: { message: "denied by test" } });

    const create = await withLocalApiInterceptor(interceptor, () =>
      runCli(["agent", "create", "--name", "Scribe", "--idempotency-key", "k1"], {
        dataDir,
        ...hostOptions,
      }),
    );
    expect(create.ok).toBe(false);

    expect(intercepted.map((r) => [r.method, r.path])).toEqual([
      ["GET", "/agents/a1"],
      ["DELETE", "/agents/a1"],
      ["POST", "/agents"],
    ]);
    expect(intercepted[2]?.body).toMatchObject({ name: "Scribe", idempotencyKey: "k1" });
    // Only the allowed read reached the server; denied writes never left the process.
    expect(seen.map((r) => [r.method, r.url])).toEqual([["GET", "/agents/a1"]]);
  });

  it("cannot rewrite the request it is shown", async () => {
    const dataDir = pairedDataDir();
    const seen = await fakeServer(dataDir);
    await withLocalApiInterceptor(
      (request) => {
        const body = request.body as Record<string, unknown> | undefined;
        expect(() => {
          if (body) body.name = "Tampered";
        }).toThrow();
      },
      () => runCli(["agent", "create", "--name", "Original"], { dataDir, ...hostOptions }),
    );
    expect(JSON.parse(seen[0]!.body)).toMatchObject({ name: "Original" });
  });

  it("scopes by async context: concurrent runs do not see each other's requests", async () => {
    const dataDir = pairedDataDir();
    await fakeServer(dataDir);
    const a: string[] = [];
    const b: string[] = [];
    await Promise.all([
      withLocalApiInterceptor(
        (r) => void a.push(r.path),
        () => runCli(["agent", "get", "from-a"], { dataDir, ...hostOptions }),
      ),
      withLocalApiInterceptor(
        (r) => void b.push(r.path),
        () => runCli(["agent", "get", "from-b"], { dataDir, ...hostOptions }),
      ),
    ]);
    expect(a).toEqual(["/agents/from-a"]);
    expect(b).toEqual(["/agents/from-b"]);
  });
});

describe("runCli host isolation", () => {
  it("captures concurrent in-process runs separately", async () => {
    const dataDir = pairedDataDir();
    const ids = Array.from({ length: 12 }, (_, index) => `agent-${index}`);
    // Later ids answer first, so completions interleave against start order.
    await fakeServer(dataDir, { delayMs: (id) => (ids.length - ids.indexOf(id)) * 5 });

    const results = await Promise.all(
      ids.map((id) => runCli(["agent", "get", id], { dataDir, ...hostOptions })),
    );

    results.forEach((result, index) => {
      const id = ids[index]!;
      expect(result.ok, id).toBe(true);
      expect(result.json, id).toMatchObject({ ok: true, data: { agent: { id } } });
      expect(JSON.parse(result.stdout).data.agent.name, id).toBe(`Agent ${id}`);
      expect(result.humanOutput, id).toContain(`Agent ${id}`);
      for (const other of ids.filter((candidate) => candidate !== id)) {
        expect(result.stdout, `${id} saw ${other}`).not.toContain(`"${other}"`);
        expect(result.humanOutput, `${id} saw ${other}`).not.toMatch(new RegExp(`${other}(?!\\d)`));
      }
    });
  });

  // Every command family, with a call that fails: the error paths are where `process.exit`,
  // `console.log`, and stderr writes live. In either output mode the host process must stay up
  // and silent, and the failure must come back as a result.
  const failing: Array<[string, string[]]> = [
    ["status", ["status", "--bogus", "x", "-z"]],
    ["quota", ["quota"]],
    ["models", ["models"]],
    ["agent", ["agent", "list", "-z"]],
    ["agent (request)", ["agent", "get", "a"]],
    ["dictionary", ["dictionary", "list"]],
    ["workspace", ["workspace", "list"]],
    ["worktree", ["worktree", "list", "--workspace", "w"]],
    ["session (flag)", ["session", "list", "--bogus"]],
    ["session (usage)", ["session", "create"]],
    ["session (request)", ["session", "get", "s"]],
    ["schedule", ["schedule", "list"]],
    ["wait", ["wait", "session", "s"]],
    ["config", ["config", "get", "no.such.key"]],
    ["control (flag)", ["control", "open", "--bogus"]],
    ["control (usage)", ["control"]],
    ["unknown command", ["nosuchcommand"]],
    ["unknown flag", ["session", "list", "-z"]],
  ];

  it.each([
    ["forced JSON", hostOptions],
    ["human output", { captureHuman: true } as const],
  ])("never exits or writes outside the capture on a failing call (%s)", async (_mode, mode) => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-hooks-unpaired-"));
    tempDirs.push(dataDir);
    const exit = vi.spyOn(process, "exit").mockImplementation(((code?: number) => {
      throw new Error(`process.exit(${code}) reached`);
    }) as never);
    const stdout = vi.spyOn(process.stdout, "write").mockImplementation(() => true);
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const outcomes: Array<[string, boolean, string | undefined]> = [];
    try {
      for (const [label, args] of failing) {
        const result = await runCli(args, { dataDir, ...mode });
        outcomes.push([label, result.ok, result.error?.message]);
      }
    } finally {
      exit.mockRestore();
      stdout.mockRestore();
      stderr.mockRestore();
      log.mockRestore();
      error.mockRestore();
    }

    expect(exit).not.toHaveBeenCalled();
    expect(stdout).not.toHaveBeenCalled();
    expect(stderr).not.toHaveBeenCalled();
    expect(log).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
    // `status` reports local state and may succeed; every other family returns an error result.
    for (const [label, ok, message] of outcomes) {
      if (label === "status") continue;
      expect(ok, label).toBe(false);
      expect(message, label).toEqual(expect.any(String));
    }
  });
});
