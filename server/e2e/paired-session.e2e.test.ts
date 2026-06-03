/**
 * E2E: Paired session flow
 *
 * Exercises the full session lifecycle for an already-paired device:
 *   1. Pre-paired device creates a workspace
 *   2. Creates a session with a local model
 *   3. Opens the split session WebSocket
 *   4. Sends a prompt, auto-approves permissions on the session stream
 *   5. Verifies assistant response arrives (text_delta + agent_end)
 *   6. Sends a prompt requiring tool use (bash)
 *   7. Verifies tool_start → tool_output → tool_end lifecycle
 *   8. Reconnects the split session stream and receives fresh state
 *
 * Requires: Docker, OMLX server on localhost:8400 with a loaded model
 */

import { describe, it, expect, beforeAll, inject } from "vitest";
import {
  api,
  generateTestInvite,
  openSessionStream,
  closeStream,
  sendPromptAndWait,
  autoApprovePermissions,
  restartServerPreservingData,
  sessionStreamURL,
  isSecureTransport,
  listWorkspaceSessions,
} from "./harness.js";

declare module "vitest" {
  export interface ProvidedContext {
    e2eLmsReady: boolean;
    e2eModel: string;
  }
}

describe("E2E: Paired Session Flow", { timeout: 600_000 }, () => {
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
      defaultModel: inject("e2eModel"),
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
      model: inject("e2eModel"),
    });

    expect(res.status).toBe(201);
    expect(res.json?.session).toBeTruthy();
    sessionId = (res.json!.session as Record<string, unknown>).id as string;
    expect(sessionId).toBeTruthy();

    const model = (res.json!.session as Record<string, unknown>).model as string;
    expect(model).toBe(inject("e2eModel"));
  });

  it("session appears in list", async () => {
    if (!lmsReady()) return;

    const sessions = await listWorkspaceSessions(deviceToken, workspaceId);
    const found = sessions.find((s) => s.id === sessionId);
    expect(found).toBeTruthy();
  });

  it("keeps an already-paired device token valid across server restart", async () => {
    if (!lmsReady()) return;

    await restartServerPreservingData();

    const me = await api("GET", "/me", deviceToken);
    expect(me.status).toBe(200);

    const workspaces = await api("GET", "/workspaces", deviceToken);
    expect(workspaces.status).toBe(200);
    const workspaceList = workspaces.json?.workspaces as { id: string }[];
    expect(workspaceList.some((workspace) => workspace.id === workspaceId)).toBe(true);

    const session = await api(
      "GET",
      `/workspaces/${workspaceId}/sessions/${sessionId}`,
      deviceToken,
    );
    expect(session.status).toBe(200);

    const sessionStream = await openSessionStream(deviceToken, workspaceId, sessionId);
    await closeStream(sessionStream);
  }, 120_000);

  // ── 3. HTTP workspace list + split session lane ──

  it("uses HTTP session snapshots and opens the bound session stream", async () => {
    if (!lmsReady()) return;

    const projected = await api("POST", `/workspaces/${workspaceId}/sessions`, deviceToken, {
      model: inject("e2eModel"),
    });
    expect(projected.status).toBe(201);
    const projectedSessionId = (projected.json!.session as Record<string, unknown>).id as string;

    const sessions = await listWorkspaceSessions(deviceToken, workspaceId);
    expect(sessions.some((session) => session.id === projectedSessionId)).toBe(true);

    const sessionStream = await openSessionStream(deviceToken, workspaceId, sessionId);

    try {
      const connected = sessionStream.events.find(
        (e) => e.type === "connected" && e.sessionId === sessionId,
      );
      expect(connected).toBeTruthy();
    } finally {
      await closeStream(sessionStream);
    }
  });

  // ── 4. Simple prompt → response (requires real LLM) ──

  it("sends a prompt and receives assistant response", async () => {
    if (!lmsReady()) return;

    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      const startIndex = stream.events.length;

      await sendPromptAndWait(
        stream,
        sessionId,
        "Reply with exactly: E2E_SIMPLE_OK. Do not use any tools.",
        "req-e2e-simple-prompt",
        { timeoutMs: 300_000 },
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

  // ── 5. Transport/auth negative paths ──

  it("rejects unauthenticated API and missing-session stream requests", async () => {
    if (!lmsReady()) return;

    const unauthenticated = await api("GET", "/workspaces");
    expect(unauthenticated.status).toBe(401);

    const invalidToken = await api("GET", "/workspaces", "not-a-real-device-token");
    expect(invalidToken.status).toBe(401);

    const WebSocket = (await import("ws")).default;
    const result = await new Promise<{ closeCode: number | null }>((resolve) => {
      const ws = new WebSocket(sessionStreamURL(workspaceId, "missing-session-id"), {
        headers: { Authorization: `Bearer ${deviceToken}` },
        ...(isSecureTransport() ? { rejectUnauthorized: false } : {}),
      });
      const timer = setTimeout(() => {
        ws.close();
        resolve({ closeCode: null });
      }, 15_000);
      ws.on("close", (code) => {
        clearTimeout(timer);
        resolve({ closeCode: code });
      });
      ws.on("error", () => {
        clearTimeout(timer);
        resolve({ closeCode: null });
      });
    });

    expect(result.closeCode).toBe(1008);
  });

  // ── 6. Tool use prompt → bash tool lifecycle (requires real LLM) ──

  it("sends a prompt requiring bash tool and verifies tool lifecycle", async () => {
    if (!lmsReady()) return;

    const stream = await openSessionStream(deviceToken, workspaceId, sessionId);
    const approver = autoApprovePermissions(stream, sessionId);

    try {
      const startIndex = stream.events.length;

      await sendPromptAndWait(
        stream,
        sessionId,
        'Use exactly one bash tool call with this command: echo E2E_TOOL_OK. After the tool finishes, reply with: "Tool executed successfully."',
        "req-e2e-tool-prompt",
        { timeoutMs: 300_000 },
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

      // Some tool calls emit multiple tool_start previews before a single tool_end.
      if (toolStarts.length > 0) {
        expect(approver.count()).toBe(0);
        expect(toolEnds.length).toBeGreaterThan(0);

        const firstToolStartIdx = sessionEvents.findIndex((e) => e.type === "tool_start");
        const firstToolEndIdx = sessionEvents.findIndex((e) => e.type === "tool_end");
        expect(firstToolStartIdx).toBeGreaterThanOrEqual(0);
        expect(firstToolEndIdx).toBeGreaterThan(firstToolStartIdx);
      }
    } finally {
      approver.stop();
      await closeStream(stream);
    }
  });

  // ── 7. Split session reconnect ──

  it("reconnects to the split session stream and receives fresh state", async () => {
    if (!lmsReady()) return;

    const stream1 = await openSessionStream(deviceToken, workspaceId, sessionId);
    try {
      const connected1 = stream1.events.find(
        (e) => e.type === "connected" && e.sessionId === sessionId,
      );
      const baselineSeq = connected1?.currentSeq ?? 0;

      await closeStream(stream1);

      const stream2 = await openSessionStream(deviceToken, workspaceId, sessionId);
      try {
        const connected2 = stream2.events.find(
          (e) => e.type === "connected" && e.sessionId === sessionId,
        );
        expect(connected2).toBeTruthy();
        expect(connected2?.currentSeq ?? 0).toBeGreaterThanOrEqual(baselineSeq);
        expect(stream2.events.some((e) => e.type === "state" && e.sessionId === sessionId)).toBe(
          true,
        );
      } finally {
        await closeStream(stream2);
      }
    } catch (err) {
      if (!stream1.closed) await closeStream(stream1);
      throw err;
    }
  });

  // ── 8. Session isolation ──

  it("does not expose a session through the wrong workspace", async () => {
    if (!lmsReady()) return;

    // Create a different workspace
    const ws2 = await api("POST", "/workspaces", deviceToken, {
      name: "e2e-wrong-workspace",
      skills: [],
    });
    const wrongWorkspaceId = (ws2.json?.workspace as Record<string, unknown>).id as string;

    // Try to access the session via the wrong workspace's sessions list
    const sessions = await listWorkspaceSessions(deviceToken, wrongWorkspaceId);
    const leaked = sessions.find((s) => s.id === sessionId);
    expect(leaked).toBeUndefined();

    const WebSocket = (await import("ws")).default;
    const result = await new Promise<{ closeCode: number | null }>((resolve) => {
      const ws = new WebSocket(sessionStreamURL(wrongWorkspaceId, sessionId), {
        headers: { Authorization: `Bearer ${deviceToken}` },
        ...(isSecureTransport() ? { rejectUnauthorized: false } : {}),
      });
      const timer = setTimeout(() => {
        ws.close();
        resolve({ closeCode: null });
      }, 15_000);
      ws.on("close", (code) => {
        clearTimeout(timer);
        resolve({ closeCode: code });
      });
      ws.on("error", () => {
        clearTimeout(timer);
        resolve({ closeCode: null });
      });
    });
    expect(result.closeCode).toBe(1008);
  });

  // ── 9. Workspace cleanup ──

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
