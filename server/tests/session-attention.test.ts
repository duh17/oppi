import { describe, expect, it } from "vitest";

import {
  pendingAskSnapshots,
  pendingBlockingUIRequestCount,
  type PendingUIRequestProvider,
} from "../src/session-attention.js";
import type { ServerMessage, Session } from "../src/types.js";

function makeSession(id: string, workspaceId = "w1"): Session {
  return {
    id,
    workspaceId,
    status: "busy",
    createdAt: 1,
    lastActivity: 1,
    messageCount: 0,
    tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    cost: 0,
  };
}

function provider(messages: ServerMessage[]): PendingUIRequestProvider {
  const session = makeSession("s1");
  return {
    getActiveSessionIds: () => new Set([session.id]),
    getActiveSession: (sessionId) => (sessionId === session.id ? session : undefined),
    getPendingUIRequestMessages: (sessionId) => (sessionId === session.id ? messages : []),
  };
}

describe("session attention", () => {
  it("derives ask snapshots and blocking count from unified pending UI replay messages", () => {
    const messages: ServerMessage[] = [
      {
        type: "extension_ui_notification",
        method: "setStatus",
        statusKey: "plan",
        statusText: "1/2",
      },
      {
        type: "extension_ui_request",
        id: "ask-1",
        sessionId: "s1",
        method: "ask",
        questions: [
          {
            id: "q1",
            question: "Pick one",
            options: [{ value: "yes", label: "Yes" }],
            multiSelect: false,
          },
        ],
      },
      {
        type: "extension_ui_request",
        id: "select-1",
        sessionId: "s1",
        method: "select",
        title: "Dangerous command",
        options: ["Allow once", "Deny"],
      },
    ];

    const pending = provider(messages);

    expect(pendingBlockingUIRequestCount(pending, "s1")).toBe(2);
    expect(pendingAskSnapshots(pending, "w1")).toEqual([
      {
        id: "ask-1",
        sessionId: "s1",
        workspaceId: "w1",
        questions: [
          {
            id: "q1",
            question: "Pick one",
            options: [{ value: "yes", label: "Yes" }],
            multiSelect: false,
          },
        ],
        allowCustom: true,
      },
    ]);
  });
});
