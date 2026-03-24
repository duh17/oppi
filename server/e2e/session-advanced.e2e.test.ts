/**
 * E2E: Advanced session lifecycle tests
 *
 * Exercises advanced session behaviors beyond basic prompt/response:
 *   1. Concurrent prompts across sessions (event isolation)
 *   2. Model switching mid-session via set_model
 *   3. Thinking level toggle via set_thinking_level
 *   4. Session deletion while stream is subscribed
 *   5. Follow-up queue execution during an active turn
 *
 * Requires: Docker, MLX server on localhost:9847 with a loaded model
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import {
  api,
  generateTestInvite,
  openStream,
  closeStream,
  waitForEvent,
  subscribeSession,
  autoApprovePermissions,
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

    for (let attempt = 0; attempt < 3; attempt++) {
      const invite = await generateTestInvite();
      const pairRes = await api("POST", "/pair", undefined, {
        pairingToken: invite.pairingToken,
        deviceName: "e2e-advanced-session",
      });

      if (pairRes.json?.deviceToken) {
        deviceToken = pairRes.json.deviceToken as string;
        break;
      }
      console.warn(`[e2e] Pairing attempt ${attempt + 1} failed (${pairRes.status}), retrying...`);
    }
    expect(deviceToken).toBeTruthy();
  }, 60_000);

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

    const wsRes = await api("POST", "/workspaces", deviceToken, {
      name,
      skills: [],
      defaultModel: model,
    });
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
      skills: [],
      defaultModel: model,
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

    const stream = await openStream(deviceToken);
    const approver1 = autoApprovePermissions(stream, session1Id);
    const approver2 = autoApprovePermissions(stream, session2Id);

    try {
      await subscribeSession(stream, session1Id, "req-sub-concurrent-1");
      await subscribeSession(stream, session2Id, "req-sub-concurrent-2");

      const startIndex = stream.events.length;

      // Send prompts to both simultaneously — no await between sends
      stream.send({
        type: "prompt",
        sessionId: session1Id,
        message: "Reply with exactly: SESSION_ONE_OK. Do not use any tools.",
        requestId: "req-concurrent-prompt-1",
      });
      stream.send({
        type: "prompt",
        sessionId: session2Id,
        message: "Reply with exactly: SESSION_TWO_OK. Do not use any tools.",
        requestId: "req-concurrent-prompt-2",
      });

      // Wait for both agent_end events
      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === session1Id,
        "agent_end session 1",
        { startIndex, timeoutMs: 300_000 },
      );
      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === session2Id,
        "agent_end session 2",
        { startIndex, timeoutMs: 300_000 },
      );

      // Collect text_delta events per session
      const allTextDeltas = stream.events
        .slice(startIndex)
        .filter((e) => e.direction === "in" && e.type === "text_delta");

      const s1Deltas = allTextDeltas.filter((e) => e.sessionId === session1Id);
      const s2Deltas = allTextDeltas.filter((e) => e.sessionId === session2Id);

      expect(s1Deltas.length).toBeGreaterThan(0);
      expect(s2Deltas.length).toBeGreaterThan(0);

      // Every text_delta must belong to exactly one of the two sessions
      for (const e of allTextDeltas) {
        expect([session1Id, session2Id]).toContain(e.sessionId);
      }
    } finally {
      approver1.stop();
      approver2.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 2. Model switching mid-session ──

  it("switches model mid-session and completes a prompt", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-model-switch");
    const stream = await openStream(deviceToken);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      await subscribeSession(stream, sessionId, "req-sub-model-switch");

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
        { timeoutMs: 30_000 },
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
    const stream = await openStream(deviceToken);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      await subscribeSession(stream, sessionId, "req-sub-thinking");

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
        { timeoutMs: 30_000 },
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

      // The MLX model may or may not produce thinking_delta events at level "low" —
      // we only assert the command didn't cause errors (no fatal error events).
      const fatalErrors = stream.events
        .slice(startIndex)
        .filter(
          (e) =>
            e.direction === "in" &&
            e.type === "error" &&
            e.sessionId === sessionId,
        );
      expect(fatalErrors).toHaveLength(0);
    } finally {
      approver.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 4. Session deletion while subscribed ──

  it("receives deletion event when session is deleted via REST", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-session-delete");
    const stream = await openStream(deviceToken);

    try {
      await subscribeSession(stream, sessionId, "req-sub-delete");
      const startIndex = stream.events.length;

      // Delete the session via REST API
      const delRes = await api(
        "DELETE",
        `/workspaces/${workspaceId}/sessions/${sessionId}`,
        deviceToken,
      );
      expect(delRes.status).toBe(200);

      // Verify a session_deleted or session_ended event arrives on the stream
      await waitForEvent(
        stream,
        (e) =>
          e.direction === "in" &&
          e.sessionId === sessionId &&
          (e.type === "session_deleted" || e.type === "session_ended"),
        "session deletion event",
        { startIndex, timeoutMs: 30_000 },
      );

      // Verify the session no longer appears in the sessions list
      const listRes = await api(
        "GET",
        `/workspaces/${workspaceId}/sessions`,
        deviceToken,
      );
      expect(listRes.status).toBe(200);

      const sessions = (listRes.json?.sessions ?? []) as { id: string }[];
      const found = sessions.find((s) => s.id === sessionId);
      expect(found).toBeUndefined();
    } finally {
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });

  // ── 5. Follow-up queue ──

  it("executes follow-up queue items after the current turn", async () => {
    if (!lmsReady()) return;

    const { workspaceId, sessionId } = await createWorkspaceAndSession("e2e-follow-up-queue");
    const stream = await openStream(deviceToken);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      await subscribeSession(stream, sessionId, "req-sub-queue");
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
        { timeoutMs: 30_000 },
      );
      expect(queueResult.success).toBe(true);

      // Wait for first agent_end (initial prompt completes)
      const { index: firstEndIdx } = await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
        "first agent_end (queue test)",
        { startIndex, timeoutMs: 300_000 },
      );

      // Verify queue-related events appeared (queue_state or queue_item_started)
      const queueEvents = stream.events
        .slice(startIndex)
        .filter(
          (e) =>
            e.direction === "in" &&
            e.sessionId === sessionId &&
            (e.type === "queue_state" || e.type === "queue_item_started"),
        );
      expect(queueEvents.length).toBeGreaterThan(0);

      // Wait for second agent_end — the follow-up should execute automatically
      await waitForEvent(
        stream,
        (e) => e.direction === "in" && e.type === "agent_end" && e.sessionId === sessionId,
        "second agent_end (follow-up)",
        { startIndex: firstEndIdx + 1, timeoutMs: 300_000 },
      );
    } finally {
      approver.stop();
      await closeStream(stream);
      await api("DELETE", `/workspaces/${workspaceId}`, deviceToken);
    }
  });
});
