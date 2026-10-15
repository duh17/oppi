import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { ModelRuntime } from "@earendil-works/pi-coding-agent";
import {
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
  fauxThinking,
  fauxToolCall,
} from "@earendil-works/pi-ai/providers/faux";
import { Harness, createRegistry, type Conversation } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { CodingTools } from "@earendil-works/pi-durable/tools";
import { NodeExecutionEnv } from "@earendil-works/pi-durable/env/node";
import { DurableInputCards } from "../extensions/durable/durable-ui.js";
import {
  attachConversationStream,
  readOlderConversationEntries,
} from "../src/durable-conversation-stream.js";
import { readDurableTrace } from "../src/durable-history.js";
import { MobileRendererRegistry } from "../src/mobile-renderer.js";
import { withMobileRenderSegments } from "../src/session-trace-service.js";
import type { ConversationStreamServerMessage } from "../src/types.js";

// Golden equivalence fixture for the Apple conversation replica: every stream frame one
// client received for a real Harness conversation, and the trace the same conversation
// reads as through the mobile trace route (`view=full`, presentation segments). The Apple
// test replays the frames and must project exactly that trace. Written only by
// `npm run protocol:fixtures:update`; the conversation's ids and times change each run.

export const CONVERSATION_STREAM_GOLDEN_FILE = fileURLToPath(
  new URL("../../protocol/conversation-stream-golden.json", import.meta.url),
);

const PNG_1X1 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
const INTERRUPTED = Array.from({ length: 60 }, (_, index) => `partial${index}`).join(" ");

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export async function buildConversationStreamGolden(): Promise<string> {
  const dir = mkdtempSync(join(tmpdir(), "oppi-conversation-golden-"));
  const models = await ModelRuntime.create({
    authPath: join(dir, "auth.json"),
    modelsPath: null,
    modelsStorePath: join(dir, "models-cache.json"),
    refreshOnCreate: false,
  });
  // Slow enough that streamed text reaches clients as several append frames.
  const faux = fauxProvider({ tokensPerSecond: 120, tokenSize: { min: 4, max: 4 } });
  models.registerNativeProvider(faux.provider);
  await models.setRuntimeApiKey("faux", "test-only-faux-credential");
  await models.refresh({ allowNetwork: false });
  const registry = createRegistry();
  registry.install(CodingTools);
  const open = async () =>
    Harness.open(
      await openNodeSqliteStorage(join(dir, "golden.sqlite")),
      {
        models,
        registry,
        env: () => new NodeExecutionEnv({ cwd: dir }),
        // Manual compaction keeps only the newest turn, so older history exists to page.
        settings: {
          compaction: {
            enabled: false,
            reserveTokens: 16_384,
            keepRecentTokens: 20,
            backgroundTokens: 0,
          },
        },
      },
      context,
    );
  const renderers = new MobileRendererRegistry();
  const frames: ConversationStreamServerMessage[] = [];
  const record = (frame: ConversationStreamServerMessage) =>
    frames.push(JSON.parse(JSON.stringify(frame)) as ConversationStreamServerMessage);
  const held = new Set<number>();
  const hold = (frame: ConversationStreamServerMessage) => {
    if (frame.type === "snapshot") held.clear();
    for (const entry of frame.type === "update" ? (frame.entries ?? []) : frame.entries)
      held.add(entry.id);
  };

  let harness = await open();
  try {
    let conversation: Conversation = await harness.createConversation(
      {
        ownership: { kind: "ownerless" },
        agent: {
          model: { provider: "faux", modelId: "faux-1" },
          tools: [...(CodingTools.tools ?? [])],
          cwd: dir,
        },
      },
      context,
    );
    const id = conversation.id;
    const attach = async (afterEntryId?: number) =>
      attachConversationStream({
        harness,
        conversationId: id,
        renderers,
        ...(afterEntryId !== undefined ? { afterEntryId } : {}),
        send: (frame) => {
          record(frame);
          hold(frame);
        },
      });
    const settle = () => wait(300);
    const turn = async (content: Parameters<Conversation["submit"]>[0]) => {
      const submission = await conversation.submit(content, context);
      await submission.wait(context);
      await conversation.waitForIdle(context);
      await settle();
    };

    let subscription = await attach();
    faux.setResponses([
      // Thinking, text, and a bash call with terminal output.
      fauxAssistantMessage(
        [
          fauxThinking("The user wants a file listing."),
          fauxText("Listing the files."),
          fauxToolCall("bash", { command: "printf 'README.md\\nsrc\\n'" }, { id: "call-list" }),
        ],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("There are two entries: README.md and src."),
      // A failing tool call.
      fauxAssistantMessage(
        [fauxToolCall("bash", { command: "echo boom >&2; exit 3" }, { id: "call-fail" })],
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("The command failed with exit code 3."),
      fauxAssistantMessage("Thanks for the job report."),
      fauxAssistantMessage("Summary of the work so far: listed files, ran a failing command."),
      fauxAssistantMessage(INTERRUPTED),
    ]);

    await turn({ type: "input", content: "List the files" });
    await turn({
      type: "input",
      content: [
        { type: "text", text: "Run the failing command for this image" },
        { type: "image", data: PNG_1X1, mimeType: "image/png" },
      ],
    });

    // A display card: an entry without model messages whose data carries a card.
    await conversation.commit(async (tx) => {
      await tx.appendEntry(id, {
        kind: "oppi.notice",
        data: {
          card: {
            title: "Deploy finished",
            subtitle: "staging",
            status: "completed",
            body: "All checks passed.",
            fields: [{ label: "Duration", value: "42s" }],
            accent: "success",
            at: 1_791_650_000_000,
          },
        },
      });
    }, context);
    await settle();

    // An extension-generated input: card metadata first, then the input it names.
    const report = "build ok\nexit 0";
    await conversation.commit(async (tx) => {
      const cards = await tx.doc(DurableInputCards, id);
      cards.requests["job-1"] = {
        title: "Background job 1",
        status: "completed",
        body: "make build",
        fields: [{ label: "Result", value: "Exit 0" }],
        accent: "success",
        output: { kind: "terminal", offset: 0, length: report.length, command: "make build" },
        at: 1_791_650_001_000,
      };
    }, context);
    await turn({ type: "input", content: report, requestId: "job-1" });

    // A real compaction: the summary request is the next faux answer.
    await conversation.compact(undefined, context);
    await conversation.waitForIdle(context);
    await settle();

    // A restart mid-answer: the retried attempt's partial must never show.
    const interrupted = await conversation.submit(
      { type: "input", content: "Explain it at length" },
      context,
    );
    void interrupted.wait(context).catch(() => undefined);
    const streamed = frames.length;
    for (let tries = 0; tries < 200; tries += 1) {
      const live = frames
        .slice(streamed)
        .some(
          (frame) =>
            frame.type === "update" &&
            JSON.stringify(frame.docs?.["pi.live"] ?? []).includes("partial1"),
        );
      if (live) break;
      await wait(25);
    }
    await harness.close(context);
    subscription.dispose();
    faux.setResponses([fauxAssistantMessage("A complete answer after the restart.")]);
    harness = await open();
    conversation = (await harness.conversation(id, context))!;
    subscription = await attach(Math.max(...held));
    harness.resume();
    await conversation.waitForIdle(context);
    await settle();

    // Page the history the compaction left out, as a client scrolling up does.
    for (;;) {
      const frame = await readOlderConversationEntries({
        harness,
        conversationId: id,
        renderers,
        beforeEntryId: Math.min(...held),
      });
      record(frame);
      hold(frame);
      if (!frame.hasOlder) break;
    }
    subscription.dispose();

    const trace = withMobileRenderSegments(
      await readDurableTrace(harness, id, "full"),
      renderers,
      true,
      [],
    );
    return `${JSON.stringify(
      {
        _meta: {
          description:
            "Durable conversation stream golden: frames one client received, and the mobile trace of the same conversation. Updated by npm run protocol:fixtures:update",
        },
        frames,
        trace: JSON.parse(JSON.stringify(trace)) as unknown,
      },
      null,
      2,
    )}\n`;
  } finally {
    await harness.close(context).catch(() => undefined);
    rmSync(dir, { recursive: true, force: true });
  }
}
