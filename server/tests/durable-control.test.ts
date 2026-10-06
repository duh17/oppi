import { mkdtempSync, rmSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import {
  createRegistry,
  Harness,
  type Conversation,
  type ConversationId,
  type Extension,
  type ToolRegistration,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { AgentScheduleStore } from "../src/agent-schedules.js";
import { createCliConfigStorage } from "../src/cli/connection-config.js";
import { DurableControlCli } from "../src/durable-control-cli.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { createRouteHelpers } from "../src/routes/http.js";
import type { RouteContext } from "../src/routes/types.js";
import {
  CONTROL_DECLARATIONS,
  CONTROL_SECTION,
  createDurableControl,
  type DurableControlHost,
} from "../extensions/durable/control/durable.js";
import { DurableUI, type UIRequest } from "../extensions/durable/durable-ui.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

const harnesses: Harness[] = [];
const servers: HttpServer[] = [];
const dirs: string[] = [];

afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  await Promise.all(
    servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))),
  );
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  vi.restoreAllMocks();
});

const YES = "Yes";
const YES_ALL = "Yes to all remaining in this script";

type Seen = { method: string; url: string };

/**
 * The owner API as the CLI sees it: the real agent routes over a real Agent store, and the real
 * schedule store behind the manual-run route (a run is recorded, never dispatched).
 */
async function ownerApi(dataDir: string) {
  const agents = new AgentDefinitionStore(dataDir);
  const schedules = new AgentScheduleStore(dataDir);
  const seen: Seen[] = [];
  const dispatchAgents = createAgentRoutes(
    { storage: { getAgentDefinitionStore: () => agents } } as unknown as RouteContext,
    createRouteHelpers(),
  );
  const server = createHttpServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", "http://localhost");
      seen.push({ method: req.method ?? "GET", url: req.url ?? "/" });
      const manualRun = /^\/schedules\/([^/]+)\/run$/.exec(url.pathname);
      if (req.method === "POST" && manualRun) {
        let text = "";
        for await (const chunk of req) text += String(chunk);
        const body = JSON.parse(text) as { requestId: string };
        const run = schedules.createManualRun(manualRun[1]!, body.requestId);
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ run: { id: run.id, status: run.status } }));
        return;
      }
      const handled = await dispatchAgents({
        method: req.method ?? "GET",
        path: url.pathname,
        url,
        req,
        res,
      } as never);
      if (!handled) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "not found" }));
      }
    })();
  });
  servers.push(server);
  await listenOnLocalApiFixture(server, dataDir);
  return { agents, schedules, seen };
}

/** Every Agent row, byte for byte, for "nothing changed" comparisons. */
function agentRows(agents: AgentDefinitionStore): string {
  const db = (
    agents as unknown as {
      db: { prepare(sql: string): { all(): unknown[] } };
    }
  ).db;
  return JSON.stringify([
    db.prepare("SELECT * FROM agent_definitions ORDER BY id").all(),
    db.prepare("SELECT * FROM agent_definition_versions ORDER BY id, version").all(),
    db.prepare("SELECT * FROM agent_create_requests ORDER BY idempotency_key").all(),
  ]);
}

const code = (body: string) =>
  fauxAssistantMessage([fauxToolCall("oppi_script", { code: body })], { stopReason: "toolUse" });
const query = (body: string) =>
  fauxAssistantMessage([fauxToolCall("oppi_query", { code: body })], { stopReason: "toolUse" });

async function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "oppi-durable-control-"));
  dirs.push(dir);
  createCliConfigStorage(dir).ensurePaired();
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const faux = fauxProvider();
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const api = await ownerApi(dir);
  const real = new DurableControlCli({ dataDir: dir, sessionIdOf: () => undefined });
  const run = vi.fn((...args: Parameters<DurableControlHost["run"]>) => real.run(...args));
  const host: DurableControlHost = { run };
  return { dir, models, faux, host, run, ...api };
}

async function openHarness(dir: string, models: ModelRuntime, extension: Extension) {
  const registry = createRegistry();
  registry.install(extension);
  const harness = await Harness.open(
    await openNodeSqliteStorage(join(dir, "control.sqlite")),
    {
      models,
      registry,
      env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? dir }),
      settings: { compaction: { enabled: false } },
    },
    context,
  );
  harnesses.push(harness);
  return harness;
}

async function createConversation(harness: Harness, extension: Extension, dir: string) {
  return harness.createConversation(
    {
      ownership: { kind: "ownerless" },
      agent: {
        model: { provider: "faux", modelId: "faux-1" },
        extensions: [extension],
        tools: [...(extension.tools ?? [])],
        cwd: dir,
      },
    },
    context,
  );
}

/** Answers confirm cards as they appear, in order; `undefined` cancels the card. */
function owner(conversation: Conversation, answers: Array<string | undefined>) {
  const cards: UIRequest[] = [];
  let stopped = false;
  const loop = (async () => {
    const queue = [...answers];
    while (!stopped) {
      const next = await conversation
        .commit(async (tx) => {
          const ui = await tx.doc(DurableUI, conversation.id);
          const pending = Object.values(ui.requests).find((entry) => !entry.response);
          if (!pending || queue.length === 0) return undefined;
          const value = queue.shift();
          pending.response = {
            id: pending.request.id,
            ...(value === undefined ? { cancelled: true } : { value }),
          };
          // A copy: the transaction view is gone once the commit settles.
          return JSON.parse(JSON.stringify(pending.request)) as UIRequest;
        }, context)
        // The Harness was closed under the loop (a crash in a test, or the end of one).
        .catch(() => "closed" as const);
      if (next === "closed") return;
      if (next) cards.push(next);
      else await new Promise((resolve) => setTimeout(resolve, 15));
    }
  })();
  return {
    cards,
    stop: async () => {
      stopped = true;
      await loop;
    },
  };
}

async function toolResults(conversation: Conversation) {
  const page = await conversation.entries({}, 200, undefined, context);
  return page.items
    .flatMap((entry) => entry.model ?? [])
    .filter((message) => message.role === "toolResult")
    .reverse()
    .map((message) => ({
      isError: message.isError,
      text: message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
    }));
}

async function send(conversation: Conversation, text = "go") {
  const settled = await (
    await conversation.submit({ type: "input", content: text }, context)
  ).wait(context);
  expect(settled.status).toBe("done");
}

type Fixture = Awaited<ReturnType<typeof fixture>>;

async function begin(
  f: Fixture,
  steps: FauxResponseStep[],
  answers: Array<string | undefined> = [],
) {
  f.faux.setResponses([...steps, fauxAssistantMessage("done")]);
  const extension = createDurableControl(() => f.host);
  const harness = await openHarness(f.dir, f.models, extension);
  const conversation = await createConversation(harness, extension, f.dir);
  return { ...f, extension, harness, conversation, responder: owner(conversation, answers) };
}

async function start(steps: FauxResponseStep[], answers: Array<string | undefined> = []) {
  return begin(await fixture(), steps, answers);
}

describe("oppi.control tools", () => {
  it("(a) a declined confirm leaves every Agent row byte-identical and sends nothing", async () => {
    const base = await fixture();
    const seed = base.agents.createAgent({ name: "Seed", description: "kept" });
    const f = await begin(
      base,
      [
        code(`
          const out = [];
          for (const attempt of [
            () => agents.create({ name: "Intruder" }),
            () => agents.update({ id: "${seed.id}", instructions: "rewritten" }),
          ]) {
            try { await attempt(); out.push("applied"); } catch (e) { out.push(e.message); }
          }
          return out;
        `),
      ],
      ["No", undefined],
    );
    const before = agentRows(f.agents);
    await send(f.conversation);
    await f.responder.stop();

    const [result] = await toolResults(f.conversation);
    expect(result?.isError).toBe(false);
    expect(JSON.parse(result!.text.split("\n").at(-1)!)).toEqual([
      "The owner declined this write. [declined]",
      "The owner declined this write. [declined]",
    ]);
    expect(agentRows(f.agents)).toBe(before);
    // The writes never left the process; only reads reached the API.
    expect(f.seen.filter((request) => request.method !== "GET")).toEqual([]);
    expect(f.responder.cards.map((card) => card.title)).toEqual([
      "Allow POST /agents?",
      `Allow PATCH /agents/${seed.id}?`,
    ]);
  });

  it("(b) oppi_query refuses every non-GET at the interceptor: the request is never sent", async () => {
    const f = await start([
      query(`
        const raw = await oppi(["agent", "create", "--name", "Sneaky"]);
        let wrapped;
        try { await agents.create({ name: "Sneaky" }); wrapped = "applied"; } catch (e) { wrapped = e.message; }
        return { raw, wrapped };
      `),
    ]);
    const before = agentRows(f.agents);
    await send(f.conversation);
    await f.responder.stop();

    const [result] = await toolResults(f.conversation);
    const value = JSON.parse(result!.text.split("\n").at(-1)!) as {
      raw: { ok: boolean; error: { code: string } };
      wrapped: string;
    };
    expect(value.raw).toMatchObject({ ok: false, error: { code: "read_only" } });
    expect(value.wrapped).toContain("oppi_query is read-only");
    expect(f.seen.filter((request) => request.method !== "GET")).toEqual([]);
    expect(agentRows(f.agents)).toBe(before);
    expect(f.responder.cards).toEqual([]);
  });

  it("(c) a script reaching for process, require, fetch or timers fails inside QuickJS", async () => {
    const f = await start([
      query(`
        const out = {};
        for (const [name, attempt] of Object.entries({
          process: () => process.exit(7),
          require: () => require("node:fs"),
          fetch: () => fetch("http://127.0.0.1:1/"),
          timer: () => setTimeout(() => {}, 1),
          wasm: () => new WebAssembly.Module(new Uint8Array(8)),
        })) {
          try { await attempt(); out[name] = "reached"; } catch (e) { out[name] = e.name; }
        }
        return out;
      `),
      fauxAssistantMessage("ok"),
      query(`process.exit(7)`),
    ]);
    const exit = vi.spyOn(process, "exit");
    const pid = process.pid;
    await send(f.conversation);
    await send(f.conversation, "again");
    await f.responder.stop();

    const [first, second] = await toolResults(f.conversation);
    expect(JSON.parse(first!.text)).toEqual({
      process: "ReferenceError",
      require: "ReferenceError",
      fetch: "ReferenceError",
      timer: "ReferenceError",
      wasm: "ReferenceError",
    });
    expect(second).toMatchObject({ isError: true });
    expect(second?.text).toContain("ReferenceError");
    expect(exit).not.toHaveBeenCalled();
    expect(process.pid).toBe(pid);
    expect(f.seen).toEqual([]);
  });

  it("(h) a bad flag in every command family returns an error envelope to the script and the server stays up", async () => {
    const families = [
      ["status"],
      ["quota"],
      ["models"],
      ["agent", "list"],
      ["agent", "create"],
      ["agent", "get", "x"],
      ["dictionary", "list"],
      ["workspace", "list"],
      ["worktree", "list"],
      ["session", "list"],
      ["session", "get", "x"],
      ["session", "wait", "x"],
      ["control", "open"],
      ["schedule", "list"],
      ["schedule", "run", "x"],
      ["wait", "x"],
      ["config", "get"],
      ["config", "validate"],
      ["nonsense"],
    ];
    const f = await start([
      query(`
        const results = [];
        for (const family of ${JSON.stringify(families)}) {
          const envelope = await oppi([...family, "--no-such-flag"]);
          results.push([family.join(" "), envelope.ok, typeof envelope.error?.message]);
        }
        return results;
      `),
    ]);
    const exit = vi.spyOn(process, "exit");
    const stdout = vi.spyOn(process.stdout, "write");
    const stderr = vi.spyOn(process.stderr, "write");
    const pid = process.pid;
    await send(f.conversation);
    await f.responder.stop();

    const [result] = await toolResults(f.conversation);
    expect(result?.isError).toBe(false);
    const results = JSON.parse(result!.text.split("\n").at(-1)!) as Array<
      [string, boolean, string]
    >;
    expect(results.map(([family]) => family)).toEqual(families.map((family) => family.join(" ")));
    // Every family answered with an envelope the script could read. These three ignore an
    // unknown flag and succeed; every other family refuses it with an error.
    const lenient = new Set(["status", "agent list", "config validate"]);
    expect(results.every(([, ok]) => typeof ok === "boolean")).toBe(true);
    expect(results.filter(([family, ok]) => ok && !lenient.has(family))).toEqual([]);
    expect(results.filter(([, ok, message]) => !ok && message !== "string")).toEqual([]);
    expect(exit).not.toHaveBeenCalled();
    expect(process.pid).toBe(pid);
    const reachedTerminal = [...stdout.mock.calls, ...stderr.mock.calls].filter(([chunk]) =>
      String(chunk).includes("no-such-flag"),
    );
    expect(reachedTerminal).toEqual([]);
  });

  it("(i) the rendered declarations plus the section stay under 2 KiB, and the model gets it as a prompt section", async () => {
    expect(CONTROL_SECTION).toContain(CONTROL_DECLARATIONS);
    expect(Buffer.byteLength(CONTROL_SECTION)).toBeLessThan(2048);

    const f = await start([]);
    const agent = await f.conversation.agent(context);
    expect(agent.tools.map((tool) => tool.name)).toEqual(["oppi_query", "oppi_script"]);
    const rendered = await Promise.all(
      agent.sections.map((section) =>
        section.render(
          {
            conversationId: f.conversation.id,
            agent,
            env: undefined,
            shown: {},
            read: undefined as never,
          },
          context,
        ),
      ),
    );
    expect(rendered).toContain(CONTROL_SECTION);
    await f.responder.stop();
  });

  it("asks for each write once per script and again in the next script after Yes to all", async () => {
    const f = await start(
      [
        code(`
          const a = await agents.create({ name: "A" });
          const b = await agents.create({ name: "B" });
          return [a.version, b.version];
        `),
        fauxAssistantMessage("first script done"),
        code(`return (await agents.create({ name: "C" })).version;`),
      ],
      [YES_ALL, YES],
    );
    await send(f.conversation, "first");
    await send(f.conversation, "second");
    await f.responder.stop();

    const names = f.agents.listAgentSummaries().map((agent) => agent.name);
    expect(names.sort()).toEqual(["A", "B", "C"]);
    // One card covered A and B; C, in another script, asked again.
    expect(f.responder.cards.map((card) => card.options)).toEqual([
      ["Yes", YES_ALL, "No"],
      ["Yes", YES_ALL, "No"],
    ]);
    expect(f.responder.cards).toHaveLength(2);
    expect((await toolResults(f.conversation)).map((result) => result.isError)).toEqual([
      false,
      false,
    ]);
  });

  it("shows a PATCH with a diff against the current record and passes expectedVersion through", async () => {
    const base = await fixture();
    const seed = base.agents.createAgent({
      name: "Old name",
      instructions: { mode: "append", text: "old" },
    });
    const f = await begin(
      base,
      [
        code(`
          const updated = await agents.update({ id: "${seed.id}", instructions: "new", expectedVersion: ${seed.version} });
          const stale = await oppi(["agent", "update", "${seed.id}", "--name", "Stale", "--expected-version", "1"]);
          return { updated, stale };
        `),
      ],
      [YES, YES],
    );
    await send(f.conversation);
    await f.responder.stop();

    const [card, second] = f.responder.cards;
    expect(card?.title).toBe(`Allow PATCH /agents/${seed.id}?`);
    expect(card?.message).toContain(`PATCH /agents/${seed.id}?expectedVersion=${seed.version}`);
    expect(card?.message).toContain("Request body:");
    expect(card?.message).toContain('instructions.text: "old" → "new"');
    expect(card?.message).not.toContain("No expected version");
    // The second write names its own diff; its stale version is refused by the store.
    expect(second?.message).toContain('name: "Old name" → "Stale"');
    expect(second?.message).toContain("expectedVersion=1");
    const [result] = await toolResults(f.conversation);
    const value = JSON.parse(result!.text.split("\n").at(-1)!) as {
      updated: { version: number };
      stale: { ok: boolean; error: { code: string } };
    };
    expect(value.updated.version).toBe(seed.version + 1);
    expect(value.stale).toMatchObject({ ok: false, error: { code: "AGENT_VERSION_CONFLICT" } });
    expect(f.agents.getAgent(seed.id)?.definition.instructions?.text).toBe("new");
    expect(f.agents.getAgent(seed.id)?.definition.name).toBe("Old name");
  });

  it("passes an id that starts with a dash to the API instead of reading it as a flag", async () => {
    const f = await start([
      query(
        `try { await agents.get({ id: "-Xu5kdkM" }); return "found"; } catch (e) { return e.message; }`,
      ),
    ]);
    await send(f.conversation);
    await f.responder.stop();
    const [result] = await toolResults(f.conversation);
    expect(result?.text).not.toContain("Unknown flag");
    expect(f.seen).toEqual([{ method: "GET", url: "/agents/-Xu5kdkM" }]);
  });

  it("serializes overlapping writes in call order and keeps concurrent reads isolated", async () => {
    const f = await start(
      [
        code(`
          const created = await Promise.all(["X", "Y", "Z"].map((name) => agents.create({ name })));
          const fetched = await Promise.all(created.map((agent) => agents.get({ id: agent.id })));
          return fetched.map((agent) => agent.id === created.find((c) => c.id === agent.id)?.id);
        `),
      ],
      [YES_ALL],
    );
    await send(f.conversation);
    await f.responder.stop();
    expect(f.responder.cards).toHaveLength(1);
    expect(
      f.agents
        .listAgentSummaries()
        .map((agent) => agent.name)
        .sort(),
    ).toEqual(["X", "Y", "Z"]);
    const [result] = await toolResults(f.conversation);
    expect(JSON.parse(result!.text.split("\n").at(-1)!)).toEqual([true, true, true]);
  });
});

/**
 * A crash between the confirmed write and the memo that records it. The tool is wrapped so the
 * first memo of a write hangs (or lands and then hangs); the Harness is closed there and a new
 * one over the same storage resumes the interrupted call.
 */
describe("oppi_script crash safety", () => {
  function crashing(extension: Extension, gap: "before" | "after", reached: () => void): Extension {
    const wrap = (native: ToolRegistration): ToolRegistration => ({
      ...native,
      async execute(args, api, ctx) {
        const memo = new Proxy(api.memo, {
          async apply(target, receiver, values) {
            if (String(values[0]).startsWith("oppi-call:") && values.length === 3) {
              if (gap === "after") await Reflect.apply(target, receiver, values);
              reached();
              return new Promise((_resolve, reject) => {
                ctx.abortSignal?.addEventListener("abort", () => reject(ctx.abortSignal!.reason), {
                  once: true,
                });
              });
            }
            return Reflect.apply(target, receiver, values);
          },
        });
        return native.execute(args as never, { ...api, memo }, ctx);
      },
    });
    return { ...extension, tools: (extension.tools ?? []).map(wrap) };
  }

  async function crashAndResume(f: Fixture, body: string, gap: "before" | "after") {
    f.faux.setResponses([code(body), fauxAssistantMessage("done")]);
    const extension = createDurableControl(() => f.host);
    let reached!: () => void;
    const hung = new Promise<void>((resolve) => (reached = resolve));
    const first = crashing(extension, gap, () => reached());
    let harness = await openHarness(f.dir, f.models, first);
    const conversation = await createConversation(harness, first, f.dir);
    const responder = owner(conversation, [YES, YES, YES]);
    await conversation.submit({ type: "input", content: "go" }, context);
    await hung;
    await responder.stop();
    await harness.close(context);
    harnesses.splice(harnesses.indexOf(harness), 1);

    harness = await openHarness(f.dir, f.models, extension);
    const reopened = (await harness.conversation(conversation.id, context))!;
    const resumed = owner(reopened, [YES, YES, YES]);
    harness.resume();
    await reopened.waitForIdle(context);
    await resumed.stop();
    return reopened;
  }

  it.each(["before", "after"] as const)(
    "(e) a crash %s the write is memoized leaves exactly one Agent on resume",
    async (gap) => {
      const f = await fixture();
      const conversation = await crashAndResume(
        f,
        `return (await agents.create({ name: "Once", instructions: "x" })).id;`,
        gap,
      );
      expect(f.agents.listAgentSummaries().map((agent) => agent.name)).toEqual(["Once"]);
      const [result] = await toolResults(conversation);
      expect(result?.isError).toBe(false);
      expect(JSON.parse(result!.text.split("\n").at(-1)!)).toBe(
        f.agents.listAgentSummaries()[0]!.id,
      );
      // After the memo landed, the rerun never touched the CLI; before it, the CLI ran again with
      // the same key and the store answered with the Agent it already had.
      expect(f.run).toHaveBeenCalledTimes(gap === "after" ? 1 : 2);
      expect(new Set(f.run.mock.calls.map(([, options]) => options.key)).size).toBe(1);
    },
  );

  it.each(["before", "after"] as const)(
    "(f) a retried `schedule run` %s the memo triggers one run",
    async (gap) => {
      const f = await fixture();
      const scheduleId = f.schedules.createSchedule({
        name: "Nightly",
        trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
        action: { type: "new_session", workspaceId: "ws", prompt: "go" },
      }).id;
      const conversation = await crashAndResume(
        f,
        `return await schedules.run({ id: "${scheduleId}" });`,
        gap,
      );
      const runs = f.schedules.listRuns(scheduleId);
      expect(runs).toHaveLength(1);
      const [result] = await toolResults(conversation);
      expect(result?.isError).toBe(false);
      expect(JSON.parse(result!.text.split("\n").at(-1)!)).toMatchObject({ id: runs[0]!.id });
      // The retry sent the same request id, so the store kept one run.
      expect(f.seen.filter((request) => request.method === "POST")).toHaveLength(
        gap === "after" ? 1 : 2,
      );
    },
  );

  it("fails a rerun that is no longer the call it remembers, instead of writing something else", async () => {
    const f = await fixture();
    const conversation = await crashAndResume(
      f,
      `return (await agents.create({ name: "n" + Math.random() })).id;`,
      "after",
    );
    expect(f.agents.listAgentSummaries()).toHaveLength(1);
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(true);
    expect(result?.text).toContain("is not the call that already ran before the restart");
  });
});
