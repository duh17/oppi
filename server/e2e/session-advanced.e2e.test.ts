/**
 * E2E: Advanced session lifecycle tests
 *
 * Exercises advanced session behaviors beyond basic prompt/response:
 *   1. Concurrent prompts across split session streams (event isolation)
 *   2. Model switching mid-session via set_model
 *   3. Thinking level toggle via set_thinking_level
 *   4. Session deletion while the bound session stream is open
 *   5. Follow-up queue execution during an active turn
 *
 * Requires: Docker, OMLX server on localhost:8400 with a loaded model
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import {
  api,
  openSessionStream,
  closeStream,
  waitForEvent,
  autoApprovePermissions,
  listWorkspaceSessions,
  pairFreshDevice,
} from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

describe("E2E: Advanced Session Lifecycle", { timeout: 600_000 }, () => {
  const lmsReady = () => inject("e2eLmsReady");
  let deviceToken = "";

  beforeAll(async () => {
    if (!lmsReady()) return;

    deviceToken = await pairFreshDevice("e2e-advanced-session");
    expect(deviceToken).toBeTruthy();
  }, 120_000);

  /** Split "provider/modelId" into its two components. */
  function parseModelId(fullModel: string): { provider: string; modelId: string } {
    const slashIdx = fullModel.indexOf("/");
    if (slashIdx < 0) throw new Error(`Invalid model format: ${fullModel}`);
    return {
      provider: fullModel.substring(0, slashIdx),
      modelId: fullModel.substring(slashIdx + 1),
    };
  }

  /** Create a workspace and a single session, returning both IDs. */
  async function createWorkspaceAndSession(
    name: string,
  ): Promise<{ workspaceId: string; sessionId: string }> {
    const model = inject("e2eModel");

    const wsRes = await api("POST", "/workspaces", deviceToken, { name });
    expect(wsRes.status).toBe(201);
    const workspaceId = (wsRes.json!.workspace as Record<string, unknown>).id as string;

    const sessRes = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model,
    });
    expect(sessRes.status).toBe(201);
    const sessionId = (sessRes.json!.session as Record<string, unknown>).id as string;

    return { workspaceId, sessionId };
  }

  // ── 1. Concurrent session prompts ──

  it("concurrent sessions do not cross-contaminate text_delta events", async () => {
    if (!lmsReady()) return;

    const model = inject("e2eModel");

    const wsRes = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-concurrent",
    });
    const workspaceId = (wsRes.json!.workspace as Record<string, unknown>).id as string;

    const sess1Res = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model,
    });
    const session1Id = (sess1Res.json!.session as Record<string, unknown>).id as string;

    const sess2Res = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model,
    });
    const session2Id = (sess2Res.json!.session as Record<string, unknown>).id as string;

    const stream1 = await openSessionStream(deviceToken, workspaceId, session1Id);
    const stream2 = await openSessionStream(deviceToken, workspaceId, session2Id);
    const approver1 = autoApprovePermissions(stream1, session1Id);
    const approver2 = autoApprovePermissions(stream2, session2Id);

    try {
      const startIndex1 = stream1.events.length;
      const startIndex2 = stream2.events.length;

      // Send prompts to both bound streams simultaneously — no await between sends.
      stream1.send({
        type: "prompt",
        sessionId: session1Id,
        message: "Reply with exactly: SESSION_ONE_OK. Do not use any tools.",
        requestId: "req-concurrent-prompt-1",
      });
      stream2.send({
        type: "prompt",
        sessionId: session2Id,
        message: "Reply with exactly: SESSION_TWO_OK. Do not use any tools.",
        requestId: "req-concurrent-prompt-2",
      });

      await waitForEvent(
        stream1,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === session1Id,
        "agent_end session 1",
        { startIndex: startIndex1, timeoutMs: 300_000 },
      );
      await waitForEvent(
        stream2,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === session2Id,
        "agent_end session 2",
        { startIndex: startIndex2, timeoutMs: 300_000 },
      );

      const s1Deltas = stream1.events
        .slice(startIndex1)
        .filter((e) => e.direction === "in" && e.type === "text_delta");
      const s2Deltas = stream2.events
        .slice(startIndex2)
        .filter((e) => e.direction === "in" && e.type === "text_delta");

      expect(s1Deltas.length).toBeGreaterThan(0);
      expect(s2Deltas.length).toBeGreaterThan(0);
      expect(s1Deltas.every((e) => e.sessionId === session1Id)).toBe(true);
      expect(s2Deltas.every((e) => e.sessionId === session2Id)).toBe(true);
      expect(stream1.events.some((e) => e.sessionId === session2Id)).toBe(false);
      expect(stream2.events.some((e) => e.sessionId === session1Id)).toBe(false);
    } finally {
      approver1.stop();
      approver2.stop();
      await closeStream(stream1);
      await closeStream(stream2);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 2. Model switching mid-session ──

  it("switches model mid-session and completes a prompt", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-model-switch");
    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      const { provider, modelId } = parseModelId(inject("e2eModel"));

      // Send set_model command (same model — verifying the command round-trips)
      stream.send({
        type: "set_model",
        sessionId,
        provider,
        modelId,
        requestId: "req-set-model",
      });

      const { event: modelResult } = await waitForEvent(
        stream,
        (e) =>
          e.direction === "in" &&
          (e.type === "command_result" || e.type === "rpc_result") &&
          e.requestId === "req-set-model",
        "set_model result",
        { timeoutMs: 120_000 },
      );
      expect(modelResult.success).toBe(true);

      // Send a prompt after model switch and verify it completes
      const startIndex = stream.events.length;
      stream.send({
        type: "prompt",
        sessionId,
        message: "Reply with exactly: MODEL_SWITCH_OK. Do not use any tools.",
        requestId: "req-post-model-prompt",
      });

      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
        "agent_end after model switch",
        { startIndex, timeoutMs: 300_000 },
      );
    } finally {
      approver.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 3. Thinking level toggle ──

  it("toggles thinking level and completes a prompt without errors", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-thinking-level");
    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      // Set thinking level to "low"
      stream.send({
        type: "set_thinking_level",
        sessionId,
        level: "low",
        requestId: "req-set-thinking",
      });

      const { event: thinkResult } = await waitForEvent(
        stream,
        (e) =>
          e.direction === "in" &&
          (e.type === "command_result" || e.type === "rpc_result") &&
          e.requestId === "req-set-thinking",
        "set_thinking_level result",
        { timeoutMs: 120_000 },
      );
      expect(thinkResult.success).toBe(true);

      // Send a prompt and verify it completes
      const startIndex = stream.events.length;
      stream.send({
        type: "prompt",
        sessionId,
        message: "What is 2 + 2? Reply briefly. Do not use any tools.",
        requestId: "req-thinking-prompt",
      });

      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
        "agent_end after thinking level change",
        { startIndex, timeoutMs: 300_000 },
      );

      // The local OMLX model may or may not produce thinking_delta events at level "low" —
      // we only assert the command didn't cause errors (no fatal error events).
      const fatalErrors = stream.events
        .slice(startIndex)
        .filter((e) => e.direction === "in" && e.type === "error" && e.sessionId === sessionId);
      expect(fatalErrors).toHaveLength(0);
    } finally {
      approver.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 4. Session deletion across split lanes ──

  it("removes a deleted session from the HTTP workspace snapshot", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-session-delete");
    const sessionStream = await openSessionStream(deviceToken, workspaceId, sessionId);

    try {
      const delRes = await api(
        "DELETE",
        `/workspaces/${workspaceId}/sessions/${sessionId}`,
        deviceToken,
      );
      expect(delRes.status).toBe(200);

      const sessions = await listWorkspaceSessions(deviceToken, workspaceId, "active");
      const found = sessions.find((s) => s.id === sessionId);
      expect(found).toBeUndefined();
    } finally {
      await closeStream(sessionStream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 5. Follow-up queue ──

  it("executes follow-up queue items after the current turn", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-follow-up-queue");
    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      const startIndex = stream.events.length;

      // Send initial prompt
      stream.send({
        type: "prompt",
        sessionId,
        message: "Say hello. Do not use any tools.",
        requestId: "req-queue-prompt-1",
      });

      // Wait for agent_start — the agent is now actively processing
      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_start" && e.sessionId === sessionId,
        "agent_start for queue test",
        { startIndex, timeoutMs: 300_000 },
      );

      // Enqueue a follow-up while the agent is busy
      stream.send({
        type: "set_queue",
        sessionId,
        baseVersion: 0,
        steering: [],
        followUp: [{ message: "Now say goodbye. Do not use any tools." }],
        requestId: "req-set-queue",
      });

      // Verify the set_queue command was accepted
      const { event: queueResult } = await waitForEvent(
        stream,
        (e) =>
          e.direction === "in" &&
          (e.type === "command_result" || e.type === "rpc_result") &&
          e.requestId === "req-set-queue",
        "set_queue result",
        { timeoutMs: 120_000 },
      );
      expect(queueResult.success).toBe(true);

      // Follow-up queue items may run within the current agent loop and emit
      // a single final agent_end after all queued work is complete.
      const { index: queueItemStartIdx } = await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "queue_item_started" && e.sessionId === sessionId,
        "queue_item_started (follow-up)",
        { startIndex, timeoutMs: 300_000 },
      );

      // Verify queue bookkeeping events appeared
      const queueEvents = stream.events
        .slice(startIndex)
        .filter(
          (e) =>
            e.direction === "in" &&
            e.sessionId === sessionId &&
            (e.type === "queue_state" || e.type === "queue_item_started"),
        );
      expect(queueEvents.length).toBeGreaterThan(0);

      // Confirm the queued follow-up message was consumed
      await waitForEvent(
        stream,
        (e) =>
          e.direction === "in" &&
          e.type === "message_end" &&
          e.sessionId === sessionId &&
          typeof e.content === "string" &&
          e.content.includes("Now say goodbye"),
        "queued follow-up message_end",
        { startIndex: queueItemStartIdx, timeoutMs: 300_000 },
      );

      // Agent turn should eventually finish after processing queued follow-up
      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
        "agent_end after follow-up",
        { startIndex: queueItemStartIdx, timeoutMs: 300_000 },
      );
    } finally {
      approver.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });
});
