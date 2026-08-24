import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { AppEventMessage, ServerMessage, Session, SessionSummary } from "../src/types.js";

const FIXTURE_MODULE_DIR = dirname(fileURLToPath(import.meta.url));

export const PROTOCOL_DIR = resolve(FIXTURE_MODULE_DIR, "../../protocol");
export const SERVER_MESSAGES_SNAPSHOT_FILE = resolve(PROTOCOL_DIR, "server-messages.json");
export const APP_EVENT_MESSAGES_SNAPSHOT_FILE = resolve(PROTOCOL_DIR, "app-event-messages.json");

export const SERVER_MESSAGES_FIXTURE_DESCRIPTION =
  "Canonical ServerMessage JSON — updated by npm run protocol:fixtures:update";
export const APP_EVENT_MESSAGES_FIXTURE_DESCRIPTION =
  "Canonical AppEventMessage JSON — updated by npm run protocol:fixtures:update";

// ── Canonical server-message examples ──

const TEST_SESSION_LAUNCH: NonNullable<Session["launch"]> = {
  source: "agent",
  agentId: "agent-reviewer",
  agentVersion: 4,
  agentIcon: { kind: "symbol", name: "checkmark.shield" },
  status: "accepted",
  requestedAt: 1739750399000,
  completedAt: 1739750400000,
};

const TEST_SESSION: Session = {
  id: "test-session-1",
  workspaceId: "ws-1",
  workspaceName: "My Workspace",
  name: "Test Session",
  status: "ready",
  createdAt: 1739750400000, // 2025-02-17T00:00:00Z
  lastActivity: 1739750460000,
  model: "anthropic/claude-sonnet-4-20250514",
  messageCount: 5,
  tokens: { input: 1500, output: 800, cacheRead: 250, cacheWrite: 100 },
  cost: 0.012,
  changeStats: {
    mutatingToolCalls: 3,
    filesChanged: 6,
    changedFiles: ["src/main.ts", "README.md"],
    changedFilesOverflow: 4,
    addedLines: 45,
    removedLines: 12,
  },
  contextTokens: 2300,
  contextWindow: 200000,
  lastMessage: "I've updated the README with the new API docs.",
  thinkingLevel: "high",
  launch: TEST_SESSION_LAUNCH,
  piSessionFile: "/tmp/pi-sessions/abc123.jsonl",
  piSessionFiles: ["/tmp/pi-sessions/abc123.jsonl"],
};

const TEST_SESSION_SUMMARY: SessionSummary = {
  id: TEST_SESSION.id,
  workspaceId: TEST_SESSION.workspaceId,
  workspaceName: TEST_SESSION.workspaceName,
  name: TEST_SESSION.name,
  status: TEST_SESSION.status,
  createdAt: TEST_SESSION.createdAt,
  lastActivity: TEST_SESSION.lastActivity,
  currentTurnStartedAt: TEST_SESSION.currentTurnStartedAt,
  model: TEST_SESSION.model,
  messageCount: TEST_SESSION.messageCount,
  tokens: TEST_SESSION.tokens,
  cost: TEST_SESSION.cost,
  changeStats: TEST_SESSION.changeStats,
  contextTokens: TEST_SESSION.contextTokens,
  contextWindow: TEST_SESSION.contextWindow,
  firstMessage: TEST_SESSION.firstMessage,
  lastMessage: TEST_SESSION.lastMessage,
  thinkingLevel: TEST_SESSION.thinkingLevel,
  agentId: TEST_SESSION.launch?.agentId,
  agentIcon: TEST_SESSION.launch?.agentIcon,
  ephemeral: TEST_SESSION.ephemeral,
};

const TEST_CONTROL_SESSION: Session = {
  ...TEST_SESSION,
  id: "control-session-1",
  workspaceId: undefined,
  workspaceName: undefined,
  name: "Oppi Control",
  control: {
    domain: "skills",
    intent: "revise",
    targetId: "skill-reviewer",
    targetName: "Reviewer Skill",
  },
};

const TEST_CONTROL_SESSION_SUMMARY: SessionSummary = {
  ...TEST_SESSION_SUMMARY,
  id: TEST_CONTROL_SESSION.id,
  workspaceId: undefined,
  workspaceName: undefined,
  name: TEST_CONTROL_SESSION.name,
  control: TEST_CONTROL_SESSION.control,
};

/**
 * The typed canonical set must contain at least one example for every server
 * discriminator. Compatibility-only malformed and future examples are kept
 * below so they cannot weaken this compile-time coverage check.
 */
const TYPED_CANONICAL_SERVER_MESSAGES = {
  // Connection lifecycle
  connected: {
    type: "connected",
    session: TEST_SESSION,
    currentSeq: 42,
    runtimeEpoch: "epoch-test-1",
  },
  stream_connected: {
    type: "stream_connected",
    userName: "my-server",
    serverDictationAvailable: true,
  },
  state: {
    type: "state",
    session: TEST_SESSION,
  },
  session_summary: {
    type: "session_summary",
    summary: TEST_SESSION_SUMMARY,
  },
  state_control: {
    type: "state",
    session: TEST_CONTROL_SESSION,
  },
  session_summary_control: {
    type: "session_summary",
    summary: TEST_CONTROL_SESSION_SUMMARY,
  },
  state_icon_default: {
    type: "state",
    session: {
      ...TEST_SESSION,
      launch: { ...TEST_SESSION_LAUNCH, agentIcon: { kind: "default" } },
    },
  },
  state_icon_emoji: {
    type: "state",
    session: {
      ...TEST_SESSION,
      launch: { ...TEST_SESSION_LAUNCH, agentIcon: { kind: "emoji", value: "🧘" } },
    },
  },
  state_icon_genmoji: {
    type: "state",
    session: {
      ...TEST_SESSION,
      launch: {
        ...TEST_SESSION_LAUNCH,
        agentIcon: {
          kind: "genmoji",
          assetId: `ia_${"A".repeat(43)}`,
          contentDescription: "A smiling fox",
        },
      },
    },
  },
  session_ended: {
    type: "session_ended",
    reason: "Process exited with code 0",
  },
  session_deleted: {
    type: "session_deleted",
    sessionId: "test-session-id",
  },
  stop_requested: {
    type: "stop_requested",
    source: "user",
    reason: "User pressed stop",
  },
  stop_confirmed: {
    type: "stop_confirmed",
    source: "user",
    reason: "Session stopped gracefully",
  },
  stop_failed: {
    type: "stop_failed",
    source: "timeout",
    reason: "Process did not respond to SIGTERM within 10s",
  },
  error: {
    type: "error",
    error: "Model API rate limit exceeded",
    code: "rate_limit",
    fatal: false,
  },

  // Agent lifecycle
  agent_start: { type: "agent_start" },
  agent_end: { type: "agent_end" },
  agent_settled: { type: "agent_settled" },
  message_end: {
    type: "message_end",
    role: "assistant",
    content: "Before\n\nAfter",
    entryId: "entry-assistant-1",
    assistantContent: [
      { kind: "text", content: "Before", contentIndex: 0, id: "entry-assistant-1-text-0" },
      { kind: "thinking", content: "Check", contentIndex: 1, id: "entry-assistant-1-think-1" },
      { kind: "text", content: "After", contentIndex: 2, id: "entry-assistant-1-text-2" },
    ],
  },
  cache_miss: {
    type: "cache_miss",
    id: "cache-miss:1739750460000:anthropic/claude-sonnet-4-20250514",
    message: "Cache miss after 5m idle: 69k tokens re-billed (~$0.79)",
  },

  // Streaming
  text_delta: { type: "text_delta", delta: "Hello, ", contentIndex: 0 },
  thinking_delta: { type: "thinking_delta", delta: "Let me analyze...", contentIndex: 0 },
  audio_stream: {
    type: "audio_stream",
    kind: "audio-stream",
    id: "audio-001",
    event: "chunk",
    mimeType: "audio/pcm; codecs=s16le",
    sampleRate: 24000,
    channels: 1,
    chunkIndex: 0,
    audioBase64: "AAAA",
    playbackBehavior: "playNow",
  },

  // Tool execution
  tool_start: {
    type: "tool_start",
    tool: "bash",
    args: { command: "npm test" },
    toolCallId: "tc-001",
  },
  tool_start_with_segments: {
    type: "tool_start",
    tool: "read",
    args: { path: "src/main.ts", offset: 1, limit: 50 },
    toolCallId: "tc-seg-001",
    callSegments: [
      { text: "read ", style: "bold" },
      { text: "src/main.ts", style: "accent" },
      { text: ":1-50", style: "warning" },
    ],
  },
  tool_update: {
    type: "tool_update",
    tool: "write",
    args: { path: "README.md", content: "hello" },
    toolCallId: "tc-update-001",
  },
  tool_output: {
    type: "tool_output",
    output: "All 42 tests passed",
    isError: false,
    toolCallId: "tc-001",
  },
  tool_output_preview: {
    type: "tool_output",
    output: "/path/to/file-180\n/path/to/file-181\n/path/to/file-182",
    isError: false,
    toolCallId: "tc-preview-001",
    mode: "replace",
    truncated: true,
    totalBytes: 32768,
  },
  tool_end: {
    type: "tool_end",
    tool: "bash",
    toolCallId: "tc-001",
  },
  tool_end_with_details: {
    type: "tool_end",
    tool: "remember",
    toolCallId: "tc-ext-001",
    details: { file: "2026-02-18.md", redacted: false },
    isError: false,
    resultSegments: [
      { text: "✓ Saved", style: "success" },
      { text: " → 2026-02-18.md", style: "muted" },
    ],
  },

  // Message queue
  queue_state: {
    type: "queue_state",
    queue: {
      version: 3,
      steering: [
        {
          id: "queue-steer-1",
          message: "Adjust the approach",
          createdAt: 1739750470000,
        },
      ],
      followUp: [],
    },
  },
  queue_item_started: {
    type: "queue_item_started",
    kind: "follow_up",
    item: {
      id: "queue-follow-1",
      message: "Run the tests next",
      createdAt: 1739750480000,
    },
    queueVersion: 4,
  },

  // Turn delivery
  turn_ack: {
    type: "turn_ack",
    command: "prompt",
    clientTurnId: "turn-abc-123",
    stage: "accepted",
    requestId: "req-001",
    duplicate: false,
  },

  // RPC responses
  command_result_success: {
    type: "command_result",
    command: "get_state",
    requestId: "req-002",
    success: true,
    data: { model: { provider: "anthropic", id: "claude-sonnet-4-0" } },
  },
  command_result_error: {
    type: "command_result",
    command: "set_model",
    requestId: "req-003",
    success: false,
    error: "Model not found",
  },

  // Compaction
  compaction_start: {
    type: "compaction_start",
    reason: "Context window 85% full",
  },
  compaction_end: {
    type: "compaction_end",
    aborted: false,
    willRetry: false,
    summary: "Compacted 15k tokens to 8k tokens",
    tokensBefore: 15000,
  },
  compaction_end_error: {
    type: "compaction_end",
    aborted: false,
    willRetry: false,
    errorMessage: "provider overloaded",
  },

  // Retry
  retry_start: {
    type: "retry_start",
    attempt: 1,
    maxAttempts: 3,
    delayMs: 5000,
    errorMessage: "API overloaded",
  },
  retry_end: {
    type: "retry_end",
    success: true,
    attempt: 2,
  },

  // Extension UI
  extension_ui_request: {
    type: "extension_ui_request",
    id: "ui-001",
    sessionId: "test-session-1",
    method: "select",
    title: "Choose a model",
    options: ["claude-sonnet", "claude-opus"],
    message: "Select the model for this task",
    placeholder: "Select...",
    prefill: "claude-sonnet",
    timeout: 30000,
    extensionScopeId: "npm:review-helper",
    extensionDisplayName: "Review Helper",
  },
  extension_ui_notification: {
    type: "extension_ui_notification",
    method: "setWidget",
    message: "Build completed successfully",
    notifyType: "info",
    statusKey: "build",
    statusText: "✅ Build passed",
    title: "Build status",
    text: "Act on the review findings",
    widgetKey: "review",
    widgetLines: ["Review session active", "Run /end-review when done"],
    widgetPlacement: "aboveEditor",
    extensionScopeId: "npm:review-helper",
    extensionDisplayName: "Review Helper",
    workingIndicator: {
      frames: ["●"],
      intervalMs: 250,
    },
    workingVisible: true,
    hiddenThinkingLabel: "Private reasoning",
    toolsExpanded: true,
  },
  extension_ui_settled: {
    type: "extension_ui_settled",
    id: "ui-001",
    sessionId: "test-session-1",
  },
  git_status: {
    type: "git_status",
    workspaceId: "ws-1",
    status: {
      isGitRepo: true,
      branch: "main",
      headSha: "a1b2c3d",
      ahead: 1,
      behind: 0,
      dirtyCount: 1,
      untrackedCount: 0,
      stagedCount: 1,
      files: [
        { status: "A", path: "src/main.ts", addedLines: 45, removedLines: 0 },
        { status: "M", path: "README.md", addedLines: 3, removedLines: 1 },
      ],
      totalFiles: 2,
      addedLines: 48,
      removedLines: 1,
      stashCount: 0,
      lastCommitMessage: "Initial commit",
      lastCommitDate: "2026-02-20T18:00:00.000Z",
      recentCommits: [
        { sha: "a1b2c3d", message: "Initial commit", date: "2026-02-20T18:00:00.000Z" },
      ],
    },
  },

  // Dictation
  dictation_ready: {
    type: "dictation_ready",
    sttProvider: "openai-compatible",
    sttModel: "gpt-4o-transcribe",
  },
  dictation_result: {
    type: "dictation_result",
    text: "hello wor",
    committedText: "hello ",
    activeText: "wor",
    snap: false,
  },
  dictation_final: {
    type: "dictation_final",
    text: "hello world",
    committedText: "hello world",
    activeText: "",
  },
  dictation_error: {
    type: "dictation_error",
    error: "STT backend unavailable",
    fatal: true,
  },
} satisfies Record<string, ServerMessage>;

type TypedCanonicalServerMessageType =
  (typeof TYPED_CANONICAL_SERVER_MESSAGES)[keyof typeof TYPED_CANONICAL_SERVER_MESSAGES]["type"];
type MissingCanonicalServerMessageType = Exclude<
  ServerMessage["type"],
  TypedCanonicalServerMessageType
>;
type CanonicalServerMessageTypesAreExhaustive = [MissingCanonicalServerMessageType] extends [never]
  ? true
  : never;

const _canonicalServerMessageTypesAreExhaustive: CanonicalServerMessageTypesAreExhaustive = true;

type DuplicateOrderKeys<
  Keys extends readonly string[],
  Seen extends string = never,
> = Keys extends readonly [infer Head extends string, ...infer Tail extends readonly string[]]
  ? Head extends Seen
    ? Head | DuplicateOrderKeys<Tail, Seen>
    : DuplicateOrderKeys<Tail, Seen | Head>
  : never;

type ExactUniqueOrder<Order extends readonly string[], Keys extends string> = [
  Exclude<Keys, Order[number]>,
] extends [never]
  ? [Exclude<Order[number], Keys>] extends [never]
    ? [DuplicateOrderKeys<Order>] extends [never]
      ? true
      : never
    : never
  : never;

function assertFixtureOrder(
  fixtureName: string,
  order: readonly string[],
  availableKeys: readonly string[],
): void {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const key of order) {
    if (seen.has(key)) duplicates.add(key);
    seen.add(key);
  }

  const missing = availableKeys.filter((key) => !seen.has(key));
  const unexpected = order.filter((key) => !availableKeys.includes(key));
  if (duplicates.size === 0 && missing.length === 0 && unexpected.length === 0) return;

  const details = [
    duplicates.size > 0 ? `duplicate keys: ${[...duplicates].join(", ")}` : "",
    missing.length > 0 ? `missing keys: ${missing.join(", ")}` : "",
    unexpected.length > 0 ? `unexpected keys: ${unexpected.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("; ");
  throw new Error(`${fixtureName} fixture order invalid: ${details}`);
}

export function assertNoOverlappingFixtureKeys(
  fixtureName: string,
  typedCanonicalExamples: Record<string, unknown>,
  compatibilityExamples: Record<string, unknown>,
): void {
  const overlappingKeys = Object.keys(typedCanonicalExamples).filter((key) =>
    Object.hasOwn(compatibilityExamples, key),
  );
  if (overlappingKeys.length === 0) return;

  throw new Error(
    `${fixtureName} has compatibility keys that shadow typed canonical keys: ${overlappingKeys.join(", ")}`,
  );
}

// These examples intentionally exercise Apple decoder fallback behavior. They
// are not part of the typed canonical discriminator coverage set above.
const SERVER_MESSAGE_COMPATIBILITY_EXAMPLES = {
  state_icon_malformed: {
    type: "state",
    session: {
      ...TEST_SESSION,
      launch: { ...TEST_SESSION_LAUNCH, agentIcon: { kind: "emoji", value: "not emoji" } },
    },
  },
  state_icon_future: {
    type: "state",
    session: {
      ...TEST_SESSION,
      launch: { ...TEST_SESSION_LAUNCH, agentIcon: { kind: "animated", version: 2 } },
    },
  },
} as const;

assertNoOverlappingFixtureKeys(
  "server-messages.json",
  TYPED_CANONICAL_SERVER_MESSAGES,
  SERVER_MESSAGE_COMPATIBILITY_EXAMPLES,
);

const SERVER_MESSAGE_ORDER = [
  "connected",
  "stream_connected",
  "state",
  "session_summary",
  "state_control",
  "session_summary_control",
  "state_icon_default",
  "state_icon_emoji",
  "state_icon_genmoji",
  "state_icon_malformed",
  "state_icon_future",
  "session_ended",
  "session_deleted",
  "stop_requested",
  "stop_confirmed",
  "stop_failed",
  "error",
  "agent_start",
  "agent_end",
  "agent_settled",
  "message_end",
  "cache_miss",
  "text_delta",
  "thinking_delta",
  "audio_stream",
  "tool_start",
  "tool_start_with_segments",
  "tool_update",
  "tool_output",
  "tool_output_preview",
  "tool_end",
  "tool_end_with_details",
  "queue_state",
  "queue_item_started",
  "turn_ack",
  "command_result_success",
  "command_result_error",
  "compaction_start",
  "compaction_end",
  "compaction_end_error",
  "retry_start",
  "retry_end",
  "extension_ui_request",
  "extension_ui_notification",
  "extension_ui_settled",
  "git_status",
  "dictation_ready",
  "dictation_result",
  "dictation_final",
  "dictation_error",
] as const satisfies readonly (
  | keyof typeof TYPED_CANONICAL_SERVER_MESSAGES
  | keyof typeof SERVER_MESSAGE_COMPATIBILITY_EXAMPLES
)[];

type ServerMessageFixtureKey =
  | Extract<keyof typeof TYPED_CANONICAL_SERVER_MESSAGES, string>
  | Extract<keyof typeof SERVER_MESSAGE_COMPATIBILITY_EXAMPLES, string>;
const _serverMessageOrderIsExact: ExactUniqueOrder<
  typeof SERVER_MESSAGE_ORDER,
  ServerMessageFixtureKey
> = true;

const ALL_SERVER_MESSAGES = {
  ...TYPED_CANONICAL_SERVER_MESSAGES,
  ...SERVER_MESSAGE_COMPATIBILITY_EXAMPLES,
};
assertFixtureOrder("server-messages.json", SERVER_MESSAGE_ORDER, Object.keys(ALL_SERVER_MESSAGES));

export function buildCanonicalServerMessages(): Record<string, unknown> {
  return Object.fromEntries(SERVER_MESSAGE_ORDER.map((key) => [key, ALL_SERVER_MESSAGES[key]]));
}

// ── Canonical app-event examples ──

function makeSession(id = "sess-1", workspaceId = "ws-1"): Session {
  return {
    id,
    workspaceId,
    workspaceName: "Workspace One",
    name: "Test session",
    status: "ready",
    createdAt: 1_791_650_000_000,
    lastActivity: 1_791_650_010_000,
    model: "anthropic/claude-sonnet-4-20250514",
    messageCount: 1,
    tokens: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0 },
    cost: 0.001,
    firstMessage: "Hello",
    launch: {
      source: "agent",
      agentId: "agent-reviewer",
      agentVersion: 4,
      agentIcon: { kind: "symbol", name: "checkmark.shield" },
      status: "accepted",
      requestedAt: 1_791_649_999_000,
    },
  };
}

function makeSessionSummary(session = makeSession()): SessionSummary {
  return {
    id: session.id,
    workspaceId: session.workspaceId,
    workspaceName: session.workspaceName,
    name: session.name,
    status: session.status,
    createdAt: session.createdAt,
    lastActivity: session.lastActivity,
    model: session.model,
    messageCount: 1,
    tokens: session.tokens,
    cost: session.cost,
    firstMessage: session.firstMessage,
    agentId: session.launch?.agentId,
    agentIcon: session.launch?.agentIcon,
    pendingAskCount: 0,
  };
}

const appEventSession = makeSession();
const appEventSummary = makeSessionSummary(appEventSession);
const appEventEmittedAt = 1_791_650_100_000;
const appEventSessionBase = {
  sessionId: appEventSession.id,
  workspaceId: appEventSession.workspaceId,
  emittedAt: appEventEmittedAt,
};
const appEventControlSummary: SessionSummary = {
  ...appEventSummary,
  id: "control-session-1",
  workspaceId: undefined,
  workspaceName: undefined,
  name: "Oppi Control",
  control: {
    domain: "schedules",
    intent: "create",
    targetName: "Nightly review",
  },
};

const APP_EVENT_CANONICAL_EXAMPLES = {
  app_events_connected: {
    type: "app_events_connected",
    serverTime: appEventEmittedAt,
    snapshotRequired: true,
  },
  session_created: { type: "session_created", ...appEventSessionBase, summary: appEventSummary },
  session_imported: { type: "session_imported", ...appEventSessionBase, summary: appEventSummary },
  session_discovered: {
    type: "session_discovered",
    ...appEventSessionBase,
    summary: appEventSummary,
  },
  session_summary: { type: "session_summary", ...appEventSessionBase, summary: appEventSummary },
  session_summary_control: {
    type: "session_summary",
    sessionId: appEventControlSummary.id,
    emittedAt: appEventEmittedAt,
    summary: appEventControlSummary,
  },
  session_summary_icon_default: {
    type: "session_summary",
    ...appEventSessionBase,
    summary: { ...appEventSummary, agentIcon: { kind: "default" } },
  },
  session_summary_icon_emoji: {
    type: "session_summary",
    ...appEventSessionBase,
    summary: { ...appEventSummary, agentIcon: { kind: "emoji", value: "🧘" } },
  },
  session_summary_icon_genmoji: {
    type: "session_summary",
    ...appEventSessionBase,
    summary: {
      ...appEventSummary,
      agentIcon: {
        kind: "genmoji",
        assetId: `ia_${"A".repeat(43)}`,
        contentDescription: "A smiling fox",
      },
    },
  },
  session_deleted: { type: "session_deleted", ...appEventSessionBase },
  session_ended: { type: "session_ended", ...appEventSessionBase, reason: "completed" },
  stop_requested: { type: "stop_requested", ...appEventSessionBase, source: "user" },
  stop_confirmed: { type: "stop_confirmed", ...appEventSessionBase, source: "server" },
  stop_failed: {
    type: "stop_failed",
    ...appEventSessionBase,
    source: "runtime",
    reason: "timeout",
  },
  session_error: {
    type: "session_error",
    ...appEventSessionBase,
    message: "Model API rate limit exceeded",
    code: "rate_limit",
    fatal: false,
  },
  extension_ui_request: {
    type: "extension_ui_request",
    ...appEventSessionBase,
    id: "ui-1",
    method: "ask",
    title: "Approve change",
    message: "Proceed?",
    questions: [
      {
        id: "q1",
        question: "Proceed?",
        options: [{ value: "yes", label: "Yes" }],
      },
    ],
    allowCustom: false,
    timeout: 30_000,
    timeoutAt: appEventEmittedAt + 30_000,
  },
  extension_ui_settled: { type: "extension_ui_settled", ...appEventSessionBase, id: "ui-1" },
  extension_ui_notification: {
    type: "extension_ui_notification",
    ...appEventSessionBase,
    method: "setStatus",
    statusKey: "build",
    statusText: "Build passed",
    notifyType: "info",
    message: "Build completed",
  },
  workspace_git_changed: {
    type: "workspace_git_changed",
    workspaceId: "ws-1",
    sessionId: appEventSession.id,
    emittedAt: appEventEmittedAt,
    reason: "mutation_tool",
  },
} satisfies Record<string, AppEventMessage>;

type TypedCanonicalAppEventMessageType =
  (typeof APP_EVENT_CANONICAL_EXAMPLES)[keyof typeof APP_EVENT_CANONICAL_EXAMPLES]["type"];
type MissingCanonicalAppEventMessageType = Exclude<
  AppEventMessage["type"],
  TypedCanonicalAppEventMessageType
>;
type CanonicalAppEventMessageTypesAreExhaustive = [MissingCanonicalAppEventMessageType] extends [
  never,
]
  ? true
  : never;

const _canonicalAppEventMessageTypesAreExhaustive: CanonicalAppEventMessageTypesAreExhaustive = true;

const APP_EVENT_COMPATIBILITY_EXAMPLES = {
  session_summary_icon_malformed: {
    type: "session_summary",
    ...appEventSessionBase,
    summary: { ...appEventSummary, agentIcon: { kind: "emoji", value: "not emoji" } },
  },
  session_summary_icon_future: {
    type: "session_summary",
    ...appEventSessionBase,
    summary: { ...appEventSummary, agentIcon: { kind: "animated", version: 2 } },
  },
} as const;

assertNoOverlappingFixtureKeys(
  "app-event-messages.json",
  APP_EVENT_CANONICAL_EXAMPLES,
  APP_EVENT_COMPATIBILITY_EXAMPLES,
);

const APP_EVENT_MESSAGE_ORDER = [
  "app_events_connected",
  "session_created",
  "session_imported",
  "session_discovered",
  "session_summary",
  "session_summary_control",
  "session_summary_icon_default",
  "session_summary_icon_emoji",
  "session_summary_icon_genmoji",
  "session_summary_icon_malformed",
  "session_summary_icon_future",
  "session_deleted",
  "session_ended",
  "stop_requested",
  "stop_confirmed",
  "stop_failed",
  "session_error",
  "extension_ui_request",
  "extension_ui_settled",
  "extension_ui_notification",
  "workspace_git_changed",
] as const satisfies readonly (
  | keyof typeof APP_EVENT_CANONICAL_EXAMPLES
  | keyof typeof APP_EVENT_COMPATIBILITY_EXAMPLES
)[];

type AppEventMessageFixtureKey =
  | Extract<keyof typeof APP_EVENT_CANONICAL_EXAMPLES, string>
  | Extract<keyof typeof APP_EVENT_COMPATIBILITY_EXAMPLES, string>;
const _appEventMessageOrderIsExact: ExactUniqueOrder<
  typeof APP_EVENT_MESSAGE_ORDER,
  AppEventMessageFixtureKey
> = true;

const ALL_APP_EVENT_MESSAGES = {
  ...APP_EVENT_CANONICAL_EXAMPLES,
  ...APP_EVENT_COMPATIBILITY_EXAMPLES,
};
assertFixtureOrder(
  "app-event-messages.json",
  APP_EVENT_MESSAGE_ORDER,
  Object.keys(ALL_APP_EVENT_MESSAGES),
);

export function buildCanonicalAppEventMessages(): Record<string, unknown> {
  return Object.fromEntries(
    APP_EVENT_MESSAGE_ORDER.map((key) => [key, ALL_APP_EVENT_MESSAGES[key]]),
  );
}

export function serializeProtocolFixture(
  description: string,
  messages: Record<string, unknown>,
): string {
  return (
    JSON.stringify(
      {
        _meta: {
          description,
          generated: "static",
          messageCount: Object.keys(messages).length,
        },
        messages,
      },
      null,
      2,
    ) + "\n"
  );
}

export function assertProtocolFixtureBytes(
  fixtureName: string,
  expected: string,
  actual: string,
): void {
  if (actual !== expected) {
    const expectedBytes = Buffer.from(expected);
    const actualBytes = Buffer.from(actual);
    const firstDifference = Math.max(expectedBytes.length, actualBytes.length);
    let offset = 0;
    while (offset < firstDifference && expectedBytes[offset] === actualBytes[offset]) {
      offset += 1;
    }
    const describeByte = (value: number | undefined): string =>
      value === undefined ? "EOF" : `0x${value.toString(16).padStart(2, "0")}`;

    throw new Error(
      `Protocol fixture drift detected in ${fixtureName} at byte ${offset} ` +
        `(expected ${describeByte(expectedBytes[offset])}, ` +
        `got ${describeByte(actualBytes[offset])}); ` +
        "run npm run protocol:fixtures:update to regenerate it.",
    );
  }
}
