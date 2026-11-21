import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime, SettingsManager } from "@earendil-works/pi-coding-agent";
import type { Message, SimpleStreamOptions } from "@earendil-works/pi-ai";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
  type FauxResponseFactory,
} from "@earendil-works/pi-ai/providers/faux";
import { UsageDoc, type ConversationId, type Harness } from "@earendil-works/pi-durable";
import { SessionHost } from "../src/durable-harness.js";
import { SessionManager } from "../src/sessions.js";
import { Storage } from "../src/storage.js";
import type { ServerMessage } from "../src/types.js";
import { bootDurablePlugins, DURABLE_BOOT_TIMEOUT_MS } from "./harness/durable-boot.js";
import { makeTempDir } from "./harness/temp-dir.js";

beforeAll(bootDurablePlugins, DURABLE_BOOT_TIMEOUT_MS);

// The built-in `cached-compaction` plugin, driven as the owner would: off unless the server
// config turns it on, and then a manual compaction summarizes through the conversation's own
// request, which the faux provider's prompt cache (per provider session) reads back.

const managers: SessionManager[] = [];
const previousAgentDir = process.env.PI_CODING_AGENT_DIR;
beforeEach(() => {
  process.env.PI_CODING_AGENT_DIR = makeTempDir("cached-compaction-agent-");
});
afterEach(async () => {
  await Promise.all(managers.splice(0).map((manager) => manager.close()));
  vi.restoreAllMocks();
  if (previousAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
  else process.env.PI_CODING_AGENT_DIR = previousAgentDir;
});

type Call = {
  messages: readonly Message[];
  options: SimpleStreamOptions | undefined;
};

const SUMMARY = "## Goal\nKeep the parser fix";

function textOf(message: Message | undefined): string {
  if (message === undefined) return "";
  if (typeof message.content === "string") return message.content;
  return message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("");
}

function isSummaryRequest(messages: readonly Message[]): boolean {
  return (
    textOf(messages[0]).includes("context summarization assistant") ||
    textOf(messages.at(-1)).includes("context checkpoint summary")
  );
}

/**
 * A durable server over a faux model priced like Opus 5.5. Its first answer is long text, or
 * with `reads`, reads that many files of 50 KB (the read tool's cap) and then answers briefly;
 * the last answer is short.
 */
async function fixture(enabled: boolean, reads = 0) {
  const dir = makeTempDir("cached-compaction-durable-");
  const files = Array.from({ length: reads }, (_, index) => `tool-output-${index}.txt`);
  for (const file of files) writeFileSync(join(dir, file), "x".repeat(50 * 1024));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  const calls: Call[] = [];
  const faux = fauxProvider({
    models: [{ id: "faux-1", cost: { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 } }],
  });
  const turns = [
    ...(files.length === 0
      ? []
      : [
          fauxAssistantMessage(
            files.map((path) => fauxToolCall("read", { path })),
            { stopReason: "toolUse" },
          ),
        ]),
    fauxAssistantMessage(files.length === 0 ? "Earlier context ".repeat(400) : "Read them."),
    fauxAssistantMessage("Latest context"),
  ];
  const respond: FauxResponseFactory = (transcript, options) => {
    const answer = isSummaryRequest(transcript.messages)
      ? fauxAssistantMessage(SUMMARY)
      : (turns.shift() ?? fauxAssistantMessage("DONE"));
    calls.push({ messages: structuredClone(transcript.messages), options });
    return answer;
  };
  faux.setResponses(Array.from({ length: 10 }, () => respond));
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  vi.spyOn(ModelRuntime, "create").mockResolvedValue(models);
  vi.spyOn(SettingsManager, "create").mockImplementation(() =>
    SettingsManager.inMemory({
      defaultProvider: "faux",
      defaultModel: "faux-1",
      defaultThinkingLevel: "off",
      compaction: { enabled: true, keepRecentTokens: 1, reserveTokens: 100, backgroundTokens: 0 },
    }),
  );
  const storage = new Storage(dir);
  storage.mutateConfig(() => ({
    experimental: {
      serverDurable: true,
      ...(enabled ? { durableExtensions: { enabled: ["cached-compaction"] } } : {}),
    },
  }));
  const workspace = storage.createWorkspace({ name: "Compaction", hostMount: dir });
  const session = storage.createSession("Compaction", "faux/faux-1");
  session.serverDurable = { storeId: session.id };
  session.workspaceId = workspace.id;
  storage.saveSession(session);
  const manager = new SessionManager(storage);
  managers.push(manager);
  const opening = vi.spyOn(SessionHost.prototype, "open");
  await manager.resumeDurableSessions();
  await manager.startSession(session.id, workspace);
  const { harness } = (await opening.mock.results[0]!.value) as { harness: Harness };
  const conversationId = storage.getSession(session.id)!.serverDurable!
    .conversationId! as ConversationId;
  return { calls, manager, session, harness, conversationId };
}

function waitFor(
  manager: SessionManager,
  sessionId: string,
  type: ServerMessage["type"],
): Promise<ServerMessage> {
  return new Promise((resolve) => {
    const unsubscribe = manager.subscribe(sessionId, (message) => {
      if (message.type !== type) return;
      unsubscribe();
      resolve(message);
    });
  });
}

/**
 * Two answered prompts, then a manual compaction: its `compaction_end`, and the cache reads the
 * conversation's usage gained beyond its answers', which is what the summary request read.
 */
async function compactAfterTwoTurns(f: Awaited<ReturnType<typeof fixture>>) {
  for (const text of ["read the parser", "now fix it"]) {
    const ended = waitFor(f.manager, f.session.id, "agent_end");
    await f.manager.sendPrompt(f.session.id, text);
    await ended;
  }
  const conversation = (await f.harness.conversation(f.conversationId, context))!;
  const answersRead = (await conversation.context(context)).messages.reduce(
    (sum, message) => sum + (message.role === "assistant" ? message.usage.cacheRead : 0),
    0,
  );
  const ended = waitFor(f.manager, f.session.id, "compaction_end");
  await f.manager.runCommand(f.session.id, { type: "compact" });
  const end = await ended;
  const usage = await f.harness.snapshot(UsageDoc, f.conversationId, context);
  return { end, summaryRead: usage!.models["faux/faux-1"]!.cacheRead - answersRead };
}

describe("cached-compaction plugin", () => {
  it("is off by default: a compaction sends pi-durable's own uncached summary request", async () => {
    const f = await fixture(false);
    const { end, summaryRead } = await compactAfterTwoTurns(f);
    expect(end).toMatchObject({ summary: SUMMARY });
    expect(summaryRead).toBe(0);

    const summary = f.calls.find((call) => isSummaryRequest(call.messages))!;
    expect(summary.messages).toHaveLength(2);
    expect(summary.messages[0]).toMatchObject({ role: "system" });
    expect(summary.options?.cacheRetention).toBe("none");
  });

  it("when on, summarizes through the conversation's cached request and places pi-durable's summary entry", async () => {
    const f = await fixture(true);
    const { end, summaryRead } = await compactAfterTwoTurns(f);
    expect(end).toMatchObject({ summary: SUMMARY });

    const summaries = f.calls.filter((call) => isSummaryRequest(call.messages));
    expect(summaries).toHaveLength(1);
    const [summary] = summaries;
    const last = f.calls.filter((call) => !isSummaryRequest(call.messages)).at(-1)!;
    // The conversation's last request, its answer, then one instruction: the same prefix.
    expect(summary!.messages.slice(0, last.messages.length)).toEqual(last.messages);
    expect(summary!.messages[last.messages.length]).toMatchObject({ role: "assistant" });
    expect(summary!.messages).toHaveLength(last.messages.length + 2);
    expect(summary!.messages.at(-1)).toMatchObject({ role: "user" });
    // The kept part starts at the second prompt's answer; the instruction quotes it.
    expect(textOf(summary!.messages.at(-1))).toContain(
      "<kept-start>\nLatest context\n</kept-start>",
    );
    expect(summary!.options?.cacheRetention).toBeUndefined();
    expect(summary!.options?.sessionId).toBe(last.options?.sessionId);
    // The provider read the conversation from its cache, and the read is counted as the session's.
    expect(summaryRead).toBeGreaterThan(0);

    const view = await (await f.harness.conversation(f.conversationId, context))!.context(context);
    expect(view.head).toMatchObject({
      kind: "pi.compaction",
      data: { reason: "manual" },
      model: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: `The conversation history before this point was compacted into the following summary:\n\n<summary>\n${SUMMARY}\n</summary>`,
            },
          ],
        },
      ],
    });
    expect(textOf(view.messages.find((message) => message.role === "assistant"))).toBe(
      "Latest context",
    );
  });

  it("when on, leaves a history of long tool output to pi-durable's request, which cuts it and costs less", async () => {
    const f = await fixture(true, 2);
    const { end, summaryRead } = await compactAfterTwoTurns(f);
    expect(end).toMatchObject({ summary: SUMMARY });
    expect(summaryRead).toBe(0);

    const summaries = f.calls.filter((call) => isSummaryRequest(call.messages));
    expect(summaries).toHaveLength(1);
    expect(summaries[0]!.messages[0]).toMatchObject({ role: "system" });
    expect(summaries[0]!.options?.cacheRetention).toBe("none");
  });
});
