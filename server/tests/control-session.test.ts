import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { AgentDoc, type ConversationId } from "@earendil-works/pi-durable";

import { ProjectContextDoc } from "../extensions/durable/project-context/contract.js";
import { isControlConversation } from "../src/control-session.js";
import { controlConversationTools } from "../src/durable-control-conversation.js";
import type { DurableHarness } from "../src/durable-harness.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createSessionRoutes } from "../src/routes/sessions.js";
import type { RouteContext } from "../src/routes/types.js";
import { SessionListService } from "../src/session-list-service.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";
import { makeTempDir } from "./harness/temp-dir.js";

async function until(check: () => boolean | Promise<boolean>, what: string): Promise<void> {
  const deadline = Date.now() + 15_000;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describe("Oppi Control sessions on the durable harness, experimental.serverDurable off", () => {
  const managers: SessionManager[] = [];
  const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
  let agentDir: string;

  beforeEach(() => {
    agentDir = makeTempDir("oppi-control-session-agent-");
    process.env.PI_CODING_AGENT_DIR = agentDir;
  });
  afterEach(async () => {
    await Promise.all(managers.splice(0).map((manager) => manager.close()));
    vi.restoreAllMocks();
    if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
  });

  async function setup() {
    const dir = makeTempDir("oppi-control-session-");
    const models = await ModelRuntime.create({
      authPath: join(dir, "auth.json"),
      modelsPath: null,
      modelsStorePath: join(dir, "models-cache.json"),
      refreshOnCreate: false,
    });
    const faux = fauxProvider();
    faux.setResponses([]);
    models.registerNativeProvider(faux.provider);
    await models.setRuntimeApiKey("faux", "test-only-faux-credential");
    await models.refresh({ allowNetwork: false });
    vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
    vi.spyOn(SettingsManager, "create").mockImplementation(() =>
      SettingsManager.inMemory({
        defaultProvider: "faux",
        defaultModel: "faux-1",
        defaultThinkingLevel: "off",
        compaction: { enabled: false },
      }),
    );
    const storage = new Storage(dir);
    expect(storage.getConfig().experimental?.serverDurable).not.toBe(true);
    return { dir, storage, faux };
  }

  async function boot(storage: Storage) {
    const manager = new SessionManager(storage);
    managers.push(manager);
    await manager.resumeDurableSessions();
    const routeContext = {
      storage,
      sessions: manager,
      sessionRuntimes: manager,
      ensureSessionContextWindow: (session: Session) => session,
    } as unknown as RouteContext;
    const dispatch = createSessionRoutes(routeContext, createRouteHelpers());
    async function request(method: string, path: string, body?: Record<string, unknown>) {
      const res = makeResponse();
      const handled = await dispatch({
        method,
        path,
        url: new URL(`http://localhost${path}`),
        req: makeRequest(body),
        res: res as never,
      });
      expect(handled).toBe(true);
      return { status: res.statusCode, body: JSON.parse(res.body) as Record<string, unknown> };
    }
    async function create(body: Record<string, unknown>) {
      const result = await request("POST", "/control-sessions", body);
      return result as {
        status: number;
        body: { session: Session; prompted?: boolean; launch?: { existing: true } };
      };
    }
    const harness = (manager as unknown as { durableHarness: Promise<DurableHarness> })
      .durableHarness;
    return { manager, request, create, harness };
  }

  async function userTurns(owner: DurableHarness, session: Session): Promise<string[]> {
    const { harness } = await (await owner.openHost(session.serverDurable!.storeId!)).open();
    const conversation = (await harness.conversation(
      session.serverDurable!.conversationId as ConversationId,
      context,
    ))!;
    const page = await conversation.entries({}, 100, undefined, context);
    return page.items
      .flatMap((entry) => entry.model ?? [])
      .filter((message) => message.role === "user")
      .map((message) => JSON.stringify(message.content));
  }

  it("creates a durable control session per request and delivers its prompt once", async () => {
    const { storage, faux } = await setup();
    // Global setup the control session must not load.
    writeFileSync(join(agentDir, "AGENTS.md"), "GLOBAL AGENTS FILE\n");
    mkdirSync(join(agentDir, "skills", "global-skill"), { recursive: true });
    writeFileSync(
      join(agentDir, "skills", "global-skill", "SKILL.md"),
      "---\nname: global-skill\ndescription: A global skill\n---\nbody\n",
    );
    faux.setResponses([fauxAssistantMessage("done")]);
    const booted = await boot(storage);

    const created = await booted.create({
      prompt: "Revise the Reviewer skill",
      model: "faux/faux-1",
      launchIdempotencyKey: "composer-1",
    });
    expect(created.status).toBe(201);
    expect(created.body.prompted).toBe(true);
    const session = created.body.session;
    expect(session).toMatchObject({
      name: "Oppi Control",
      runtime: "oppi",
      serverDurable: { storeId: session.id, role: "control" },
      launch: {
        target: { server: true, displayCwd: "Oppi Control" },
        idempotencyKey: "composer-1",
        status: "accepted",
        promptDispatch: "delivered",
      },
    });
    expect(session.workspaceId).toBeUndefined();
    expect(JSON.stringify(session)).not.toContain('"control":');
    const stored = storage.getSession(session.id)!;
    expect(stored.serverDurable?.conversationId).toBeGreaterThan(0);
    expect(stored.launch?.promptDispatch).toBe("delivered");

    await until(() => faux.state.callCount === 1, "the first turn");
    await until(
      () => booted.manager.getActiveSession(session.id)?.status === "ready",
      "the turn to settle",
    );
    const owner = await booted.harness;
    const bound = storage.getSession(session.id)!;
    expect(await userTurns(owner, bound)).toEqual([
      expect.stringContaining("Revise the Reviewer skill"),
    ]);

    // Replaying the same launch returns the same session and never delivers the prompt again.
    const replay = await booted.create({
      prompt: "Revise the Reviewer skill",
      model: "faux/faux-1",
      launchIdempotencyKey: "composer-1",
    });
    expect(replay.status).toBe(200);
    expect(replay.body.session.id).toBe(session.id);
    expect(replay.body.launch).toEqual({ existing: true });
    expect(replay.body.prompted).toBe(true);
    expect(await userTurns(owner, bound)).toHaveLength(1);
    expect(faux.state.callCount).toBe(1);

    // A second request is a second session with its own store.
    faux.setResponses([fauxAssistantMessage("again")]);
    const second = await booted.create({ prompt: "Make a theme", name: "Theme" });
    expect(second.status).toBe(201);
    expect(second.body.session.id).not.toBe(session.id);
    expect(second.body.session.name).toBe("Theme");
    expect(storage.listSessions().filter(isControlConversation)).toHaveLength(2);

    // The stored selection is the exact control list (bash included), not the coding default.
    const { harness } = await (await owner.openHost(session.id)).open();
    const conversationId = bound.serverDurable!.conversationId as ConversationId;
    const agent = await harness.snapshot(AgentDoc, conversationId, context);
    expect(agent?.extensions).toEqual([
      "ask",
      "working-words",
      "oppi.control",
      "codemode",
      "coding-tools",
    ]);
    expect(agent?.tools).toEqual(
      controlConversationTools(owner.controlExtensions).map((tool) => tool.name),
    );
    // Classic parity: the host file tools and bash, next to the oppi tools.
    expect(agent?.tools).toEqual(
      expect.arrayContaining([
        "read",
        "bash",
        "edit",
        "write",
        "ask",
        "codemode",
        "oppi",
        "agents_list",
      ]),
    );
    expect(agent?.cwd).toBe(join(storage.getDataDir(), "control-conversation", "cwd"));
    expect(owner.defaultExtensions.map((e) => e.name)).not.toContain("oppi.control");
    // No global AGENTS file and no Skills, although the agent dir has both and `read` exists.
    const presented = await harness.snapshot(ProjectContextDoc, conversationId, context);
    expect(presented?.projectContext).toBeUndefined();
    expect(presented?.skills).toBeUndefined();

    // On the phone's global list, with the role and without a workspace.
    const list = new SessionListService({
      storage,
      sessionRuntimes: booted.manager,
      ensureSessionContextWindow: (row) => row,
    });
    const listed = list.listRecentWorkspaceSessionSummaries({ recentDays: 0 }).sessions;
    expect(listed.find((row) => row.id === session.id)).toMatchObject({
      engine: "durable",
      serverDurable: { role: "control" },
    });
    expect(listed.find((row) => row.id === session.id)?.workspaceId).toBeUndefined();
  });

  it("refuses a launch key that belongs to a session that is not a control session", async () => {
    const { storage } = await setup();
    const booted = await boot(storage);
    const workspace = storage.createWorkspace({ name: "W", hostMount: storage.getDataDir() });
    const other = storage.createSession("Workspace row");
    other.workspaceId = workspace.id;
    other.launch = { idempotencyKey: "shared", status: "accepted", promptDispatch: "delivered" };
    storage.saveSession(other);
    const refused = await booted.create({ prompt: "hi", launchIdempotencyKey: "shared" });
    expect(refused.status).toBe(409);
    expect(storage.listSessions().filter(isControlConversation)).toEqual([]);
  });

  it("keeps ordinary durable creates behind the flag", async () => {
    const { storage } = await setup();
    const booted = await boot(storage);
    const workspace = storage.createWorkspace({ name: "W", hostMount: storage.getDataDir() });
    const refused = await booted.request("POST", `/workspaces/${workspace.id}/sessions`, {
      engine: "durable",
    });
    expect(refused.status).toBe(409);
    expect(refused.body.error).toContain("experimental.serverDurable");
  });

  it("accepts the classic Pi Control body and makes a durable control session from it", async () => {
    const { storage } = await setup();
    const booted = await boot(storage);
    // What app builds made for classic Pi Control send: metadata, a name, and no prompt.
    const created = await booted.create({
      domain: "skills",
      intent: "revise",
      targetId: "skill-reviewer",
      targetName: "Reviewer",
      name: "Revise Reviewer",
      launchIdempotencyKey: "classic-app-1",
    });
    expect(created.status).toBe(201);
    expect(created.body).not.toHaveProperty("prompted");
    const session = created.body.session;
    expect(session).toMatchObject({
      name: "Revise Reviewer",
      serverDurable: { storeId: session.id, role: "control" },
      launch: { status: "accepted", promptDispatch: "not_sent" },
    });
    expect(session).not.toHaveProperty("control");
    expect(storage.getSession(session.id)).not.toHaveProperty("control");
    // Nothing started: the client sends the first message after it opens the session.
    expect(booted.manager.isActive(session.id)).toBe(false);

    const replay = await booted.create({
      domain: "skills",
      intent: "revise",
      name: "Revise Reviewer",
      launchIdempotencyKey: "classic-app-1",
    });
    expect(replay.status).toBe(200);
    expect(replay.body.session.id).toBe(session.id);

    // Opening it binds a durable conversation without the experiment.
    const resumed = await booted.request("POST", `/control-sessions/${session.id}/resume`);
    expect(resumed.status).toBe(200);
    expect((resumed.body.session as Session).serverDurable?.conversationId).toBeGreaterThan(0);
    expect(booted.manager.isActive(session.id)).toBe(true);
  });

  it("gives the oppi CLI host only to control sessions' conversations", async () => {
    const { storage, faux } = await setup();
    faux.setResponses([fauxAssistantMessage("done")]);
    const booted = await boot(storage);
    const created = await booted.create({ prompt: "hi", model: "faux/faux-1" });
    const control = storage.getSession(created.body.session.id)!;
    const owner = await booted.harness;
    const cli = owner.boundControl!;
    const conversationId = control.serverDurable!.conversationId as ConversationId;
    expect(cli.forConversation(control.id, conversationId)).toMatchObject({
      themesDir: join(storage.getDataDir(), "themes"),
    });

    // The same store and conversation, bound to a durable session without the role.
    const ordinary = storage.createSession("Ordinary durable");
    ordinary.serverDurable = { storeId: "ordinary-store", conversationId: 3 };
    storage.saveSession(ordinary);
    expect(cli.forConversation("ordinary-store", 3 as ConversationId)).toBeUndefined();
    const refused = await cli.run("ordinary-store", ["agent", "list"], {
      conversationId: 3 as ConversationId,
      key: "k",
      signal: new AbortController().signal,
    });
    expect(refused).toEqual({
      envelope: { ok: false, error: { code: "refused", message: expect.any(String) } },
      wrote: false,
    });
  });

  it("runs control tools on the host the server binds, with the section as its instructions", async () => {
    const { storage, faux } = await setup();
    faux.setResponses([
      fauxAssistantMessage(
        [
          fauxToolCall("codemode", {
            code: "let reached; try { await tools.agents_list({}); } catch (e) { reached = e.message; } return [6 * 7, reached];",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage([fauxToolCall("workspaces_list", {})], { stopReason: "toolUse" }),
      fauxAssistantMessage("forty-two"),
    ]);
    const booted = await boot(storage);
    const created = await booted.create({ prompt: "what is 6 * 7?", model: "faux/faux-1" });
    await until(() => faux.state.callCount === 3, "the three model calls");
    await until(
      () => booted.manager.getActiveSession(created.body.session.id)?.status === "ready",
      "the turn to settle",
    );
    const owner = await booted.harness;
    const session = storage.getSession(created.body.session.id)!;
    const { harness } = await (await owner.openHost(session.serverDurable!.storeId!)).open();
    const conversation = (await harness.conversation(
      session.serverDurable!.conversationId as ConversationId,
      context,
    ))!;
    const page = await conversation.entries({}, 50, undefined, context);
    const results = page.items
      .flatMap((entry) => entry.model ?? [])
      .filter((message) => message.role === "toolResult");
    const script = results.find((message) => message.toolName === "codemode");
    // Both reached the CLI host the server binds, which refuses: this data dir is not paired.
    expect(script).toMatchObject({ isError: false });
    expect(JSON.stringify(script?.content)).toContain("[42,");
    expect(JSON.stringify(script?.content)).toContain("oppi init");
    const direct = results.find((message) => message.toolName === "workspaces_list");
    expect(direct).toMatchObject({ isError: true });
    expect(JSON.stringify(direct?.content)).toContain("oppi init");
    const agent = await conversation.agent(context);
    expect(agent.instructions).toBeUndefined();
    expect(agent.sections.map((section) => section.key)).toContain("oppi-control");
    // The section names this server's themes directory, which only the bound host knows.
    const system = page.items
      .flatMap((entry) => entry.model ?? [])
      .find((message) => message.role === "system");
    expect(JSON.stringify(system)).toContain(join(storage.getDataDir(), "themes"));
  });
});
