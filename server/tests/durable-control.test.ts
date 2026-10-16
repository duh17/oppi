import { mkdtempSync, rmSync } from "node:fs";
import { createServer as createHttpServer, type Server as HttpServer } from "node:http";
import { tmpdir } from "node:os";
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
import {
  createRegistry,
  Harness,
  type Conversation,
  type ConversationId,
  type Extension,
} from "@earendil-works/pi-durable";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { AgentScheduleStore } from "../src/agent-schedules.js";
import { createCliConfigStorage } from "../src/cli/connection-config.js";
import { DurableControlCli } from "../src/durable-control-cli.js";
import { DurableHarness } from "../src/durable-harness.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createScheduleRoutes } from "../src/routes/schedules.js";
import type { RouteContext } from "../src/routes/types.js";
import { CONTROL_SECTION, createDurableControl } from "../extensions/durable/control/durable.js";
import type { DurableControlHost } from "../src/durable-extension-api.js";
import { DurableUI, type UIRequest } from "../extensions/durable/durable-ui.js";
import { listenOnLocalApiFixture } from "./harness/local-api-socket.js";

const harnesses: Harness[] = [];
const servers: HttpServer[] = [];
const dirs: string[] = [];
const runtimes: DurableHarness[] = [];

afterEach(async () => {
  await Promise.all(harnesses.splice(0).map((harness) => harness.close(context)));
  await Promise.all(runtimes.splice(0).map((runtime) => runtime.closeAll()));
  await Promise.all(
    servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))),
  );
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  vi.restoreAllMocks();
});

const YES = "Yes";
const YES_ALL = "Yes to all remaining in this script";
const NO = "No";

type Seen = { method: string; url: string };

/**
 * The owner API as the CLI sees it: the real agent routes over a real Agent store, and the real
 * schedule store behind the manual-run route (a run is recorded, never dispatched).
 */
async function ownerApi(dataDir: string) {
  const agents = new AgentDefinitionStore(dataDir);
  const schedules = new AgentScheduleStore(dataDir);
  const seen: Seen[] = [];
  /** Bodies of `POST /sessions/:id/command`, which is only recorded: the turn dedupe is the server's. */
  const commands: Array<{ clientTurnId?: string; message?: string }> = [];
  /** Paths whose next request is answered late, to make calls finish in another order. */
  const delayFirst = new Set<string>();
  const routeContext = {
    storage: {
      getAgentDefinitionStore: () => agents,
      getAgentScheduleStore: () => schedules,
      getWorkspace: (id: string) => (id === "ws" ? { id, name: "ws" } : undefined),
    },
  } as unknown as RouteContext;
  const dispatchAgents = createAgentRoutes(routeContext, createRouteHelpers());
  const dispatchSchedules = createScheduleRoutes(routeContext, createRouteHelpers());
  const server = createHttpServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", "http://localhost");
      seen.push({ method: req.method ?? "GET", url: req.url ?? "/" });
      if (delayFirst.delete(url.pathname)) await new Promise((resolve) => setTimeout(resolve, 150));
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
      const sessionLookup = req.method === "GET" && url.pathname === "/sessions";
      if (sessionLookup) {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ sessions: [{ id: url.searchParams.get("idPrefix") }] }));
        return;
      }
      if (req.method === "POST" && /^\/sessions\/[^/]+\/command$/.test(url.pathname)) {
        let text = "";
        for await (const chunk of req) text += String(chunk);
        commands.push(JSON.parse(text) as { clientTurnId?: string; message?: string });
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ messages: [] }));
        return;
      }
      if (req.method === "GET" && url.pathname === "/workspaces/ws") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ workspace: { id: "ws", name: "ws" } }));
        return;
      }
      const routed = { method: req.method ?? "GET", path: url.pathname, url, req, res } as never;
      const handled = (await dispatchSchedules(routed)) || (await dispatchAgents(routed));
      if (!handled) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "not found" }));
      }
    })();
  });
  servers.push(server);
  await listenOnLocalApiFixture(server, dataDir);
  return { agents, schedules, seen, commands, delayFirst };
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

/** A codemode script, as the model writes one. */
const script = (body: string) =>
  fauxAssistantMessage([fauxToolCall("codemode", { code: body })], { stopReason: "toolUse" });
/** A control tool called by the model directly. */
const direct = (name: string, args: Record<string, unknown>) =>
  fauxAssistantMessage([fauxToolCall(name, args)], { stopReason: "toolUse" });

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
  // Every conversation these tests open stands for the control conversation.
  const real = new DurableControlCli({
    dataDir: dir,
    sessionIdOf: () => "control-session",
  }).forConversation("control", 1 as ConversationId)!;
  const run = vi.fn((...args: Parameters<DurableControlHost["run"]>) => real.run(...args));
  const host: DurableControlHost = { run };
  // The server's own codemode for control: its sandbox, memory limit, and options.
  const runtime = new DurableHarness(dir);
  runtimes.push(runtime);
  return { dir, models, faux, host, run, real, codemode: runtime.controlCodemode, ...api };
}

type Fixture = Awaited<ReturnType<typeof fixture>>;

async function openHarness(f: Fixture, extensions: readonly Extension[]) {
  const registry = createRegistry();
  for (const extension of extensions) registry.install(extension);
  const harness = await Harness.open(
    await openNodeSqliteStorage(join(f.dir, "control.sqlite")),
    {
      models: f.models,
      registry,
      env: ({ cwd }) => new NodeExecutionEnv({ cwd: cwd ?? f.dir }),
      settings: { compaction: { enabled: false } },
    },
    context,
  );
  harnesses.push(harness);
  return harness;
}

async function createConversation(harness: Harness, extensions: readonly Extension[], dir: string) {
  return harness.createConversation(
    {
      ownership: { kind: "ownerless" },
      agent: {
        model: { provider: "faux", modelId: "faux-1" },
        extensions: [...extensions],
        tools: extensions.flatMap((extension) => extension.tools ?? []),
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

/** The model's tool results, oldest first. */
async function toolResults(conversation: Conversation) {
  const page = await conversation.entries({}, 200, undefined, context);
  return page.items
    .flatMap((entry) => entry.model ?? [])
    .filter((message) => message.role === "toolResult")
    .reverse()
    .map((message) => ({
      toolName: message.toolName,
      isError: message.isError,
      text: message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
    }));
}

/** What a script returned: the last line of its codemode result (a string as is, else JSON). */
function returned(result: { text: string } | undefined): unknown {
  const line = result!.text.split("\n").at(-1)!;
  try {
    return JSON.parse(line);
  } catch {
    return line;
  }
}

async function send(conversation: Conversation, text = "go") {
  const settled = await (
    await conversation.submit({ type: "input", content: text }, context)
  ).wait(context);
  expect(settled.status).toBe("done");
}

async function begin(
  f: Fixture,
  steps: FauxResponseStep[],
  answers: Array<string | undefined> = [],
) {
  f.faux.setResponses([...steps, fauxAssistantMessage("done")]);
  const extensions = [createDurableControl(() => f.host), f.codemode];
  const harness = await openHarness(f, extensions);
  const conversation = await createConversation(harness, extensions, f.dir);
  return { ...f, extensions, harness, conversation, responder: owner(conversation, answers) };
}

async function start(steps: FauxResponseStep[], answers: Array<string | undefined> = []) {
  return begin(await fixture(), steps, answers);
}

describe("oppi.control tools", () => {
  it("offers every control tool to the model and to codemode scripts, with the control section", async () => {
    expect(Buffer.byteLength(CONTROL_SECTION)).toBeLessThan(1024);
    const f = await start([]);
    const agent = await f.conversation.agent(context);
    const names = agent.tools.map((tool) => tool.name);
    expect(names).toEqual(expect.arrayContaining(["oppi", "agents_create", "codemode"]));
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
    // Scripts see the same tools, declared in pi-durable's own codemode section.
    const codemodeSection = rendered.find((text) => text?.includes("agents_create("));
    expect(codemodeSection).toBeDefined();
    await f.responder.stop();
  });

  it("(a) a declined confirm leaves every Agent row byte-identical and sends nothing", async () => {
    const base = await fixture();
    const seed = base.agents.createAgent({ name: "Seed", description: "kept" });
    const f = await begin(
      base,
      [
        script(`
          const out = [];
          for (const attempt of [
            () => tools.agents_create({ name: "Intruder" }),
            () => tools.agents_update({ id: "${seed.id}", instructions: "rewritten" }),
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
    expect(returned(result)).toEqual([
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

  it("runs a direct call like a script call: a write asks Yes or No, a read just reads", async () => {
    const f = await start(
      [direct("agents_create", { name: "Direct" }), direct("agents_list", {})],
      [YES],
    );
    await send(f.conversation);
    await f.responder.stop();

    // Outside a script there is nothing for "Yes to all" to cover.
    expect(f.responder.cards.map((card) => card.options)).toEqual([["Yes", "No"]]);
    const [created, list] = await toolResults(f.conversation);
    expect(created).toMatchObject({ toolName: "agents_create", isError: false });
    expect(JSON.parse(created!.text)).toMatchObject({ id: expect.any(String), version: 1 });
    expect(list).toMatchObject({ toolName: "agents_list", isError: false });
    expect(JSON.parse(list!.text).agents.map((agent: { name: string }) => agent.name)).toEqual([
      "Direct",
    ]);
  });

  it("(c) a script reaching for process, require, fetch or timers fails inside QuickJS", async () => {
    const f = await start([
      script(`
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
    ]);
    const exit = vi.spyOn(process, "exit");
    const pid = process.pid;
    await send(f.conversation);
    await f.responder.stop();

    const [first] = await toolResults(f.conversation);
    expect(returned(first)).toEqual({
      process: "ReferenceError",
      require: "ReferenceError",
      fetch: "ReferenceError",
      timer: "ReferenceError",
      wasm: "ReferenceError",
    });
    expect(exit).not.toHaveBeenCalled();
    expect(process.pid).toBe(pid);
    expect(f.seen).toEqual([]);
  });

  it("(h) a bad flag in every command family returns an error envelope and the server stays up", async () => {
    const families = [
      ["quota"],
      ["models"],
      ["agent", "list"],
      ["agent", "get", "x"],
      ["dictionary", "list"],
      ["workspace", "list"],
      ["worktree", "list"],
      ["session", "list"],
      ["session", "get", "x"],
      ["session", "wait", "x"],
      ["schedule", "list"],
      ["wait", "x"],
      ["config", "get"],
      ["config", "validate"],
      ["nonsense"],
    ];
    const f = await start([
      script(`
        const results = [];
        for (const family of ${JSON.stringify(families)}) {
          const envelope = await tools.oppi({ argv: [...family, "--no-such-flag"] });
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
    const results = returned(result) as Array<[string, boolean, string]>;
    expect(results.map(([family]) => family)).toEqual(families.map((family) => family.join(" ")));
    // Every family answered with an envelope the script could read. These ignore an
    // unknown flag and succeed; every other family refuses it with an error.
    const lenient = new Set(["agent list", "schedule list", "config validate"]);
    expect(results.every(([, ok]) => typeof ok === "boolean")).toBe(true);
    expect(results.filter(([family, ok]) => ok && !lenient.has(family))).toEqual([]);
    expect(results.filter(([, ok, message]) => !ok && message !== "string")).toEqual([]);
    expect(exit).not.toHaveBeenCalled();
    expect(process.pid).toBe(pid);
    const reachedTerminal = [...stdout.mock.calls, ...stderr.mock.calls].filter(([chunk]) =>
      String(chunk).includes("no-such-flag"),
    );
    expect(reachedTerminal).toEqual([]);
    // Nothing in these was a write the owner had to see.
    expect(f.responder.cards).toEqual([]);
  });

  it("asks for each write once per script and again in the next script after Yes to all", async () => {
    const f = await start(
      [
        script(`
          const a = await tools.agents_create({ name: "A" });
          const b = await tools.agents_create({ name: "B" });
          return [a.version, b.version];
        `),
        fauxAssistantMessage("first script done"),
        script(`return (await tools.agents_create({ name: "C" })).version;`),
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
        script(`
          const updated = await tools.agents_update({ id: "${seed.id}", instructions: "new", expectedVersion: ${seed.version} });
          // After --: a positional that starts with "-" is a flag.
          const stale = await tools.oppi({ argv: [
            "agent", "update", "--name", "Stale", "--expected-version", "1", "--", "${seed.id}",
          ] });
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
    const value = returned(result) as {
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
      script(
        `try { await tools.agents_get({ id: "-Xu5kdkM" }); return "found"; } catch (e) { return e.message; }`,
      ),
    ]);
    await send(f.conversation);
    await f.responder.stop();
    const [result] = await toolResults(f.conversation);
    expect(result?.text).not.toContain("Unknown flag");
    expect(f.seen).toEqual([{ method: "GET", url: "/agents/-Xu5kdkM" }]);
  });

  it("refuses a body too large for the confirm card, with or without Yes to all, and sends nothing", async () => {
    const f = await start(
      [
        script(`
          const out = [];
          for (const attempt of [
            () => tools.agents_create({ name: "Big", instructions: "x".repeat(7000) }),
            () => tools.agents_create({ name: "Small" }),
            () => tools.agents_create({ name: "Big again", instructions: "y".repeat(7000) }),
          ]) {
            try { await attempt(); out.push("applied"); } catch (e) { out.push(e.message); }
          }
          return out;
        `),
      ],
      [YES_ALL],
    );
    await send(f.conversation);
    await f.responder.stop();

    const out = returned((await toolResults(f.conversation))[0]) as string[];
    expect(out[0]).toMatch(/at most 6000.*nothing was sent.*\[body_too_large\]/);
    expect(out[1]).toBe("applied");
    // Yes to all, given for the small write, does not carry an unreadable body past the card.
    expect(out[2]).toContain("[body_too_large]");
    expect(f.agents.listAgentSummaries().map((agent) => agent.name)).toEqual(["Small"]);
    expect(f.seen.filter((request) => request.method === "POST")).toHaveLength(1);
    expect(f.responder.cards).toHaveLength(1);
  });

  it("does not cancel a confirm card the owner has not answered within the sandbox's 5 minute default", async () => {
    // Shrink a 5 minute timer to 300 ms so waiting through it takes under a second; any other
    // timer is untouched.
    const realSetTimeout = globalThis.setTimeout;
    vi.spyOn(globalThis, "setTimeout").mockImplementation(((
      handler: () => void,
      delay?: number,
      ...rest: unknown[]
    ) =>
      realSetTimeout(
        handler,
        delay === 300_000 ? 300 : delay,
        ...rest,
      )) as unknown as typeof setTimeout);
    const f = await start([
      script(`return (await tools.agents_create({ name: "Late" })).version;`),
    ]);
    const settled = (await f.conversation.submit({ type: "input", content: "go" }, context)).wait(
      context,
    );
    await new Promise((resolve) => realSetTimeout(resolve, 900));
    expect(f.agents.listAgentSummaries()).toEqual([]);
    const answer = owner(f.conversation, [YES]);
    expect((await settled).status).toBe("done");
    await answer.stop();
    await f.responder.stop();

    const [result] = await toolResults(f.conversation);
    expect(result?.isError).toBe(false);
    expect(f.agents.listAgentSummaries().map((agent) => agent.name)).toEqual(["Late"]);
  });

  it("stops a script that outgrows the VM's memory limit without hurting the server", async () => {
    const f = await start([
      script(`const hoard = []; for (;;) hoard.push(new Array(1e6).fill(0));`),
    ]);
    const pid = process.pid;
    await send(f.conversation);
    await f.responder.stop();
    const [result] = await toolResults(f.conversation);
    expect(result?.isError).toBe(true);
    expect(result?.text).toMatch(/out of memory/i);
    expect(process.pid).toBe(pid);
  });

  it("gives scripts one sessions_wait shape for one id, a timeout, and --all", async () => {
    const f = await start([
      script(`
        const out = [];
        for (const args of [{ ids: ["a"] }, { ids: ["a", "b"], timeout: "1s" }, { ids: ["a", "b"], all: true }]) {
          try { out.push(await tools.sessions_wait(args)); } catch (e) { out.push(e.message); }
        }
        return out;
      `),
    ]);
    // The `oppi session wait` JSON data of each case (`cli/commands/session.ts`).
    const answers: Array<Record<string, unknown>> = [
      { session_id: "a", reason: "idle", status: "ready" },
      {
        timed_out: true,
        code: "wait_timeout",
        condition: "any",
        pending: ["b"],
        sessions: [
          { session_id: "a", status: "ready", tools_this_turn: 0 },
          { session_id: "b", status: null, tools_this_turn: 2 },
        ],
      },
      { condition: "all", sessions: [{ session_id: "a", status: "ready" }] },
    ];
    f.run.mockImplementation(async (argv, options) =>
      argv[0] === "session" && argv[1] === "wait"
        ? { envelope: { ok: true, data: answers.shift() as never }, wrote: false }
        : f.real.run(argv, options),
    );
    await send(f.conversation);
    await f.responder.stop();

    expect(returned((await toolResults(f.conversation))[0])).toEqual([
      { timed_out: false, sessions: [{ session_id: "a", status: "ready", reason: "idle" }] },
      {
        timed_out: true,
        sessions: [
          { session_id: "a", status: "ready", tools_this_turn: 0 },
          { session_id: "b", status: null, tools_this_turn: 2 },
        ],
      },
      { timed_out: false, sessions: [{ session_id: "a", status: "ready" }] },
    ]);
  });

  it("sends nothing when the call is stopped as the owner's answer arrives", async () => {
    const f = await fixture();
    const stop = new AbortController();
    const outcome = await f.host
      .run(["agent", "create", "--name", "Too late"], {
        conversationId: 1 as ConversationId,
        key: "9",
        signal: stop.signal,
        onWrite: async () => stop.abort(),
      })
      .then(
        () => "settled",
        () => "aborted",
      );
    expect(outcome).toBe("aborted");
    expect(f.seen.filter((request) => request.method !== "GET")).toEqual([]);
    expect(f.agents.listAgentSummaries()).toEqual([]);
  });

  it("asks overlapping writes one card at a time, so Yes to all covers the ones behind it", async () => {
    const f = await start(
      [
        script(`
          const created = await Promise.all(["X", "Y", "Z"].map((name) => tools.agents_create({ name })));
          const fetched = await Promise.all(created.map((agent) => tools.agents_get({ id: agent.id })));
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
    expect(returned((await toolResults(f.conversation))[0])).toEqual([true, true, true]);
    // Each write is its own call, with its own replay key.
    const keys = f.run.mock.calls
      .filter(([argv]) => argv[1] === "create")
      .map(([, options]) => options.key);
    expect(new Set(keys).size).toBe(3);
  });
});

/**
 * A server crash in the middle of a script. The host's `run` hangs at one call, before or after
 * the CLI ran; the Harness is closed there, and a new one over the same storage resumes. pi-durable's
 * codemode replays the script: finished calls are handed their results again, never run again.
 */
describe("control script crash safety", () => {
  async function crashAndResume(
    f: Fixture,
    body: string,
    crash: { call: number; gap: "before" | "after" },
    answers: Array<string | undefined> = [YES, YES, YES],
  ) {
    let reached!: () => void;
    const hung = new Promise<void>((resolve) => (reached = resolve));
    let calls = 0;
    f.run.mockImplementation(async (argv, options) => {
      if (calls++ !== crash.call) return f.real.run(argv, options);
      if (crash.gap === "after") await f.real.run(argv, options);
      reached();
      return new Promise((_resolve, reject) => {
        options.signal.addEventListener("abort", () => reject(options.signal.reason), {
          once: true,
        });
      });
    });
    f.faux.setResponses([script(body), fauxAssistantMessage("done")]);
    const extensions = [createDurableControl(() => f.host), f.codemode];
    let harness = await openHarness(f, extensions);
    const conversation = await createConversation(harness, extensions, f.dir);
    const responder = owner(conversation, answers);
    await conversation.submit({ type: "input", content: "go" }, context);
    await hung;
    await responder.stop();
    await harness.close(context);
    harnesses.splice(harnesses.indexOf(harness), 1);

    harness = await openHarness(f, extensions);
    const reopened = (await harness.conversation(conversation.id, context))!;
    const resumed = owner(reopened, answers.slice(responder.cards.length));
    harness.resume();
    await reopened.waitForIdle(context);
    await resumed.stop();
    return Object.assign(reopened, { cards: [...responder.cards, ...resumed.cards] });
  }

  it("(e) a crash after an approved write reached the store leaves exactly one Agent", async () => {
    const f = await fixture();
    const conversation = await crashAndResume(
      f,
      `return (await tools.agents_create({ name: "Once", instructions: "x" })).id;`,
      { call: 0, gap: "after" },
    );
    expect(f.agents.listAgentSummaries().map((agent) => agent.name)).toEqual(["Once"]);
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(false);
    expect(returned(result)).toBe(f.agents.listAgentSummaries()[0]!.id);
    // The call ran again with the same key, and the store answered with the Agent it had. The
    // owner's answer was kept with the call: one card.
    expect(f.run).toHaveBeenCalledTimes(2);
    expect(new Set(f.run.mock.calls.map(([, options]) => options.key)).size).toBe(1);
    expect(conversation.cards).toHaveLength(1);
  });

  it("(f) a retried `schedules_run` triggers one run", async () => {
    const f = await fixture();
    const scheduleId = f.schedules.createSchedule({
      name: "Nightly",
      trigger: { type: "every", intervalMs: 3_600_000, timeZone: "UTC" },
      action: { type: "new_session", workspaceId: "ws", prompt: "go" },
    }).id;
    const conversation = await crashAndResume(
      f,
      `return await tools.schedules_run({ id: "${scheduleId}" });`,
      { call: 0, gap: "after" },
    );
    const runs = f.schedules.listRuns(scheduleId);
    expect(runs).toHaveLength(1);
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(false);
    expect(returned(result)).toMatchObject({ id: runs[0]!.id });
    // The retry sent the same request id, so the store kept one run.
    expect(f.seen.filter((request) => request.method === "POST")).toHaveLength(2);
  });

  it("(e2) a key the script chose does not make the rerun a different write", async () => {
    const f = await fixture();
    const conversation = await crashAndResume(
      f,
      `return await tools.oppi({ argv: ["agent", "create", "--name", "Once", "--idempotency-key", "t" + Math.random()] });`,
      { call: 0, gap: "after" },
    );
    expect(f.agents.listAgentSummaries().map((agent) => agent.name)).toEqual(["Once"]);
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(false);
    expect(returned(result)).toMatchObject({ ok: true });
    // Two POSTs reached the API, the second answered from the key the first stored.
    expect(f.seen.filter((request) => request.method === "POST")).toHaveLength(2);
  });

  it("(g) a retried `session send` carries the same turn id, whatever the script passed", async () => {
    const f = await fixture();
    const session = "11111111-1111-4111-8111-111111111111";
    await crashAndResume(
      f,
      `return await tools.oppi({ argv: ["session", "send", "${session}", "--text", "hello", "--turn-id", "t" + Math.random()] });`,
      { call: 0, gap: "after" },
    );
    expect(f.commands).toHaveLength(2);
    const turns = new Set(f.commands.map((command) => command.clientTurnId));
    expect(turns.size).toBe(1);
    expect([...turns][0]).toMatch(/^\d+:[0-9a-f]{12}$/);
  });

  it("(h) schedules_create binds a saved Agent, and a retried create makes no second schedule", async () => {
    const f = await fixture();
    const scout = f.agents.createAgent({ name: "scout" });
    const conversation = await crashAndResume(
      f,
      `return await tools.schedules_create({
        name: "Daily scout", prompt: "Look around", workspace: "ws", agent: "scout",
        cron: "0 9 * * *", tz: "America/Los_Angeles",
      });`,
      { call: 0, gap: "after" },
    );
    const created = f.schedules.listSchedules();
    expect(created).toHaveLength(1);
    expect(created[0]).toMatchObject({
      name: "Daily scout",
      trigger: { type: "cron", expression: "0 9 * * *", timeZone: "America/Los_Angeles" },
      action: { type: "new_session", workspaceId: "ws", agentId: scout.id, prompt: "Look around" },
    });
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(false);
    expect(returned(result)).toMatchObject({ id: created[0]!.id });
    expect(f.seen.filter((request) => request.method === "POST")).toHaveLength(2);
  });

  it("refuses a rerun whose write is not the one the owner said Yes to, even with Yes to all", async () => {
    const f = await fixture();
    let reached!: () => void;
    const hung = new Promise<void>((resolve) => (reached = resolve));
    let calls = 0;
    // First run: the owner answers the card, then the process dies before the write is sent.
    // Rerun: the same call now builds another request, as a name that resolves elsewhere would.
    f.run.mockImplementation(async (argv, options) => {
      if (calls++ === 0)
        return f.real.run(argv, {
          ...options,
          onWrite: async (write) => {
            await options.onWrite!(write);
            reached();
            await new Promise((_resolve, reject) =>
              options.signal.addEventListener("abort", () => reject(options.signal.reason), {
                once: true,
              }),
            );
          },
        });
      return f.real.run(
        argv.map((word) => (word === "Approved" ? "Swapped" : word)),
        options,
      );
    });
    f.faux.setResponses([
      script(
        `try { await tools.agents_create({ name: "Approved" }); return "sent"; } catch (e) { return e.message; }`,
      ),
      fauxAssistantMessage("done"),
    ]);
    const extensions = [createDurableControl(() => f.host), f.codemode];
    let harness = await openHarness(f, extensions);
    const conversation = await createConversation(harness, extensions, f.dir);
    const responder = owner(conversation, [YES_ALL]);
    await conversation.submit({ type: "input", content: "go" }, context);
    await hung;
    await responder.stop();
    await harness.close(context);
    harnesses.splice(harnesses.indexOf(harness), 1);

    harness = await openHarness(f, extensions);
    const reopened = (await harness.conversation(conversation.id, context))!;
    const resumed = owner(reopened, [YES]);
    harness.resume();
    await reopened.waitForIdle(context);
    await resumed.stop();

    expect(returned((await toolResults(reopened))[0])).toMatch(/\[card_changed\]$/);
    // Neither request reached the store, and the owner was never asked about the swapped one.
    expect(f.seen.filter((request) => request.method === "POST")).toEqual([]);
    expect(f.agents.listAgentSummaries()).toEqual([]);
    expect([...responder.cards, ...resumed.cards]).toHaveLength(1);
  });

  it("resumes a list-then-archive loop over the original set, one confirm per write", async () => {
    const f = await fixture();
    const doomed = ["tmp-1", "tmp-2", "tmp-3"].map((name) => f.agents.createAgent({ name }).id);
    const kept = f.agents.createAgent({ name: "keep" }).id;
    // Call 0 is the list and call 1 the first archive; the crash lands as the second archive
    // (call 2) starts, after the first one finished.
    const conversation = await crashAndResume(
      f,
      `
        const { agents: all } = await tools.agents_list({});
        const ids = all.filter((agent) => agent.name.startsWith("tmp-")).map((agent) => agent.id);
        for (const id of ids) await tools.agents_archive({ id });
        return ids;
      `,
      { call: 2, gap: "before" },
    );
    expect(f.agents.listAgentSummaries().map((agent) => agent.id)).toEqual([kept]);
    // A fresh list would only have shown two; the script still archived all three.
    const [result] = await toolResults(conversation);
    expect(result?.isError).toBe(false);
    expect((returned(result) as string[]).sort()).toEqual([...doomed].sort());
    expect(conversation.cards).toHaveLength(3);
    // The list and the first archive were not run again.
    expect(f.run).toHaveBeenCalledTimes(5);
    expect(f.seen.filter((request) => request.method === "DELETE")).toHaveLength(3);
  });
});
