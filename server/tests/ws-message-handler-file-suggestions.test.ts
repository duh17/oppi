import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import type { ClientMessage, ServerMessage, Session, Workspace } from "../src/types.js";
import { WsMessageHandler, type WsMessageHandlerDeps } from "../src/ws-message-handler.js";

interface HandlerHarness {
  handler: WsMessageHandler;
  session: Session;
  sent: ServerMessage[];
}

function makeSession(id = "s1"): Session {
  const now = Date.now();
  return {
    id,
    workspaceId: "w1",
    status: "ready",
    createdAt: now,
    lastActivity: now,
    messageCount: 0,
    tokens: { input: 0, output: 0 },
    cost: 0,
  };
}

function makeWorkspace(hostMount: string): Workspace {
  const now = Date.now();
  return {
    id: "w1",
    name: "workspace",
    hostMount,
    skills: [],
    createdAt: now,
    updatedAt: now,
  };
}

function makeHarness(resolveWorkspaceForSession?: (session: Session) => Workspace | undefined): HandlerHarness {
  const session = makeSession();
  const sent: ServerMessage[] = [];

  const deps: WsMessageHandlerDeps = {
    sessions: {
      sendPrompt: vi.fn(async () => {}),
      sendSteer: vi.fn(async () => {}),
      sendFollowUp: vi.fn(async () => {}),
      getMessageQueue: vi.fn(() => ({ version: 0, steering: [], followUp: [] })),
      setMessageQueue: vi.fn(async () => ({ version: 0, steering: [], followUp: [] })),
      sendAbort: vi.fn(async () => {}),
      stopSession: vi.fn(async () => {}),
      getActiveSession: vi.fn(() => undefined as Session | undefined),
      respondToUIRequest: vi.fn(() => true),
      forwardClientCommand: vi.fn(async () => {}),
    },
    gate: {
      resolveDecision: vi.fn(() => true),
    },
    ensureSessionContextWindow: vi.fn((value: Session) => value),
    resolveWorkspaceForSession,
  };

  const handler = new WsMessageHandler(deps);
  return { handler, session, sent };
}

function dispatch(harness: HandlerHarness, msg: ClientMessage): Promise<void> {
  return harness.handler.handleClientMessage(harness.session, msg, (outbound) => {
    harness.sent.push(outbound);
  });
}

const tempDirs: string[] = [];

function makeTempDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "oppi-ws-file-suggestions-"));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("WsMessageHandler get_file_suggestions", () => {
  it("returns command_result success with suggestion payload", async () => {
    const root = makeTempDir();
    mkdirSync(join(root, "src"), { recursive: true });
    writeFileSync(join(root, "src", "ChatView.swift"), "struct ChatView {}\n");

    const harness = makeHarness(() => makeWorkspace(root));

    await dispatch(harness, {
      type: "get_file_suggestions",
      query: "Chat",
      requestId: "req-success",
    });

    expect(harness.sent).toHaveLength(1);
    const result = harness.sent[0];
    if (result.type !== "command_result") {
      throw new Error(`Expected command_result, got ${result.type}`);
    }

    expect(result.command).toBe("get_file_suggestions");
    expect(result.requestId).toBe("req-success");
    expect(result.success).toBe(true);

    const payload = result.data as
      | {
          items?: Array<{ path?: string }>;
        }
      | undefined;
    const paths = payload?.items?.map((item) => item.path) ?? [];
    expect(paths).toContain("src/ChatView.swift");
  });

  it("returns command_result failure when workspace is unavailable", async () => {
    const harness = makeHarness(() => undefined);

    await dispatch(harness, {
      type: "get_file_suggestions",
      query: "Chat",
      requestId: "req-no-workspace",
    });

    expect(harness.sent).toEqual([
      {
        type: "command_result",
        command: "get_file_suggestions",
        requestId: "req-no-workspace",
        success: false,
        error: "workspace_unavailable",
      },
    ]);
  });

  it("returns command_result failure when suggestion resolution throws", async () => {
    const root = makeTempDir();
    const workspace = makeWorkspace(root);
    const malformedWorkspace: Workspace = {
      ...workspace,
      allowedPaths: [
        {
          path: null as unknown as string,
          access: "read",
        },
      ],
    };

    const harness = makeHarness(() => malformedWorkspace);

    await dispatch(harness, {
      type: "get_file_suggestions",
      query: "Chat",
      requestId: "req-failure",
    });

    expect(harness.sent).toHaveLength(1);
    const result = harness.sent[0];
    if (result.type !== "command_result") {
      throw new Error(`Expected command_result, got ${result.type}`);
    }

    expect(result.command).toBe("get_file_suggestions");
    expect(result.requestId).toBe("req-failure");
    expect(result.success).toBe(false);
    expect(typeof result.error).toBe("string");
    expect((result.error ?? "").length).toBeGreaterThan(0);
  });

  it("handles missing requestId with command_result response", async () => {
    const root = makeTempDir();
    mkdirSync(join(root, "src"), { recursive: true });
    writeFileSync(join(root, "src", "ChatView.swift"), "struct ChatView {}\n");

    const harness = makeHarness(() => makeWorkspace(root));

    await dispatch(harness, {
      type: "get_file_suggestions",
      query: "Chat",
    });

    expect(harness.sent).toHaveLength(1);
    const result = harness.sent[0];
    if (result.type !== "command_result") {
      throw new Error(`Expected command_result, got ${result.type}`);
    }

    expect(result.command).toBe("get_file_suggestions");
    expect(result.requestId).toBeUndefined();
    expect(result.success).toBe(true);
  });
});
