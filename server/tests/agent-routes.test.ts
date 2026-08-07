import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { ServerResponse } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import { AgentDefinitionStore } from "../src/agent-definitions.js";
import { AgentConfigurationError } from "../src/agent-launch-errors.js";
import { DEFAULT_AGENT_ID } from "../src/default-agent.js";
import { openDatabase } from "../src/sqlite-compat.js";
import { createRouteHelpers } from "../src/routes/http.js";
import { createAgentRoutes } from "../src/routes/agents.js";
import { RouteHandler } from "../src/routes/index.js";
import type { RouteContext } from "../src/routes/types.js";
import type { Session } from "../src/types.js";
import { makeRequest, makeResponse } from "./harness/route-test-helpers.js";

function makeSession(overrides: Partial<Session> = {}): Session {
  return {
    id: overrides.id ?? "sess-1",
    status: overrides.status ?? "ready",
    createdAt: overrides.createdAt ?? 1,
    lastActivity: overrides.lastActivity ?? 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
    runtime: "oppi",
    ...overrides,
  };
}

type AgentUpdateWorkerMessage = {
  kind: "ready" | "read" | "result";
  ok?: boolean;
  name?: string;
  message?: string;
  code?: string;
  version?: number;
  description?: string;
  expectedVersion?: number;
  currentVersion?: number;
};

type AgentUpdateWorkerHandle = {
  child: ChildProcessWithoutNullStreams;
  ready: Promise<void>;
  read: Promise<void>;
  result: Promise<AgentUpdateWorkerMessage>;
};

const AGENT_RACE_PHASE_TIMEOUT_MS = 3_000;
const AGENT_RACE_TERM_TIMEOUT_MS = 500;
const AGENT_RACE_KILL_TIMEOUT_MS = 1_000;

function agentUpdateChildSource(): string {
  const agentDefinitionsUrl = new URL("../src/agent-definitions.ts", import.meta.url).href;
  return `
import { existsSync } from "node:fs";
import { createInterface } from "node:readline";
import { AgentDefinitionStore } from ${JSON.stringify(agentDefinitionsUrl)};

const [dataDir, dbPath, agentId, description, releasePath, expectedVersionText] =
  process.argv.slice(1);
const expectedVersion = expectedVersionText ? Number(expectedVersionText) : undefined;
const store = new AgentDefinitionStore(dataDir, dbPath);
const originalGetAgent = store.getAgent.bind(store);
let lookupHeld = false;
store.getAgent = (id) => {
  const agent = originalGetAgent(id);
  if (!lookupHeld && id === agentId) {
    lookupHeld = true;
    process.stdout.write(JSON.stringify({ kind: "read" }) + "\\n");
    const gateSignal = new Int32Array(new SharedArrayBuffer(4));
    const gateDeadline = Date.now() + 3_000;
    while (!existsSync(releasePath) && Date.now() < gateDeadline) {
      Atomics.wait(gateSignal, 0, 0, 10);
    }
    if (!existsSync(releasePath)) throw new Error("Agent race gate timed out");
  }
  return agent;
};
const input = createInterface({ input: process.stdin });
process.stdout.write("ready\\n");
input.once("line", () => {
  try {
    const updated = store.updateAgent(agentId, { description }, Date.now(), expectedVersion);
    process.stdout.write(JSON.stringify({
      kind: "result",
      ok: true,
      version: updated?.version,
      description: updated?.definition.description,
    }) + "\\n");
  } catch (error) {
    const record = error && typeof error === "object" ? error : {};
    process.stdout.write(JSON.stringify({
      kind: "result",
      ok: false,
      name: error instanceof Error ? error.name : "UnknownError",
      message: error instanceof Error ? error.message : String(error),
      code: record.code,
      expectedVersion: record.expectedVersion,
      currentVersion: record.currentVersion,
    }) + "\\n");
  } finally {
    store.close();
    input.close();
  }
});
`;
}

function spawnAgentUpdateWorker(
  dataDir: string,
  dbPath: string,
  agentId: string,
  description: string,
  releasePath: string,
  expectedVersion: number | undefined,
): AgentUpdateWorkerHandle {
  const child = spawn(
    process.execPath,
    [
      "--import",
      "tsx/esm",
      "--input-type=module",
      "--eval",
      agentUpdateChildSource(),
      dataDir,
      dbPath,
      agentId,
      description,
      releasePath,
      expectedVersion === undefined ? "" : String(expectedVersion),
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );

  let readyResolved = false;
  let readResolved = false;
  let resultResolved = false;
  let resolveReady: () => void = () => {};
  let rejectReady: (error: unknown) => void = () => {};
  let resolveRead: () => void = () => {};
  let rejectRead: (error: unknown) => void = () => {};
  let resolveResult: (message: AgentUpdateWorkerMessage) => void = () => {};
  let rejectResult: (error: unknown) => void = () => {};
  const ready = new Promise<void>((resolve, reject) => {
    resolveReady = () => {
      readyResolved = true;
      resolve();
    };
    rejectReady = reject;
  });
  const read = new Promise<void>((resolve, reject) => {
    resolveRead = () => {
      readResolved = true;
      resolve();
    };
    rejectRead = reject;
  });
  const result = new Promise<AgentUpdateWorkerMessage>((resolve, reject) => {
    resolveResult = (message) => {
      resultResolved = true;
      resolve(message);
    };
    rejectResult = reject;
  });
  const rejectBoth = (error: unknown): void => {
    if (!readyResolved) rejectReady(error);
    if (!readResolved) rejectRead(error);
    if (!resultResolved) rejectResult(error);
  };
  let output = "";
  let errorOutput = "";
  const handleLine = (line: string): void => {
    const trimmed = line.trim();
    if (!trimmed) return;
    if (trimmed === "ready") {
      resolveReady();
      return;
    }
    if (trimmed === '{"kind":"read"}') {
      resolveRead();
      return;
    }
    try {
      const message = JSON.parse(trimmed) as AgentUpdateWorkerMessage;
      if (message.kind === "result") resolveResult(message);
      else rejectBoth(new Error(`Unexpected agent update child message: ${trimmed}`));
    } catch (error: unknown) {
      rejectBoth(error);
    }
  };
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    output += chunk;
    const lines = output.split("\n");
    output = lines.pop() ?? "";
    for (const line of lines) handleLine(line);
  });
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    errorOutput += chunk;
  });
  child.on("error", rejectBoth);
  child.on("exit", (code) => {
    if (code !== 0) {
      rejectBoth(new Error(`Agent update child exited with code ${code}: ${errorOutput.trim()}`));
    }
  });
  void ready.catch(() => undefined);
  void read.catch(() => undefined);
  void result.catch(() => undefined);

  return { child, ready, read, result };
}

async function runConcurrentAgentUpdates(
  dataDir: string,
  dbPath: string,
  agentId: string,
  expectedVersion: number | undefined,
): Promise<AgentUpdateWorkerMessage[]> {
  const releasePath = join(dataDir, "agent-cas-release");
  const handles: AgentUpdateWorkerHandle[] = [];
  try {
    for (const description of ["Writer A", "Writer B"]) {
      const handle = spawnAgentUpdateWorker(
        dataDir,
        dbPath,
        agentId,
        description,
        releasePath,
        expectedVersion,
      );
      handles.push(handle);
      await waitForAgentRace(handle.ready, "child readiness");
    }

    for (const handle of handles) handle.child.stdin.write("start\n");
    await waitForAgentRace(Promise.all(handles.map((handle) => handle.read)), "read gate");
    writeFileSync(releasePath, "release");
    return await waitForAgentRace(
      Promise.all(handles.map((handle) => handle.result)),
      "child results",
    );
  } finally {
    writeFileSync(releasePath, "release");
    await Promise.all(handles.map((handle) => stopAgentUpdateChild(handle.child)));
  }
}

async function waitForAgentRace<T>(promise: Promise<T>, phase: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`Agent race ${phase} timed out`)),
          AGENT_RACE_PHASE_TIMEOUT_MS,
        );
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

async function stopAgentUpdateChild(child: ChildProcessWithoutNullStreams): Promise<void> {
  if (await waitForAgentChildExit(child, AGENT_RACE_TERM_TIMEOUT_MS)) return;
  child.kill("SIGKILL");
  await waitForAgentChildExit(child, AGENT_RACE_KILL_TIMEOUT_MS);
}

function waitForAgentChildExit(
  child: ChildProcessWithoutNullStreams,
  timeoutMs: number,
): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (exited: boolean): void => {
      if (timer) clearTimeout(timer);
      child.off("exit", onExit);
      child.off("error", onError);
      resolve(exited);
    };
    const onExit = (): void => finish(true);
    const onError = (): void => {};
    child.once("exit", onExit);
    child.once("error", onError);
    timer = setTimeout(() => finish(false), timeoutMs);
  });
}

describe("agent routes", () => {
  it("mounts saved Agent routes in the main route handler", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-mounted-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const routes = new RouteHandler(ctx);

      const listRes = makeResponse();
      await routes.dispatch(
        "GET",
        "/agents",
        new URL("http://localhost/agents"),
        {} as never,
        listRes as never,
      );
      expect(listRes.statusCode).toBe(200);
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: DEFAULT_AGENT_ID,
            name: "Oppi",
            status: "active",
          }),
          expect.objectContaining({ id: agent.id, name: "Reviewer", status: "active" }),
        ]),
      );

      const launchRes = makeResponse();
      await routes.dispatch(
        "POST",
        `/agents/${agent.id}/sessions`,
        new URL(`http://localhost/agents/${agent.id}/sessions`),
        makeRequest({}) as never,
        launchRes as never,
      );
      expect(launchRes.statusCode).toBe(400);
      expect(JSON.parse(launchRes.body)).toEqual({ error: "target.workspaceId required" });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("creates, lists, gets, updates, and archives durable Agent definitions", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const createRes = makeResponse();
      expect(
        await dispatch({
          method: "POST",
          path: "/agents",
          url: new URL("http://localhost/agents"),
          req: makeRequest({
            name: "Reviewer",
            description: "Reviews diffs",
            instructions: { mode: "append", text: "Focus on risk." },
            resources: { skillPaths: [".pi/skills/reviewer"] },
            sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "medium" },
            launchConstraints: {
              allowedWorkspaceIds: ["review-workspace"],
              requiredRuntime: "sandbox",
            },
          }) as never,
          res: createRes as never,
        }),
      ).toBe(true);
      expect(createRes.statusCode).toBe(201);
      const created = JSON.parse(createRes.body).agent as { id: string; version: number };
      expect(created.id).toBeTruthy();
      expect(created.version).toBe(1);

      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: {} as never,
        res: listRes as never,
      });
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([
          expect.objectContaining({
            id: DEFAULT_AGENT_ID,
            name: "Oppi",
            status: "active",
          }),
          expect.objectContaining({
            id: created.id,
            name: "Reviewer",
            launchConstraints: {
              allowedWorkspaceIds: ["review-workspace"],
              requiredRuntime: "sandbox",
            },
            status: "active",
          }),
        ]),
      );

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: `/agents/${encodeURIComponent("Reviewer")}`,
        url: new URL("http://localhost/agents/Reviewer"),
        req: {} as never,
        res: getRes as never,
      });
      expect(JSON.parse(getRes.body).agent).toMatchObject({
        id: created.id,
        definition: {
          name: "Reviewer",
          description: "Reviews diffs",
          resources: { skillPaths: [".pi/skills/reviewer"] },
        },
      });

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: makeRequest({ description: "Reviews risky diffs" }) as never,
        res: updateRes as never,
      });
      expect(JSON.parse(updateRes.body).agent).toMatchObject({
        id: created.id,
        version: 2,
        definition: { name: "Reviewer", description: "Reviews risky diffs" },
      });
      expect(store.getAgentVersion(created.id, 1)?.definition).toMatchObject({
        name: "Reviewer",
        description: "Reviews diffs",
      });
      expect(store.getAgentVersion(created.id, 2)?.definition).toMatchObject({
        name: "Reviewer",
        description: "Reviews risky diffs",
      });

      const clearRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: makeRequest({
          description: null,
          instructions: null,
          resources: null,
          sessionDefaults: { model: null, thinkingLevel: null },
        }) as never,
        res: clearRes as never,
      });
      const cleared = JSON.parse(clearRes.body).agent as { definition: Record<string, unknown> };
      expect(cleared.definition).not.toHaveProperty("description");
      expect(cleared.definition).not.toHaveProperty("instructions");
      expect(cleared.definition).not.toHaveProperty("resources");
      expect(cleared.definition.sessionDefaults).toEqual({});

      const archiveRes = makeResponse();
      await dispatch({
        method: "DELETE",
        path: `/agents/${created.id}`,
        url: new URL(`http://localhost/agents/${created.id}`),
        req: {} as never,
        res: archiveRes as never,
      });
      expect(JSON.parse(archiveRes.body).agent).toMatchObject({
        id: created.id,
        status: "archived",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects stale expected-version updates atomically with HTTP 409", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-cas-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer", description: "Reviewed baseline" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const concurrent = store.updateAgent(agent.id, { description: "Concurrent update" });
      expect(concurrent?.version).toBe(2);

      const staleRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}?expectedVersion=1`),
        req: makeRequest({ description: "Approved update" }) as never,
        res: staleRes as never,
      });

      expect(staleRes.statusCode).toBe(409);
      expect(JSON.parse(staleRes.body)).toEqual({
        error: "Agent version conflict: expected 1, current 2",
        code: "AGENT_VERSION_CONFLICT",
        expectedVersion: 1,
        currentVersion: 2,
      });
      expect(store.getAgent(agent.id)).toMatchObject({
        version: 2,
        definition: { description: "Concurrent update" },
      });
      expect(store.getAgentVersion(agent.id, 3)).toBeUndefined();
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("keeps PATCH compatibility when expectedVersion is absent", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-compatible-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ description: "Compatible update" }) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body).agent).toMatchObject({
        version: 2,
        definition: { description: "Compatible update" },
      });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("returns undefined instead of a conflict when a CAS miss finds an archived Agent", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-cas-archived-"));
    const dbPath = join(dataDir, "session-state.db");
    const store = new AgentDefinitionStore(dataDir, dbPath);
    const concurrentStore = new AgentDefinitionStore(dataDir, dbPath);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const originalGetAgent = store.getAgent.bind(store);
      let firstLookup = true;
      store.getAgent = (agentId) => {
        const current = originalGetAgent(agentId);
        if (firstLookup && agentId === agent.id) {
          firstLookup = false;
          expect(concurrentStore.archiveAgent(agent.id)).toMatchObject({ status: "archived" });
        }
        return current;
      };

      expect(store.updateAgent(agent.id, { description: "Should not apply" }, Date.now(), 1)).toBe(
        undefined,
      );
      expect(concurrentStore.getAgent(agent.id)).toMatchObject({ status: "archived" });
    } finally {
      concurrentStore.close();
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it.each([
    ["unexpected=1", "Unknown Agent update query parameter: unexpected"],
    ["expectedversion=1", "Unknown Agent update query parameter: expectedversion"],
    ["expectedVersion=1&expectedVersion=2", "expectedVersion must be specified exactly once"],
    ["expectedVersion=", "expectedVersion must be a positive integer"],
    ["expectedVersion=9007199254740992", "expectedVersion must be a positive safe integer"],
  ])("rejects malformed Agent update query %s", async (query, error) => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-query-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}?${query}`),
        req: makeRequest({ description: "Updated" }) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error });
      expect(store.getAgent(agent.id)).toMatchObject({ version: 1 });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it.each([
    ["with expectedVersion", 1],
    ["without expectedVersion", undefined],
  ] as const)(
    "resolves a true two-connection Agent update race (%s) as one success and one conflict",
    async (_label, expectedVersion) => {
      const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-cas-connections-"));
      const dbPath = join(dataDir, "session-state.db");
      const store = new AgentDefinitionStore(dataDir, dbPath);
      const agent = store.createAgent({ name: "Reviewer", description: "Reviewed baseline" });
      store.close();

      try {
        const results = await runConcurrentAgentUpdates(dataDir, dbPath, agent.id, expectedVersion);
        const successes = results.filter((result) => result.ok);
        const conflicts = results.filter((result) => !result.ok);

        if (expectedVersion !== undefined) {
          expect(successes).toHaveLength(1);
          expect(successes[0]).toMatchObject({ kind: "result", ok: true, version: 2 });
          expect(conflicts).toEqual([
            expect.objectContaining({
              kind: "result",
              ok: false,
              name: "AgentVersionConflictError",
              code: "AGENT_VERSION_CONFLICT",
              expectedVersion: 1,
              currentVersion: 2,
            }),
          ]);
        } else {
          expect(successes).toHaveLength(2);
          expect(conflicts).toHaveLength(0);
          expect(successes.map((result) => result.version).sort()).toEqual([2, 3]);
        }

        const finalStore = new AgentDefinitionStore(dataDir, dbPath);
        try {
          const final = finalStore.getAgent(agent.id);
          const finalVersion = expectedVersion === undefined ? 3 : 2;
          const finalSuccess = successes.find((result) => result.version === finalVersion);
          expect(final).toMatchObject({
            version: finalVersion,
            definition: { description: finalSuccess?.description },
          });
          expect(finalStore.getAgentVersion(agent.id, finalVersion)).toMatchObject({
            definition: { description: finalSuccess?.description },
          });
          if (expectedVersion === undefined) {
            const firstSuccess = successes.find((result) => result.version === 2);
            expect(finalStore.getAgentVersion(agent.id, 2)).toMatchObject({
              definition: { description: firstSuccess?.description },
            });
          }
          expect(finalStore.getAgentVersion(agent.id, 4)).toBeUndefined();
        } finally {
          finalStore.close();
        }
      } finally {
        rmSync(dataDir, { recursive: true, force: true });
      }
    },
  );

  it("migrates a historical malformed icon to Default before unrelated updates", () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-historical-icon-"));
    const databasePath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Historian",
        icon: { kind: "symbol", name: "sparkles" },
        description: "Original description",
      });
      store.close();

      const db = openDatabase(databasePath);
      db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
        JSON.stringify({
          name: "Historian",
          icon: "historical/icon",
          description: "Original description",
        }),
        agent.id,
      );
      db.close();

      store = new AgentDefinitionStore(dataDir);
      const updated = store.updateAgent(agent.id, { description: "Updated description" });
      expect(updated?.definition).toMatchObject({
        icon: { kind: "default" },
        description: "Updated description",
      });
      expect(() =>
        store.updateAgent(agent.id, { icon: { kind: "symbol", name: "still/invalid" } }),
      ).toThrow(/icon.name/);

      const cleared = store.updateAgent(agent.id, { icon: { kind: "default" } });
      expect(cleared?.definition.icon).toEqual({ kind: "default" });
      expect(cleared?.definition.description).toBe("Updated description");
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("updates, persists, returns, and clears a saved Agent icon", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-icon-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Sensei",
        description: "Guides reviews",
        instructions: { mode: "append", text: "Stay calm." },
        sessionDefaults: { model: "openai-codex/gpt-5.5" },
      });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: { kind: "emoji", value: "  🧘  " } }) as never,
        res: updateRes as never,
      });
      expect(updateRes.statusCode).toBe(200);
      expect(JSON.parse(updateRes.body).agent.definition).toMatchObject({
        name: "Sensei",
        icon: { kind: "emoji", value: "🧘" },
        description: "Guides reviews",
        instructions: { mode: "append", text: "Stay calm." },
        sessionDefaults: { model: "openai-codex/gpt-5.5" },
      });

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: {} as never,
        res: getRes as never,
      });
      expect(JSON.parse(getRes.body).agent.definition.icon).toEqual({
        kind: "emoji",
        value: "🧘",
      });
      expect(store.getAgentVersion(agent.id, 2)?.definition.icon).toEqual({
        kind: "emoji",
        value: "🧘",
      });

      const listRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: {} as never,
        res: listRes as never,
      });
      expect(JSON.parse(listRes.body).agents).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ id: agent.id, icon: { kind: "emoji", value: "🧘" } }),
        ]),
      );

      const sfSymbolRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: { kind: "symbol", name: "  checkmark.shield  " } }) as never,
        res: sfSymbolRes as never,
      });
      expect(sfSymbolRes.statusCode).toBe(200);
      expect(JSON.parse(sfSymbolRes.body).agent.definition.icon).toEqual({
        kind: "symbol",
        name: "checkmark.shield",
      });

      for (const invalidIcon of [
        "two words",
        { kind: "emoji", value: "🧘🧘" },
        { kind: "symbol", name: "not/a/symbol" },
        { kind: "symbol", name: "x".repeat(129) },
        { kind: "future" },
      ]) {
        const invalidRes = makeResponse();
        await dispatch({
          method: "PATCH",
          path: `/agents/${agent.id}`,
          url: new URL(`http://localhost/agents/${agent.id}`),
          req: makeRequest({ icon: invalidIcon }) as never,
          res: invalidRes as never,
        });
        expect(invalidRes.statusCode).toBe(400);
        expect(JSON.parse(invalidRes.body).error).toContain("icon");
      }

      const clearRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ icon: { kind: "default" } }) as never,
        res: clearRes as never,
      });
      expect(clearRes.statusCode).toBe(200);
      expect(JSON.parse(clearRes.body).agent.definition.icon).toEqual({ kind: "default" });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("resolves only the oppi alias and id for the shipped identity", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-alias-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      for (const reference of ["oppi", "oppi-default-agent"]) {
        const res = makeResponse();
        await dispatch({
          method: "GET",
          path: `/agents/${reference}`,
          url: new URL(`http://localhost/agents/${reference}`),
          req: {} as never,
          res: res as never,
        });
        expect(res.statusCode).toBe(200);
        expect(JSON.parse(res.body).agent).toMatchObject({ id: DEFAULT_AGENT_ID });
      }

      // The old `default` alias was removed; it must not resolve to the identity.
      const defaultRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents/default",
        url: new URL("http://localhost/agents/default"),
        req: {} as never,
        res: defaultRes as never,
      });
      expect(defaultRes.statusCode).toBe(404);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("seeds an overwriteable default Agent identity and can reset customization", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const getRes = makeResponse();
      await dispatch({
        method: "GET",
        path: "/agents/oppi",
        url: new URL("http://localhost/agents/oppi"),
        req: {} as never,
        res: getRes as never,
      });
      expect(getRes.statusCode).toBe(200);
      expect(JSON.parse(getRes.body).agent).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Oppi",
        status: "active",
        definition: {
          name: "Oppi",
          description: expect.stringContaining("Manage Oppi"),
          resources: { noContextFiles: true },
          sessionDefaults: { noTools: "builtin", tools: ["oppi", "ask", "read"] },
        },
      });

      const updateRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: "/agents/oppi",
        url: new URL("http://localhost/agents/oppi"),
        req: makeRequest({
          name: "Home Agent",
          icon: { kind: "emoji", value: "🏠" },
          description: "Coordinates Oppi from the app home screen",
          instructions: { mode: "append", text: "Prefer short status summaries." },
          sessionDefaults: { model: "openai-codex/gpt-5.5", thinkingLevel: "high" },
        }) as never,
        res: updateRes as never,
      });
      expect(updateRes.statusCode).toBe(200);
      const updated = JSON.parse(updateRes.body).agent;
      expect(updated).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Oppi",
        version: 2,
        definition: {
          name: "Oppi",
          icon: { kind: "emoji", value: "🏠" },
          description: "Coordinates Oppi from the app home screen",
          instructions: { mode: "append", text: "Prefer short status summaries." },
          resources: { noContextFiles: true },
          sessionDefaults: {
            model: "openai-codex/gpt-5.5",
            thinkingLevel: "high",
            noTools: "builtin",
            tools: ["oppi", "ask", "read"],
          },
        },
      });

      const rejectRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: "/agents/oppi",
        url: new URL("http://localhost/agents/oppi"),
        req: makeRequest({ sessionDefaults: { tools: ["bash"] } }) as never,
        res: rejectRes as never,
      });
      expect(rejectRes.statusCode).toBe(400);
      expect(JSON.parse(rejectRes.body).error).toContain("sessionDefaults.tools");

      const launchOverrideRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents/oppi/sessions",
        url: new URL("http://localhost/agents/oppi/sessions"),
        req: makeRequest({
          prompt: { text: "Run safely" },
          target: { workspaceId: "ws-1" },
          overrides: { tools: ["bash"] },
        }) as never,
        res: launchOverrideRes as never,
      });
      expect(launchOverrideRes.statusCode).toBe(400);
      expect(JSON.parse(launchOverrideRes.body).error).toBe(
        "Oppi launch overrides cannot change tools",
      );

      const resetRes = makeResponse();
      await dispatch({
        method: "DELETE",
        path: "/agents/oppi/customization",
        url: new URL("http://localhost/agents/oppi/customization"),
        req: {} as never,
        res: resetRes as never,
      });
      expect(resetRes.statusCode).toBe(200);
      expect(JSON.parse(resetRes.body).agent).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Oppi",
        version: 3,
        definition: {
          name: "Oppi",
          resources: { noContextFiles: true },
          sessionDefaults: { noTools: "builtin", tools: ["oppi", "ask", "read"] },
        },
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("accepts the native Oppi agent edit body without resources on its canonical route", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-native-route-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      await dispatch({
        method: "PATCH",
        path: `/agents/${DEFAULT_AGENT_ID}`,
        url: new URL(`http://localhost/agents/${DEFAULT_AGENT_ID}`),
        req: makeRequest({
          name: "Home Agent",
          description: null,
          instructions: null,
          sessionDefaults: { model: "openai/gpt-5.6", thinkingLevel: "high" },
        }) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(200);
      expect(JSON.parse(res.body).agent).toMatchObject({
        id: DEFAULT_AGENT_ID,
        name: "Oppi",
        definition: {
          name: "Oppi",
          resources: { noContextFiles: true },
          sessionDefaults: {
            model: "openai/gpt-5.6",
            thinkingLevel: "high",
            noTools: "builtin",
            tools: ["oppi", "ask", "read"],
          },
        },
      });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("does not archive the reserved default Agent identity", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-default-agent-archive-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const res = makeResponse();
      await dispatch({
        method: "DELETE",
        path: "/agents/oppi",
        url: new URL("http://localhost/agents/oppi"),
        req: {} as never,
        res: res as never,
      });
      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("cannot be archived");
      expect(store.getAgent(DEFAULT_AGENT_ID)).toMatchObject({ status: "active" });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("launches a workspace session from a saved Agent with launch metadata", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-launch-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({
        name: "Reviewer",
        icon: { kind: "symbol", name: "checkmark.shield" },
        sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
      });
      const sessions: Session[] = [];
      const saveSession = vi.fn((session: Session) => {
        const existing = sessions.findIndex((candidate) => candidate.id === session.id);
        const copy = structuredClone(session);
        if (existing >= 0) sessions[existing] = copy;
        else sessions.push(copy);
      });
      const startSession = vi.fn(async (sessionId: string) => {
        const session = sessions.find((candidate) => candidate.id === sessionId);
        if (!session) throw new Error("missing session");
        return session;
      });
      const sendPrompt = vi.fn(async () => undefined);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          getDataDir: vi.fn(() => dataDir),
          createSession: vi.fn((name?: string, model?: string) => {
            const session = makeSession({ id: `sess-${sessions.length + 1}`, name, model });
            sessions.push(structuredClone(session));
            return session;
          }),
          saveSession,
          getSession: vi.fn((sessionId: string) =>
            sessions.find((candidate) => candidate.id === sessionId),
          ),
          listSessions: vi.fn(() => sessions),
          findSessionByLaunchIdempotencyKey: vi.fn((key: string) =>
            sessions.find((candidate) => candidate.launch?.idempotencyKey === key),
          ),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: { startSession, sendPrompt },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
        appEvents: { emitSessionCreated: vi.fn(), emitSessionSummary: vi.fn() },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      for (const [prompt, expectedError] of [
        ["invalid", "prompt must be an object"],
        [{ text: 42 }, "prompt.text required"],
        [{ text: "Review", attachments: "invalid" }, "prompt.attachments must be an array"],
        [{ text: "Review", attachments: [null] }, "prompt.attachments[0] must be an object"],
        [
          { text: "Review", attachments: [{ type: "future" }] },
          "prompt.attachments[0].type must be attachment",
        ],
        [
          {
            text: "Review",
            attachments: [
              {
                type: "attachment",
                id: "upload-1",
                source: "upload",
                name: "notes.txt",
                mimeType: "text/plain",
                sizeBytes: -1,
              },
            ],
          },
          "prompt.attachments[0].sizeBytes must be a non-negative safe integer",
        ],
        [
          {
            text: "Review",
            attachments: [
              {
                type: "attachment",
                id: "workspace-1",
                source: "workspace",
                name: "notes.txt",
                mimeType: "text/plain",
                sizeBytes: 12,
              },
            ],
          },
          "prompt.attachments[0].workspacePath is required for workspace attachments",
        ],
      ] as const) {
        const invalidRes = makeResponse();
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({ prompt, target: { workspaceId: "ws-1" } }) as never,
          res: invalidRes as never,
        });
        expect(invalidRes.statusCode).toBe(400);
        expect(JSON.parse(invalidRes.body)).toEqual({ error: expectedError });
      }
      expect(sessions).toHaveLength(0);

      const res = makeResponse();
      expect(
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Review this" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            idempotencyKey: "agent-launch-1",
            sessionName: "Review run",
            overrides: { model: "override-model" },
          }) as never,
          res: res as never,
        }),
      ).toBe(true);

      expect(res.statusCode).toBe(201);
      const body = JSON.parse(res.body) as {
        receipt: { accepted: boolean; agentId: string; agentVersion: number; sessionId: string };
        session: Session;
      };
      expect(body.receipt).toMatchObject({
        accepted: true,
        agentId: agent.id,
        agentVersion: 1,
        promptDispatch: "delivered",
      });
      expect(body.session).toMatchObject({
        id: body.receipt.sessionId,
        workspaceId: "ws-1",
        worktreeId: "main",
        model: "override-model",
        thinkingLevel: "high",
        launch: {
          source: "agent",
          agentId: agent.id,
          agentVersion: 1,
          agentIcon: { kind: "symbol", name: "checkmark.shield" },
          idempotencyKey: "agent-launch-1",
          modelPolicy: "required",
          promptDispatch: "delivered",
        },
      });
      expect(startSession).toHaveBeenCalledWith(body.receipt.sessionId, {
        id: "ws-1",
        name: "Oppi",
      });
      expect(sendPrompt).toHaveBeenCalledWith(body.receipt.sessionId, "Review this", {});

      const draftRes = makeResponse();
      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          target: { workspaceId: "ws-1" },
          idempotencyKey: "agent-draft-1",
        }) as never,
        res: draftRes as never,
      });

      expect(draftRes.statusCode).toBe(201);
      expect(JSON.parse(draftRes.body)).toMatchObject({
        receipt: {
          accepted: true,
          agentId: agent.id,
          agentVersion: 1,
          promptDispatch: "not_sent",
        },
        session: {
          workspaceId: "ws-1",
          model: "agent-model",
          thinkingLevel: "high",
          launch: {
            agentId: agent.id,
            status: "accepted",
            promptDispatch: "not_sent",
          },
        },
      });
      expect(startSession).toHaveBeenCalledOnce();
      expect(sendPrompt).toHaveBeenCalledOnce();

      const modelError = new Error(
        'Required model "agent-model" is not available; refusing model fallback',
      );
      startSession.mockRejectedValueOnce(modelError);
      const failedRes = makeResponse();
      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          prompt: { text: "Must not reach another model" },
          target: { workspaceId: "ws-1", worktreeId: "main" },
        }) as never,
        res: failedRes as never,
      });

      expect(failedRes.statusCode).toBe(409);
      const failedBody = JSON.parse(failedRes.body) as {
        error: string;
        sessionId: string;
        receipt: Record<string, unknown>;
      };
      expect(failedBody).toMatchObject({
        error: modelError.message,
        sessionId: expect.any(String),
        receipt: {
          accepted: false,
          retryable: false,
          reason: "required_model_unavailable",
          agentId: agent.id,
          agentVersion: 1,
          sessionId: expect.any(String),
          promptDispatch: "not_sent",
          promptError: modelError.message,
        },
      });
      expect(failedBody.receipt.sessionId).toBe(failedBody.sessionId);
      expect(sendPrompt).toHaveBeenCalledOnce();
      expect(sessions.at(-1)).toMatchObject({
        model: "agent-model",
        status: "error",
        launch: {
          modelPolicy: "required",
          status: "failed",
          promptDispatch: "not_sent",
          promptError: modelError.message,
        },
      });

      startSession.mockRejectedValueOnce(
        new AgentConfigurationError("agent_tools_unavailable", {
          missingTools: ["research_web_search", "research_youtube_transcribe"],
        }),
      );
      const configurationRes = makeResponse();
      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          prompt: { text: "Research safely" },
          target: { workspaceId: "ws-1", worktreeId: "main" },
        }) as never,
        res: configurationRes as never,
      });

      expect(configurationRes.statusCode).toBe(422);
      expect(JSON.parse(configurationRes.body)).toMatchObject({
        code: "agent_tools_unavailable",
        error:
          "Reviewer can’t start in Oppi because these configured tools are unavailable: research_web_search, research_youtube_transcribe. Edit Reviewer → Resources → Extensions and select Extensions that provide these tools, or remove them from Allowed Tools. Then start again.",
        sessionId: expect.any(String),
        receipt: {
          accepted: false,
          retryable: false,
          reason: "agent_tools_unavailable",
          promptDispatch: "not_sent",
        },
        recovery: {
          actions: ["edit_agent"],
          agentId: agent.id,
          workspaceId: "ws-1",
          missingTools: ["research_web_search", "research_youtube_transcribe"],
        },
      });
      expect(sessions.at(-1)).toMatchObject({
        status: "error",
        launch: {
          status: "failed",
          promptDispatch: "not_sent",
          failure: { code: "agent_tools_unavailable" },
        },
      });

      store.updateAgent(agent.id, {
        launchConstraints: {
          allowedWorkspaceIds: ["research-workspace"],
          requiredRuntime: "sandbox",
        },
      });
      const workspaceConstraintRes = makeResponse();
      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          prompt: { text: "Use the wrong target" },
          target: { workspaceId: "ws-1", worktreeId: "main" },
        }) as never,
        res: workspaceConstraintRes as never,
      });

      expect(workspaceConstraintRes.statusCode).toBe(422);
      expect(JSON.parse(workspaceConstraintRes.body)).toMatchObject({
        code: "agent_workspace_incompatible",
        receipt: {
          accepted: false,
          retryable: false,
          reason: "agent_workspace_incompatible",
          promptDispatch: "not_sent",
        },
        recovery: {
          actions: ["choose_workspace", "edit_agent"],
          allowedWorkspaceIds: ["research-workspace"],
          requiredRuntime: "sandbox",
          actualRuntime: "host",
        },
      });
      expect(startSession).toHaveBeenCalledTimes(3);
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("launches an Agent with a historical malformed icon under unrelated overrides", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-historical-icon-launch-"));
    const databasePath = join(dataDir, "session-state.db");
    let store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({
        name: "Historian",
        icon: { kind: "symbol", name: "sparkles" },
        sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
      });
      store.close();

      const db = openDatabase(databasePath);
      db.prepare("UPDATE agent_definitions SET definition_json = ? WHERE id = ?").run(
        JSON.stringify({
          name: "Historian",
          icon: "historical/icon",
          sessionDefaults: { model: "agent-model", thinkingLevel: "high" },
        }),
        agent.id,
      );
      db.close();

      store = new AgentDefinitionStore(dataDir);
      const sessions: Session[] = [];
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          getDataDir: vi.fn(() => dataDir),
          createSession: vi.fn((name?: string, model?: string) => {
            const session = makeSession({ id: `sess-${sessions.length + 1}`, name, model });
            sessions.push(structuredClone(session));
            return session;
          }),
          saveSession: vi.fn((session: Session) => {
            const existing = sessions.findIndex((candidate) => candidate.id === session.id);
            const copy = structuredClone(session);
            if (existing >= 0) sessions[existing] = copy;
            else sessions.push(copy);
          }),
          getSession: vi.fn((sessionId: string) =>
            sessions.find((candidate) => candidate.id === sessionId),
          ),
          listSessions: vi.fn(() => sessions),
          findSessionByLaunchIdempotencyKey: vi.fn(),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: {
          startSession: vi.fn(async (sessionId: string) => {
            const session = sessions.find((candidate) => candidate.id === sessionId);
            if (!session) throw new Error("missing session");
            return session;
          }),
          sendPrompt: vi.fn(async () => undefined),
        },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const launch = async (overrides?: Record<string, unknown>): Promise<Session> => {
        const res = makeResponse();
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Read history" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            ...(overrides === undefined ? {} : { overrides }),
          }) as never,
          res: res as never,
        });
        expect(res.statusCode).toBe(201);
        return (JSON.parse(res.body) as { session: Session }).session;
      };

      const launches = [
        await launch(),
        await launch({ model: "override-model" }),
        await launch({ thinkingLevel: "low" }),
      ];
      expect(launches).toMatchObject([
        { model: "agent-model", thinkingLevel: "high" },
        { model: "override-model", thinkingLevel: "high" },
        { model: "agent-model", thinkingLevel: "low" },
      ]);
      for (const launched of launches) {
        expect(launched.launch?.agentIcon).toEqual({ kind: "default" });
      }

      for (const [overrides, errorFragment] of [
        [{ model: "   " }, "model"],
        [{ thinkingLevel: "turbo" }, "thinkingLevel"],
        [{ tools: "bash" }, "tools"],
        [{ excludeTools: [42] }, "excludeTools"],
        [{ noTools: "none" }, "noTools"],
      ] as const) {
        const sessionCount = sessions.length;
        const res = makeResponse();
        await dispatch({
          method: "POST",
          path: `/agents/${agent.id}/sessions`,
          url: new URL(`http://localhost/agents/${agent.id}/sessions`),
          req: makeRequest({
            prompt: { text: "Read history" },
            target: { workspaceId: "ws-1", worktreeId: "main" },
            overrides,
          }) as never,
          res: res as never,
        });
        expect(res.statusCode).toBe(400);
        expect(JSON.parse(res.body).error).toContain(errorFragment);
        expect(sessions).toHaveLength(sessionCount);
      }
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it.each([
    [{ parentSessionId: 42 }, "parentSessionId must be a non-empty string"],
    [{ parentSessionId: "   " }, "parentSessionId must be a non-empty string"],
    [{ allowNestedDelegation: "true" }, "allowNestedDelegation must be a boolean"],
  ])("rejects malformed delegation fields with HTTP 400", async (body, error) => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-delegation-routes-"));
    const store = new AgentDefinitionStore(dataDir);
    try {
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest(body) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body)).toEqual({ error });
    } finally {
      store.close();
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects invalid launch override values before creating a session", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-override-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({ name: "Reviewer" });
      const createSession = vi.fn();
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
          getWorkspace: vi.fn((workspaceId: string) =>
            workspaceId === "ws-1" ? { id: "ws-1", name: "Oppi" } : undefined,
          ),
          getDataDir: vi.fn(() => dataDir),
          createSession,
          saveSession: vi.fn(),
          listSessions: vi.fn(() => []),
          findSessionByLaunchIdempotencyKey: vi.fn(),
          claimSessionLaunchRecovery: vi.fn(),
        },
        sessions: { startSession: vi.fn(), sendPrompt: vi.fn() },
        ensureSessionContextWindow: vi.fn((session: Session) => session),
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: `/agents/${agent.id}/sessions`,
        url: new URL(`http://localhost/agents/${agent.id}/sessions`),
        req: makeRequest({
          prompt: { text: "Review this" },
          target: { workspaceId: "ws-1", worktreeId: "main" },
          overrides: { thinkingLevel: "turbo" },
        }) as never,
        res: res as never,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("thinkingLevel");
      expect(createSession).not.toHaveBeenCalled();
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects public Agent definitions that use reserved default identity names", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-reserved-name-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());

      const defaultNameRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "Oppi" }) as never,
        res: defaultNameRes as unknown as ServerResponse,
      });
      expect(defaultNameRes.statusCode).toBe(400);
      expect(JSON.parse(defaultNameRes.body).error).toContain("reserved");

      const aliasRes = makeResponse();
      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "oppi" }) as never,
        res: aliasRes as unknown as ServerResponse,
      });
      expect(aliasRes.statusCode).toBe(400);
      expect(JSON.parse(aliasRes.body).error).toContain("reserved");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects public Agent definitions that include launch targets", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-invalid-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const ctx = {
        storage: {
          getAgentDefinitionStore: () => store,
        },
      } as unknown as RouteContext;
      const dispatch = createAgentRoutes(ctx, createRouteHelpers());
      const res = makeResponse();

      await dispatch({
        method: "POST",
        path: "/agents",
        url: new URL("http://localhost/agents"),
        req: makeRequest({ name: "Bad", target: { workspaceId: "ws-1" } }) as never,
        res: res as unknown as ServerResponse,
      });

      expect(res.statusCode).toBe(400);
      expect(JSON.parse(res.body).error).toContain("target");
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });

  it("rejects unexpected Agent definition fields and empty updates", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "oppi-agent-strict-routes-"));
    try {
      const store = new AgentDefinitionStore(dataDir);
      const agent = store.createAgent({ name: "Reviewer" });
      const dispatch = createAgentRoutes(
        { storage: { getAgentDefinitionStore: () => store } } as unknown as RouteContext,
        createRouteHelpers(),
      );

      const unexpectedRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ description: "Updated", unexpected: true }) as never,
        res: unexpectedRes as unknown as ServerResponse,
      });
      expect(unexpectedRes.statusCode).toBe(400);
      expect(JSON.parse(unexpectedRes.body)).toEqual({
        error: "Agent definition has unexpected field: unexpected",
      });

      const nestedRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({ sessionDefaults: { model: "model", unexpected: true } }) as never,
        res: nestedRes as unknown as ServerResponse,
      });
      expect(nestedRes.statusCode).toBe(400);
      expect(JSON.parse(nestedRes.body)).toEqual({
        error: "sessionDefaults has unexpected field: unexpected",
      });

      const emptyRes = makeResponse();
      await dispatch({
        method: "PATCH",
        path: `/agents/${agent.id}`,
        url: new URL(`http://localhost/agents/${agent.id}`),
        req: makeRequest({}) as never,
        res: emptyRes as unknown as ServerResponse,
      });
      expect(emptyRes.statusCode).toBe(400);
      expect(JSON.parse(emptyRes.body)).toEqual({
        error: "Agent update must include at least one field",
      });
    } finally {
      rmSync(dataDir, { recursive: true, force: true });
    }
  });
});
