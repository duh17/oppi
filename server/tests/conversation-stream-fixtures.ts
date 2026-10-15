import { fileURLToPath } from "node:url";
import type {
  ConversationEntryView,
  ConversationStreamAttach,
  ConversationStreamOlder,
  ConversationStreamServerMessage,
} from "../src/types.js";
import { serializeProtocolFixture } from "./protocol-fixtures.js";

// Experimental durable conversation stream (capabilities.conversationStream v1).
// Kept apart from server-messages.json: those examples must all decode as known
// focused-stream events in the Apple client, which reads this stream with its own models.
// The server examples are one ordered sequence: the Apple replica test applies them in
// this order and checks the result of every op kind.

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

const failureCard = {
  title: "Run failed",
  body: "Provider overloaded",
  accent: "error",
  at: 1_791_650_004_000,
} as const;

const cardEntry: ConversationEntryView = {
  id: 12,
  kind: "oppi.failure",
  data: { card: failureCard },
  card: { kind: "custom", ...failureCard },
};

/** An attempt a restart interrupted; hidden once its generation retries. */
const partialEntry: ConversationEntryView = {
  id: 13,
  kind: "pi.assistant",
  model: [
    {
      role: "assistant",
      content: [{ type: "text", text: "There are tw" }],
      api: "anthropic-messages",
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage,
      stopReason: "aborted",
      timestamp: 1_791_650_003_500,
    },
  ],
};

const inputCardEntry: ConversationEntryView = {
  id: 21,
  kind: "pi.user",
  card: {
    kind: "custom",
    title: "Background job 3",
    status: "completed",
    body: "npm test",
    fields: [{ label: "Result", value: "Exit 0" }],
    accent: "success",
    output: { kind: "terminal", offset: 0, length: 12, command: "npm test" },
    at: 1_791_650_006_000,
  },
  inputCard: true,
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
  update_queue: {
    type: "update",
    conversationId: 3,
    docs: {
      "pi.inbox": [
        [
          "p",
          ["items"],
          0,
          0,
          [
            { id: 31, mode: "followUp", content: "first" },
            { id: 32, mode: "steer", content: "second" },
            { id: 33, mode: "followUp", content: "third" },
          ],
        ],
        ["m", ["items"], [1, 0, 2]],
        ["d", ["items", 2]],
        ["s", ["items", 1, "content"], "first, edited"],
      ],
    },
  },
  update_partial: {
    type: "update",
    conversationId: 3,
    entries: [partialEntry],
  },
  update_hidden: {
    type: "update",
    conversationId: 3,
    entries: [{ id: 13, kind: "pi.assistant", hidden: true }],
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
  update_input_card: {
    type: "update",
    conversationId: 3,
    entries: [inputCardEntry],
  },
  older: {
    type: "older",
    conversationId: 3,
    entries: [userEntry, toolCallEntry, toolResultEntry],
    hasOlder: false,
  },
} satisfies Record<string, ConversationStreamServerMessage>;

const CONVERSATION_STREAM_CLIENT_MESSAGES = {
  attach: { type: "attach", requestId: "req-attach-1" },
  attach_resume: { type: "attach", conversationId: 3, afterEntryId: 11, requestId: "req-attach-2" },
  attach_by_session: { type: "attach", sessionId: "test-session-1" },
} satisfies Record<string, ConversationStreamAttach>;

const CONVERSATION_STREAM_OLDER_REQUESTS = {
  older: { type: "older", beforeEntryId: 11, limit: 100, requestId: "req-older-1" },
} satisfies Record<string, ConversationStreamOlder>;

export function buildConversationStreamMessages(): Record<string, unknown> {
  return {
    ...Object.fromEntries(
      Object.entries(CONVERSATION_STREAM_SERVER_MESSAGES).map(([key, value]) => [
        `server.${key}`,
        value,
      ]),
    ),
    ...Object.fromEntries(
      Object.entries({
        ...CONVERSATION_STREAM_CLIENT_MESSAGES,
        ...CONVERSATION_STREAM_OLDER_REQUESTS,
      }).map(([key, value]) => [`client.${key}`, value]),
    ),
  };
}

export function serializeConversationStreamFixture(): string {
  return serializeProtocolFixture(
    CONVERSATION_STREAM_FIXTURE_DESCRIPTION,
    buildConversationStreamMessages(),
  );
}
