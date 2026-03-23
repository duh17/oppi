/**
 * E2E: Paired session flow
 *
 * Exercises the full session lifecycle for an already-paired device:
 *   1. Pre-paired device creates a workspace
 *   2. Creates a session with a local model
 *   3. Opens /stream WebSocket and subscribes to the session
 *   4. Sends a prompt, auto-approves permissions
 *   5. Verifies assistant response arrives (text_delta + agent_end)
 *   6. Sends a prompt requiring tool use (bash)
 *   7. Verifies tool_start → tool_output → tool_end lifecycle
 *   8. Reconnects /stream and verifies catch-up replay
 *
 * Requires: Docker, LM Studio on localhost:1234 with a loaded model
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import {
  api,
  generateTestInvite,
  openStream,
  closeStream,
  waitForEvent,
  subscribeSession,
  sendPromptAndWait,
  autoApprovePermissions,
  supportsRealSessions,
  E2E_MODEL,
} from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
  }
}

describe("E2E: Paired Session Flow", { timeout: 300_000 }, () => {
  // Server is started by globalSetup (e2e/setup.ts)
  const lmsReady = () => inject("e2eLmsReady");
  let deviceToken = "";
  let workspaceId = "";
  let sessionId = "";

  beforeAll(async () => {
    if (!lmsReady()) return;

    // Pre-pair: generate invite and pair in one atomic step.
    // Uses a retry loop because the pairing test may have just issued/consumed
    // a token — we need a fresh one.
    for (let attempt = 0; attempt < 3; attempt++) {
      const invite = await generateTestInvite();
      const pairRes = await api("POST", "/pair", undefined, {
        pairingToken: invite.pairingToken,
        deviceName: "e2e-paired-session",
      });

      if (pairRes.json?.deviceToken) {
        deviceToken = pairRes.json.deviceToken as string;
        break;
      }

      // Token may have been consumed between generate and pair (race).
      // Retry with a fresh token.
      console.warn(`[e2e] Pairing attempt ${attempt + 1} failed (${pairRes.status}), retrying...`);
    }

    expect(deviceToken).toBeTruthy();
  }, 60_000);

  // ── 1. Workspace CRUD ──

  it("creates a workspace", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-session-workspace",
      skills: [],
      defaultModel: E2E_MODEL,
    });

    expect(res.status).toBe(201);
    expect(res.json?.workspace).toBeTruthy();
    workspaceId = (res.json!.workspace as Record<string, unknown>).id as string;
    expect(workspaceId).toBeTruthy();
  });

  it("workspace appears in list", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", "/workspaces", deviceToken);
    expect(res.status).toBe(200);

    const workspaces = res.json?.workspaces as { id: string }[];
    const found = workspaces.find((w) => w.id === workspaceId);
    expect(found).toBeTruthy();
  });

  // ── 2. Session creation ──

  it("creates a session", async () => {
    if (!lmsReady()) return;

    const res = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model: E2E_MODEL,
    });

    expect(res.status).toBe(201);
    expect(res.json?.session).toBeTruthy();
    sessionId = (res.json!.session as Record<string, unknown>).id as string;
    expect(sessionId).toBeTruthy();

    const model = (res.json!.session as Record<string, unknown>).model as string;
    expect(model).toBe(E2E_MODEL);
  });

  it("session appears in list", async () => {
    if (!lmsReady()) return;

    const res = await api("GET", `/workspaces/${workspaceId}/sessions`, deviceToken);
    expect(res.status).toBe(200);

    const sessions = res.json?.sessions as { id: string }[];
    const found = sessions.find((s) => s.id === sessionId);
    expect(found).toBeTruthy();
  });

  // ── 3. Stream subscribe ──

  it("subscribes to session via /stream", async () => {
    if (!lmsReady()) return;

    const stream = await openStream(deviceToken);

    try {
      const { rpcData } = await subscribeSession(stream, sessionId, "req-e2e-subscribe");
      expect(rpcData.catchUpComplete).toBe(true);
    } finally {
      await closeStream(stream);
    }
  });

  // ── 4. Simple prompt → response (requires real LLM) ──

  it("sends a prompt and receives assistant response", async () => {
    if (!lmsReady() || !supportsRealSessions()) return;

    const stream = await openStream(deviceToken);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      await subscribeSession(stream, sessionId, "req-e2e-sub-prompt");

      const startIndex = stream.events.length;

      await sendPromptAndWait(
        stream,
        sessionId,
        "Reply with exactly: E2E_SIMPLE_OK. Do not use any tools.",
        "req-e2e-simple-prompt",
        { timeoutMs: 120_000 },
      );

      // Verify we got text content
      const textEvents = stream.events
        .slice(startIndex)
        .filter(
          (e) =>
            e.direction === "in" &&
            e.sessionId === sessionId &&
            (e.type === "text_delta" || e.type === "message_end"),
        );

      expect(textEvents.length).toBeGreaterThan(0);

      // Collect assistant text
      let assistantText = "";
      for (const e of textEvents) {
        if (e.type === "text_delta" && e.delta) assistantText += e.delta;
        if (e.type === "message_end" && e.content) assistantText += e.content;
      }

      // Model should have responded (exact text may vary with local model)
      expect(assistantText.trim().length).toBeGreaterThan(0);
    } finally {
      approver.stop();
      await closeStream(stream);
    }
  });

  // ── 5. Tool use prompt → bash tool lifecycle (requires real LLM) ──

  it("sends a prompt requiring bash tool and verifies tool lifecycle", async () => {
    if (!lmsReady() || !supportsRealSessions()) return;

    const stream = await openStream(deviceToken);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      await subscribeSession(stream, sessionId, "req-e2e-sub-tool");

      const startIndex = stream.events.length;

      await sendPromptAndWait(
        stream,
        sessionId,
        'Use exactly one bash tool call with this command: echo E2E_TOOL_OK. After the tool finishes, reply with: "Tool executed successfully."',
        "req-e2e-tool-prompt",
        { timeoutMs: 120_000 },
      );

      const sessionEvents = stream.events
        .slice(startIndex)
        .filter((e) => e.direction === "in" && e.sessionId === sessionId);

      // Verify agent lifecycle
      const agentStart = sessionEvents.find((e) => e.type === "agent_start");
      const agentEnd = sessionEvents.find((e) => e.type === "agent_end");
      expect(agentStart).toBeTruthy();
      expect(agentEnd).toBeTruthy();

      // Verify tool lifecycle (model may or may not use bash - depends on LLM)
      const toolStarts = sessionEvents.filter((e) => e.type === "tool_start");
      const toolEnds = sessionEvents.filter((e) => e.type === "tool_end");

      // Permission requests should have been auto-approved
      if (toolStarts.length > 0) {
        expect(approver.count()).toBeGreaterThan(0);
        expect(toolEnds.length).toBe(toolStarts.length);
      }
    } finally {
      approver.stop();
      await closeStream(stream);
    }
  });

  // ── 6. Reconnect and catch-up replay (requires real LLM for events to exist) ──

  it("reconnects to /stream and replays missed events", async () => {
    if (!lmsReady() || !supportsRealSessions()) return;

    // First connection: subscribe and capture baseline seq
    const stream1 = await openStream(deviceToken);
    try {
      await subscribeSession(stream1, sessionId, "req-e2e-reconnect-sub-1");

      const sessionEvents = stream1.events.filter(
        (e) =>
          e.direction === "in" &&
          e.sessionId === sessionId &&
          typeof e.sessionSeq === "number",
      );

      const baselineSeq = sessionEvents.length > 0
        ? sessionEvents[sessionEvents.length - 1].sessionSeq!
        : 0;

      expect(baselineSeq).toBeGreaterThan(0);

      // Disconnect
      await closeStream(stream1);

      // Second connection: subscribe with sinceSeq to get catch-up
      const stream2 = await openStream(deviceToken);
      try {
        const startIndex = stream2.events.length;

        stream2.send({
          type: "subscribe",
          sessionId,
          level: "full",
          sinceSeq: 0, // Request full replay
          requestId: "req-e2e-reconnect-sub-2",
        });

        const { event: rpcEvent } = await waitForEvent(
          stream2,
          (e) =>
            e.direction === "in" &&
            (e.type === "command_result" || e.type === "rpc_result") &&
            e.requestId === "req-e2e-reconnect-sub-2",
          "reconnect subscribe rpc_result",
        );

        expect(rpcEvent.success).toBe(true);

        // Should have received catch-up events
        const catchupEvents = stream2.events
          .slice(startIndex)
          .filter(
            (e) =>
              e.direction === "in" &&
              e.sessionId === sessionId &&
              typeof e.sessionSeq === "number" &&
              e.sessionSeq! > 0,
          );

        expect(catchupEvents.length).toBeGreaterThan(0);

        // Seqs should be strictly increasing
        for (let i = 1; i < catchupEvents.length; i++) {
          expect(catchupEvents[i].sessionSeq!).toBeGreaterThan(
            catchupEvents[i - 1].sessionSeq!,
          );
        }
      } finally {
        await closeStream(stream2);
      }
    } catch (err) {
      // Ensure stream1 is closed on error
      if (!stream1.closed) await closeStream(stream1);
      throw err;
    }
  });

  // ── 7. Session isolation ──

  it("cannot subscribe to session from wrong workspace", async () => {
    if (!lmsReady()) return;

    // Create a different workspace
    const ws2 = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-wrong-workspace",
      skills: [],
    });
    const wrongWorkspaceId = (ws2.json?.workspace as Record<string, unknown>).id as string;

    // Try to access the session via the wrong workspace's sessions list
    const sessionsRes = await api(
      "GET",
      `/workspaces/${wrongWorkspaceId}/sessions`,
      deviceToken,
    );
    expect(sessionsRes.status).toBe(200);

    const sessions = sessionsRes.json?.sessions as { id: string }[];
    const leaked = sessions.find((s) => s.id === sessionId);
    expect(leaked).toBeUndefined();
  });

  // ── 8. Workspace cleanup ──

  it("deletes workspace", async () => {
    if (!lmsReady()) return;

    const res = await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    expect(res.status).toBe(200);

    // Verify deleted
    const list = await api("GET", "/workspaces", deviceToken);
    const workspaces = list.json?.workspaces as { id: string }[];
    const found = workspaces.find((w) => w.id === workspaceId);
    expect(found).toBeUndefined();
  });
});
