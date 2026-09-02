/**
 * E2E: Quick session send (smoke test)
 *
 * Minimal end-to-end smoke test that exercises the happy path:
 *   1. Pair a device
 *   2. Create a workspace and session
 *   3. Open the split session WebSocket
 *   4. Send a simple prompt
 *   5. Verify assistant response contains E2E_QUICK_SESSION_SEND_OK
 *
 * Requires: Docker (or native), OMLX server on localhost:8400 with a loaded model
 */

import { describe, it, expect, beforeAll, afterAll, inject } from "vitest";
import {
  api,
  openSessionStream,
  closeStream,
  sendPromptAndWait,
  autoApprovePermissions,
  pairFreshDevice,
} from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

describe("E2E: Quick Session Send", { timeout: 300_000 }, () => {
  const lmsReady = () => inject("e2eLmsReady");
  let deviceToken = "";
  let workspaceId = "";
  let sessionId = "";

  beforeAll(async () => {
    if (!lmsReady()) return;

    deviceToken = await pairFreshDevice("e2e-quick-send");
    expect(deviceToken).toBeTruthy();

    // Create workspace
    const wsRes = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-quick-send-workspace",
    });

    expect(wsRes.status).toBe(201);
    workspaceId = (wsRes.json!.workspace as Record<string, unknown>).id as string;
    expect(workspaceId).toBeTruthy();

    // Create session
    const sessionRes = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model: inject("e2eModel"),
    });

    expect(sessionRes.status).toBe(201);
    sessionId = (sessionRes.json!.session as Record<string, unknown>).id as string;
    expect(sessionId).toBeTruthy();
  }, 120_000);

  afterAll(async () => {
    if (!lmsReady() || !deviceToken || !workspaceId) return;

    const res = await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    expect(res.status).toBe(200);

    const list = await api("GET", "/workspaces", deviceToken);
    const workspaces = list.json?.workspaces as { id: string }[];
    const found = workspaces.find((w) => w.id === workspaceId);
    expect(found).toBeUndefined();
  });

  it("sends a prompt and receives E2E_QUICK_SESSION_SEND_OK in the response", async () => {
    if (!lmsReady()) return;

    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      const startIndex = stream.events.length;

      await sendPromptAndWait(
        stream,
        sessionId,
        "Reply with exactly: E2E_QUICK_SESSION_SEND_OK. Do not use any tools or add extra text.",
        "req-e2e-quick-send",
        { timeoutMs: 300_000 },
      );

      // Collect assistant text from text_delta and message_end events
      const textEvents = stream.events
        .slice(startIndex)
        .filter(
          (e) =>
            e.direction === "in" &&
            e.sessionId === sessionId &&
            (e.type === "text_delta" || e.type === "message_end"),
        );

      expect(textEvents.length).toBeGreaterThan(0);

      let assistantText = "";
      for (const e of textEvents) {
        if (e.type === "text_delta" && e.delta) assistantText += e.delta;
        if (e.type === "message_end" && e.content) assistantText += e.content;
      }

      expect(assistantText.trim().length).toBeGreaterThan(0);
      expect(assistantText).toContain("E2E_QUICK_SESSION_SEND_OK");
    } finally {
      approver.stop();
      await closeStream(stream);
    }
  });
});
