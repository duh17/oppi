import { writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import {
  fauxProvider,
  fauxAssistantMessage,
  fauxToolCall,
  type FauxResponseStep,
} from "@earendil-works/pi-ai/providers/faux";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { Storage } from "../src/storage.js";
import { SessionManager } from "../src/sessions.js";
import { SessionRuntimes } from "../src/runtime-router.js";
import type { ServerMessage } from "../src/types.js";
import { makeTempDir } from "./harness/temp-dir.js";
import { bootDurablePlugins, DURABLE_BOOT_TIMEOUT_MS } from "./harness/durable-boot.js";

// The durable `read` tool over internal URLs, through a real SessionManager, the real plugin host
// and built-ins, and a scripted model: what the agent sees is the tool result in its transcript.

// The first durable runtime in a worker imports every built-in plugin; boot that once here, on
// its own budget, instead of inside whichever test runs first.
beforeAll(bootDurablePlugins, DURABLE_BOOT_TIMEOUT_MS);

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
beforeEach(() => {
  process.env.PI_CODING_AGENT_DIR = makeTempDir("oppi-internal-urls-agent-");
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

const read = (path: string): FauxResponseStep =>
  fauxAssistantMessage([fauxToolCall("read", { path })], { stopReason: "toolUse" });

async function fixture(responses: FauxResponseStep[]) {
  const dir = makeTempDir("oppi-internal-urls-");
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
  storage.mutateConfig(() => ({ experimental: { serverDurable: true } }));
  const workspace = storage.createWorkspace({ name: "Internal URLs", hostMount: dir });
  const otherDir = join(dir, "other");
  mkdirSync(otherDir);
  const otherWorkspace = storage.createWorkspace({ name: "Elsewhere", hostMount: otherDir });
  const manager = new SessionManager(storage);
  managers.push(manager);
  await manager.resumeDurableSessions();
  const create = (name: string, workspaceId: string, parent?: string) => {
    const session = storage.createSession(name, "faux/faux-1");
    session.serverDurable = { storeId: session.id };
    session.workspaceId = workspaceId;
    if (parent) session.launch = { source: "agent", parentSessionId: parent };
    storage.saveSession(session);
    return session;
  };
  const turn = async (sessionId: string, text: string) => {
    const done = new Promise<void>((resolve) => {
      const stop = manager.subscribe(sessionId, (message: ServerMessage) => {
        if (message.type === "agent_end") {
          stop();
          resolve();
        }
      });
    });
    await manager.sendPrompt(sessionId, text);
    await done;
  };
  /** The text of every `read` result the session has, in order. */
  const reads = async (sessionId: string) =>
    (
      (await manager.runCommand(sessionId, { type: "get_messages" })) as Array<{
        role: string;
        toolName?: string;
        isError?: boolean;
        content?: Array<{ type: string; text?: string }>;
      }>
    )
      .filter((m) => m.role === "toolResult" && m.toolName === "read")
      .map((m) => ({
        isError: m.isError === true,
        text: (m.content ?? []).map((part) => part.text ?? "").join(""),
      }));
  return { dir, storage, workspace, otherWorkspace, manager, faux, create, turn, reads };
}

describe("internal URLs through the durable read tool", () => {
  it("reads sibling transcripts, a launched child's answer, and refuses other workspaces", async () => {
    const f = await fixture([]);
    const parent = f.create("Parent", f.workspace.id);
    const child = f.create("Child", f.workspace.id, parent.id);
    const sibling = f.create("Sibling", f.workspace.id);
    const stranger = f.create("Stranger", f.otherWorkspace.id, parent.id);
    // The child answers first; then the parent reads it.
    f.faux.setResponses([
      fauxAssistantMessage("CHILD-ANSWER-42"),
      fauxAssistantMessage("SIBLING-WORDS"),
      read("agent://"),
      read(`agent://${child.id.slice(0, 8)}`),
      read(`history://${sibling.id}`),
      read("history://"),
      read(`agent://${sibling.id}`),
      read(`history://${stranger.id}`),
      read(`agent://${stranger.id}`),
      read("pr://12"),
      read("artifact://1"),
      read("history://zzzz-not-a-session"),
      read("note.txt"),
      fauxAssistantMessage("DONE"),
    ]);
    for (const session of [child, sibling, parent]) {
      await f.manager.startSession(session.id, f.workspace);
    }
    writeFileSync(join(f.dir, "note.txt"), "plain file still reads\n");
    await f.turn(child.id, "work");
    await f.turn(sibling.id, "talk");
    await f.turn(parent.id, "inspect");
    const results = await f.reads(parent.id);

    expect(results.map((r) => r.isError)).toEqual([
      false,
      false,
      false,
      false,
      true,
      true,
      true,
      true,
      true,
      true,
      false,
    ]);
    // Bare agent:// lists only what this session launched.
    expect(results[0]!.text).toContain(child.id);
    expect(results[0]!.text).not.toContain(sibling.id);
    expect(results[0]!.text).not.toContain(stranger.id);
    // A prefix names the child; its latest answer is the text.
    expect(results[1]!.text).toContain("CHILD-ANSWER-42");
    expect(results[2]!.text).toContain("SIBLING-WORDS");
    // history:// lists this workspace only.
    expect(results[3]!.text).toContain(sibling.id);
    expect(results[3]!.text).not.toContain(stranger.id);
    // A sibling is readable by history:// but is not this session's child.
    expect(results[4]!.text).toContain(`No child session "${sibling.id}"`);
    expect(results[4]!.text).toContain(child.id);
    // Another workspace's session does not exist from here, under either scheme.
    expect(results[5]!.text).toContain("No session");
    expect(results[5]!.text).not.toContain(stranger.id.concat("  "));
    expect(results[6]!.text).toContain("No child session");
    expect(results[7]!.text).toContain("gh pr view");
    expect(results[8]!.text).toContain("artifact:// is not available");
    expect(results[9]!.text).toContain(`Valid ids:`);
    expect(results[10]!.text).toContain("plain file still reads");
  }, 30_000);

  it("reads a background job's live output and lists jobs through proc://", async () => {
    const f = await fixture([]);
    const session = f.create("Jobs", f.workspace.id);
    vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(
      async (_command, options, execContext) => {
        options?.onOutput?.("live line one\n");
        return await new Promise((_resolve, reject) => {
          execContext.abortSignal!.addEventListener(
            "abort",
            () => reject(execContext.abortSignal!.reason),
            { once: true },
          );
        });
      },
    );
    f.faux.setResponses([
      fauxAssistantMessage(
        [fauxToolCall("background_job", { action: "start", command: "watch things" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      read("proc://"),
      read("proc://bash"),
      read("proc://nope"),
      fauxAssistantMessage("DONE"),
    ]);
    await f.manager.startSession(session.id, f.workspace);
    await f.turn(session.id, "start");
    await f.turn(session.id, "look");
    const [list, one, missing] = await f.reads(session.id);
    expect(list).toMatchObject({ isError: false });
    expect(list!.text).toContain("bash-1  running  watch things");
    expect(one).toMatchObject({ isError: false });
    expect(one!.text).toContain("bash-1  running");
    expect(one!.text).toContain("live line one");
    expect(missing).toMatchObject({ isError: true });
    expect(missing!.text).toContain("Valid ids: bash-1");
  });
});

describe("the app's view of an internal URL", () => {
  it("shows a running job's live output, appends from an offset, stops it, then reads the delivered card", async () => {
    const f = await fixture([]);
    // The app's route reads through the runtimes; a durable session never reaches the pi-tui runtime.
    const runtimes = new SessionRuntimes(f.storage, f.manager, undefined as never);
    const session = f.create("Jobs", f.workspace.id);
    let print: (text: string) => void = () => {};
    vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(
      async (_command, options, execContext) => {
        print = (text) => options?.onOutput?.(text);
        print("\u001b[32mline one\u001b[0m\n");
        // Runs until Stop, then reports the kill as the real environment does.
        await new Promise<void>((resolve) =>
          execContext.abortSignal!.addEventListener("abort", () => resolve(), { once: true }),
        );
        return { ok: false, error: { code: "aborted", message: "aborted" } };
      },
    );
    f.faux.setResponses([
      fauxAssistantMessage(
        [
          fauxToolCall("background_job", {
            action: "start",
            command: "cd /tmp && make build",
          }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("SEEN"),
    ]);
    await f.manager.startSession(session.id, f.workspace);
    await f.turn(session.id, "start");

    const running = await runtimes.viewInternalUrl(session.id, "proc://bash");
    expect(running).toMatchObject({
      url: "proc://bash-1",
      title: "make build",
      status: { text: "Running", tone: "accent", live: true },
      command: "cd /tmp && make build",
      output: { start: 0, text: "\u001b[32mline one\u001b[0m\n", truncated: false },
      stoppable: true,
    });
    expect(running!.facts.map((fact) => fact.label)).toEqual(["Folder", "Started", "Job"]);

    // A read from the end of what the app holds returns only what came after it.
    print("line two\n");
    const held = running!.output.text.length;
    const next = await runtimes.viewInternalUrl(session.id, "proc://bash-1", held);
    expect(next!.output).toEqual({ start: held, text: "line two\n", truncated: false });

    expect(await runtimes.stopInternalUrl(session.id, "proc://bash-1")).toBeUndefined();
    await vi.waitFor(
      async () => {
        const view = await runtimes.viewInternalUrl(session.id, "proc://bash-1");
        expect(view!.status).toMatchObject({ text: "Stopped", live: false });
        expect(view!.status.endedAt).toBeGreaterThanOrEqual(view!.status.startedAt!);
        expect(view!.stoppable).toBe(false);
        // Delivered or not, the output is the job's: its saved output, then the result card's.
        expect(view!.output.text).toContain("line two");
      },
      { timeout: 8_000 },
    );
    // Once the result is delivered and the model has read it, the output comes from its card.
    await vi.waitFor(
      async () => {
        const messages = (await f.manager.runCommand(session.id, {
          type: "get_messages",
        })) as Array<{
          role: string;
          content?: unknown;
        }>;
        expect(JSON.stringify(messages.filter((m) => m.role === "assistant"))).toContain("SEEN");
      },
      { timeout: 5_000 },
    );
    const delivered = await runtimes.viewInternalUrl(session.id, "proc://bash-1");
    expect(delivered!.output.text).toContain("line one");
    expect(delivered!.output.text).toContain("line two");
    expect(await runtimes.stopInternalUrl(session.id, "proc://bash-1")).toBe(
      "bash-1 is not running.",
    );

    await expect(runtimes.viewInternalUrl(session.id, "proc://nope")).rejects.toThrow(
      "Valid ids: bash-1",
    );
    await expect(runtimes.viewInternalUrl(session.id, "history://x")).rejects.toThrow(
      "Oppi cannot show history://x",
    );
  }, 30_000);

  it("keeps a long job's output at its true offsets after it ends, so a reader resumes where it left off", async () => {
    const f = await fixture([]);
    const runtimes = new SessionRuntimes(f.storage, f.manager, undefined as never);
    const session = f.create("Long", f.workspace.id);
    // 70,000 characters where each one names its offset mod 10: 6,000 drop off the front.
    const whole = "0123456789".repeat(7_000);
    vi.spyOn(NodeExecutionEnv.prototype, "exec").mockImplementation(async (_command, options) => {
      options?.onOutput?.(whole);
      return { ok: true, value: { exitCode: 0, stdout: "", stderr: "" } };
    });
    f.faux.setResponses([
      fauxAssistantMessage(
        [fauxToolCall("background_job", { action: "start", command: "make logs" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("STARTED"),
      fauxAssistantMessage("SEEN"),
    ]);
    await f.manager.startSession(session.id, f.workspace);
    await f.turn(session.id, "start");

    const resumeAt = 66_000;
    const expectTrueOffsets = async (): Promise<void> => {
      const view = await runtimes.viewInternalUrl(session.id, "proc://bash-1");
      expect(view!.status.live).toBe(false);
      expect(view!.output).toEqual({ start: 6_000, text: whole.slice(6_000), truncated: true });
      const resumed = await runtimes.viewInternalUrl(session.id, "proc://bash-1", resumeAt);
      expect(resumed!.output).toEqual({
        start: resumeAt,
        text: whole.slice(resumeAt),
        truncated: true,
      });
    };
    // Saved output, or already the card's: both keep the job's offsets.
    await vi.waitFor(expectTrueOffsets, { timeout: 8_000 });
    await vi.waitFor(
      async () => {
        const messages = (await f.manager.runCommand(session.id, {
          type: "get_messages",
        })) as Array<{ role: string; content?: unknown }>;
        expect(JSON.stringify(messages.filter((m) => m.role === "assistant"))).toContain("SEEN");
      },
      { timeout: 5_000 },
    );
    // The delivered card's output.
    await expectTrueOffsets();
  }, 30_000);
});

describe("mcp:// through a real MCP server", () => {
  it("lists and reads a resource the session's MCP server offers", async () => {
    const server = fileURLToPath(new URL("./fixtures/mcp-resource-server.mjs", import.meta.url));
    mkdirSync(process.env.PI_CODING_AGENT_DIR!, { recursive: true });
    writeFileSync(
      join(process.env.PI_CODING_AGENT_DIR!, "mcp.json"),
      JSON.stringify({ mcpServers: { notes: { command: process.execPath, args: [server] } } }),
    );
    const f = await fixture([]);
    const session = f.create("Resources", f.workspace.id);
    f.faux.setResponses([
      read("mcp://"),
      read("mcp://test://notes"),
      read("mcp://test://missing"),
      fauxAssistantMessage("DONE"),
    ]);
    await f.manager.startSession(session.id, f.workspace);
    await f.turn(session.id, "resources");
    const [list, body, missing] = await f.reads(session.id);
    expect(list).toMatchObject({ isError: false });
    expect(list!.text).toContain("notes  test://notes  Notes");
    expect(body).toMatchObject({ isError: false });
    expect(body!.text).toBe("NOTES-RESOURCE-BODY");
    expect(missing).toMatchObject({ isError: true });
    expect(missing!.text).toContain('No MCP resource "test://missing"');
  }, 30_000);
});
