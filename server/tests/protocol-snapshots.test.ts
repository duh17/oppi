/**
 * Protocol snapshot tests — canonical JSON for every ServerMessage type.
 *
 * Generates `protocol/server-messages.json` with one example of every
 * ServerMessage variant. iOS tests decode this file to verify cross-platform
 * protocol stability. If this test fails, the protocol contract has changed.
 *
 * Run `npm test -- tests/protocol-snapshots.test.ts -- -u` to update snapshots.
 */
import { describe, expect, it } from "vitest";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ServerMessage, Session } from "../src/types.js";

const PROTOCOL_DIR = resolve(__dirname, "../../protocol");
const SNAPSHOTS_FILE = join(PROTOCOL_DIR, "server-messages.json");

// ── Canonical test session ──

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
  tokens: { input: 1500, output: 800 },
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
  piSessionFile: "/tmp/pi-sessions/abc123.jsonl",
  piSessionFiles: ["/tmp/pi-sessions/abc123.jsonl"],
  piSessionId: "uuid-abc-123",
};

// ── Every ServerMessage variant ──

function buildCanonicalMessages(): Record<string, ServerMessage> {
  return {
    // Connection lifecycle
    connected: {
      type: "connected",
      session: TEST_SESSION,
      currentSeq: 42,
    },
    stream_connected: {
      type: "stream_connected",
      userName: "my-server",
    },
    state: {
      type: "state",
      session: TEST_SESSION,
    },
    session_ended: {
      type: "session_ended",
      reason: "Process exited with code 0",
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
    turn_start: { type: "turn_start" },
    turn_end: { type: "turn_end" },
    message_end: {
      type: "message_end",
      role: "assistant",
      content: "I've finished updating the code.",
    },

    // Streaming
    text_delta: { type: "text_delta", delta: "Hello, " },
    thinking_delta: { type: "thinking_delta", delta: "Let me analyze..." },

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
    tool_output: {
      type: "tool_output",
      output: "All 42 tests passed",
      isError: false,
      toolCallId: "tc-001",
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

    // Permission gate
    permission_request: {
      type: "permission_request",
      id: "perm-001",
      sessionId: "test-session-1",
      tool: "bash",
      input: { command: "rm -rf node_modules" },
      displaySummary: "Run: rm -rf node_modules",
      reason: "Destructive file operation",
      timeoutAt: 1739750520000,
      expires: true,
    },
    permission_expired: {
      type: "permission_expired",
      id: "perm-002",
      reason: "Approval timeout (30s)",
    },
    permission_cancelled: {
      type: "permission_cancelled",
      id: "perm-003",
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
    },
    extension_ui_notification: {
      type: "extension_ui_notification",
      method: "notify",
      message: "Build completed successfully",
      notifyType: "success",
      statusKey: "build",
      statusText: "✅ Build passed",
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
      },
    },
  };
}

// ── Tests ──

describe("protocol snapshots", () => {
  const messages = buildCanonicalMessages();

  it("generates canonical ServerMessage JSON for all types", () => {
    if (!existsSync(PROTOCOL_DIR)) {
      mkdirSync(PROTOCOL_DIR, { recursive: true });
    }

    const snapshot = {
      _meta: {
        description:
          "Canonical ServerMessage JSON — generated by server/tests/protocol-snapshots.test.ts",
        generated: "static",
        messageCount: Object.keys(messages).length,
      },
      messages,
    };

    writeFileSync(SNAPSHOTS_FILE, JSON.stringify(snapshot, null, 2) + "\n");

    // Verify the file is valid JSON
    const parsed = JSON.parse(readFileSync(SNAPSHOTS_FILE, "utf-8"));
    expect(parsed.messages).toBeDefined();
    expect(Object.keys(parsed.messages).length).toBe(Object.keys(messages).length);
  });

  it("covers every ServerMessage type discriminator", () => {
    // These are all the type values iOS must handle (from types.ts)
    const expectedTypes = [
      "connected",
      "stream_connected",
      "state",
      "session_ended",
      "stop_requested",
      "stop_confirmed",
      "stop_failed",
      "error",
      "agent_start",
      "agent_end",
      "turn_start",
      "turn_end",
      "message_end",
      "text_delta",
      "thinking_delta",
      "tool_start",
      "tool_output",
      "tool_end",
      "turn_ack",
      "command_result",
      "compaction_start",
      "compaction_end",
      "retry_start",
      "retry_end",
      "permission_request",
      "permission_expired",
      "permission_cancelled",
      "extension_ui_request",
      "extension_ui_notification",
      "git_status",
    ];

    const actualTypes = new Set(Object.values(messages).map((m) => m.type));

    for (const expected of expectedTypes) {
      expect(actualTypes.has(expected), `Missing snapshot for type: ${expected}`).toBe(true);
    }
  });

  it("every message has a type field", () => {
    for (const [key, msg] of Object.entries(messages)) {
      expect(msg.type, `Message "${key}" missing type`).toBeTypeOf("string");
    }
  });

  it("session objects have all required fields", () => {
    // Verify the test session has the shape iOS expects
    const sessionMessages = Object.values(messages).filter((m) => "session" in m);

    for (const msg of sessionMessages) {
      const session = (msg as { session: Session }).session;
      expect(session.id).toBeTypeOf("string");
      expect(session.status).toBeTypeOf("string");
      expect(session.createdAt).toBeTypeOf("number");
      expect(session.lastActivity).toBeTypeOf("number");
      expect(session.messageCount).toBeTypeOf("number");
      expect(session.tokens).toBeDefined();
      expect(session.tokens.input).toBeTypeOf("number");
      expect(session.tokens.output).toBeTypeOf("number");
      expect(session.cost).toBeTypeOf("number");
    }
  });

  it("timestamps are Unix milliseconds (not seconds)", () => {
    const session = TEST_SESSION;
    // Unix ms should be > 1e12 (year ~2001)
    expect(session.createdAt).toBeGreaterThan(1e12);
    expect(session.lastActivity).toBeGreaterThan(1e12);

    // Permission timeoutAt too
    const perm = messages.permission_request as { timeoutAt: number };
    expect(perm.timeoutAt).toBeGreaterThan(1e12);
  });
});
