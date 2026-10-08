import { fileURLToPath } from "node:url";
import type {
  ConversationEntryView,
  ConversationStreamAttach,
  ConversationStreamServerMessage,
} from "../src/types.js";
import { serializeProtocolFixture } from "./protocol-fixtures.js";

// Experimental durable conversation stream (capabilities.conversationStream v1).
// Kept apart from server-messages.json: those examples must all decode as known
// focused-stream events in the Apple client, which does not model this stream yet.

export const CONVERSATION_STREAM_SNAPSHOT_FILE = fileURLToPath(
  new URL("../../protocol/conversation-stream.json", import.meta.url),
);
export const CONVERSATION_STREAM_FIXTURE_DESCRIPTION =
  "Experimental durable conversation stream frames — updated by npm run protocol:fixtures:update";

const usage = {
  input: 668,
  output: 68,
  cacheRead: 0,
  cacheWrite: 668,
  totalTokens: 1404,
  cost: { input: 0.002, output: 0.001, cacheRead: 0, cacheWrite: 0, total: 0.003 },
};

const userEntry: ConversationEntryView = {
  id: 8,
  kind: "pi.user",
  model: [{ role: "user", content: "List the files", timestamp: 1_791_650_000_000 }],
};

const toolCallEntry: ConversationEntryView = {
  id: 9,
  kind: "pi.assistant",
  model: [
    {
      role: "assistant",
      content: [{ type: "toolCall", id: "call-1", name: "bash", arguments: { command: "ls" } }],
      api: "anthropic-messages",
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage,
      stopReason: "toolUse",
      timestamp: 1_791_650_001_000,
    },
  ],
  toolCalls: {
    "call-1": {
      callSegments: [
        { text: "$ ", style: "bold" },
        { text: "ls", style: "accent" },
      ],
      inputPresentation: { fields: { command: { role: "command", language: "bash" } } },
      outputPresentation: { kind: "terminal" },
    },
  },
};

const toolResultEntry: ConversationEntryView = {
  id: 10,
  kind: "pi.tool-result",
  model: [
    {
      role: "toolResult",
      toolCallId: "call-1",
      toolName: "bash",
      content: [{ type: "text", text: "README.md\nsrc\n" }],
      isError: false,
      timestamp: 1_791_650_002_000,
    },
  ],
  toolResult: {
    resultSegments: [{ text: "2 lines", style: "muted" }],
    outputPresentation: { kind: "terminal" },
    outputAvailability: { complete: true },
  },
};

const answerEntry: ConversationEntryView = {
  id: 11,
  kind: "pi.assistant",
  model: [
    {
      role: "assistant",
      content: [{ type: "text", text: "There are two entries." }],
      api: "anthropic-messages",
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage,
      stopReason: "stop",
      timestamp: 1_791_650_003_000,
    },
  ],
};

const cardEntry: ConversationEntryView = {
  id: 12,
  kind: "oppi.failure",
  data: {
    card: {
      title: "Run failed",
      body: "Provider overloaded",
      accent: "error",
      at: 1_791_650_004_000,
    },
  },
};

const compactionEntry: ConversationEntryView = {
  id: 20,
  kind: "pi.compaction",
  model: [
    { role: "user", content: "<summary>Listed files</summary>", timestamp: 1_791_650_005_000 },
  ],
};

const CONVERSATION_STREAM_SERVER_MESSAGES = {
  snapshot: {
    type: "snapshot",
    conversationId: 3,
    head: 0,
    hasOlder: false,
    entries: [userEntry, toolCallEntry, toolResultEntry],
    docs: {
      "pi.live": {
        run: { taskId: 14, inputs: [7] },
        generation: {
          attempt: 1,
          message: {
            role: "assistant",
            content: [{ type: "text", text: "There are" }],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage,
            stopReason: "pending",
            timestamp: 1_791_650_003_000,
          },
        },
      },
      "pi.inbox": { items: [] },
      "pi.agent": {
        model: { provider: "anthropic", modelId: "claude-sonnet-4-5" },
        thinkingLevel: "medium",
        tools: ["read", "bash", "edit", "write"],
        cwd: "/workspace/project",
      },
      "pi.usage": { models: { "anthropic/claude-sonnet-4-5": usage } },
      "oppi.extension-ui": {
        requests: {
          "ask-1": { id: "ask-1", method: "confirm", title: "Delete build/?" },
        },
        notifications: {
          "status:jobs": {
            id: "status:jobs",
            method: "setStatus",
            statusKey: "jobs",
            statusText: "1 job running",
          },
        },
      },
    },
  },
  update_append: {
    type: "update",
    conversationId: 3,
    docs: { "pi.live": [["a", ["generation", "message", "content", 0, "text"], " two entries."]] },
  },
  update_landing: {
    type: "update",
    conversationId: 3,
    entries: [answerEntry],
    docs: {
      "pi.live": [
        ["d", ["run"]],
        ["d", ["generation"]],
      ],
      "pi.usage": [["s", ["models", "anthropic/claude-sonnet-4-5", "output"], 82]],
    },
  },
  update_running_tool: {
    type: "update",
    conversationId: 3,
    docs: {
      "pi.live": [
        [
          "s",
          ["tools"],
          [
            {
              callId: "call-1",
              name: "bash",
              taskId: 15,
              status: "running",
              output: "README.md\n",
            },
          ],
        ],
        [
          "s",
          ["toolCalls"],
          {
            "call-1": {
              callSegments: [
                { text: "$ ", style: "bold" },
                { text: "ls", style: "accent" },
              ],
              outputPresentation: { kind: "terminal" },
            },
          },
        ],
      ],
    },
  },
  update_output_window: {
    type: "update",
    conversationId: 3,
    docs: {
      "pi.live": [
        ["t", ["tools", 0, "output"], 10],
        ["a", ["tools", 0, "output"], "src\n"],
      ],
    },
  },
  update_resume: {
    type: "update",
    conversationId: 3,
    entries: [cardEntry],
    docs: {
      "pi.live": [["r", {}]],
      "pi.inbox": [["r", { items: [] }]],
      "pi.agent": [["r", { model: { provider: "anthropic", modelId: "claude-sonnet-4-5" } }]],
      "pi.usage": [["r", { models: {} }]],
      "oppi.extension-ui": null,
    },
  },
  snapshot_after_compaction: {
    type: "snapshot",
    conversationId: 3,
    head: 20,
    hasOlder: true,
    entries: [compactionEntry, answerEntry, cardEntry],
    docs: { "pi.live": {} },
  },
} satisfies Record<string, ConversationStreamServerMessage>;

const CONVERSATION_STREAM_CLIENT_MESSAGES = {
  attach: { type: "attach", requestId: "req-attach-1" },
  attach_resume: { type: "attach", conversationId: 3, afterEntryId: 11, requestId: "req-attach-2" },
  attach_by_session: { type: "attach", sessionId: "test-session-1" },
} satisfies Record<string, ConversationStreamAttach>;

export function buildConversationStreamMessages(): Record<string, unknown> {
  return {
    ...Object.fromEntries(
      Object.entries(CONVERSATION_STREAM_SERVER_MESSAGES).map(([key, value]) => [
        `server.${key}`,
        value,
      ]),
    ),
    ...Object.fromEntries(
      Object.entries(CONVERSATION_STREAM_CLIENT_MESSAGES).map(([key, value]) => [
        `client.${key}`,
        value,
      ]),
    ),
  };
}

export function serializeConversationStreamFixture(): string {
  return serializeProtocolFixture(
    CONVERSATION_STREAM_FIXTURE_DESCRIPTION,
    buildConversationStreamMessages(),
  );
}
