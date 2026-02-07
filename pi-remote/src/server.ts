/**
 * HTTP + WebSocket server.
 *
 * Bridges phone clients to pi sessions running in sandboxed containers.
 * Handles: auth, session CRUD, WebSocket streaming, permission gate
 * forwarding, and extension UI request relay.
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager, type ExtensionUIResponse } from "./sessions.js";
import { PolicyEngine } from "./policy.js";
import { GateServer, type PendingDecision } from "./gate.js";
import { SandboxManager } from "./sandbox.js";
import { readSessionTrace } from "./trace.js";
import { createPushClient, type PushClient, type APNsConfig } from "./push.js";
import type {
  User,
  Session,
  ClientMessage,
  ServerMessage,
  CreateSessionRequest,
  RegisterDeviceTokenRequest,
  ApiError,
} from "./types.js";

export class Server {
  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private sandbox: SandboxManager;
  private push: PushClient;
  private httpServer: ReturnType<typeof createServer>;
  private wss: WebSocketServer;

  // Track WebSocket connections per user for permission/UI forwarding
  private userConnections: Map<string, Set<WebSocket>> = new Map();

  constructor(storage: Storage, apnsConfig?: APNsConfig) {
    this.storage = storage;

    this.policy = new PolicyEngine("admin"); // Per-user in v2
    this.gate = new GateServer(this.policy);
    this.sandbox = new SandboxManager();
    this.push = createPushClient(apnsConfig);
    this.sessions = new SessionManager(storage, this.gate, this.sandbox);

    this.httpServer = createServer((req, res) => this.handleHttp(req, res));
    this.wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });

    // Wire gate events → phone WebSocket
    this.gate.on("approval_needed", (pending: PendingDecision) => {
      this.forwardPermissionRequest(pending);
    });

    this.gate.on("approval_timeout", ({ requestId, sessionId }: { requestId: string; sessionId: string }) => {
      const session = this.findSessionById(sessionId);
      if (session) {
        this.broadcastToUser(session.userId, {
          type: "permission_expired",
          id: requestId,
          reason: "Approval timeout",
        });
      }
    });
  }

  // ─── Start / Stop ───

  async start(): Promise<void> {
    // Best-effort cleanup from previous crashes before accepting connections.
    await this.sandbox.cleanupOrphanedContainers();

    // Ensure container image exists (build if needed)
    await this.sandbox.ensureImage();

    const config = this.storage.getConfig();
    return new Promise((resolve) => {
      this.httpServer.listen(config.port, config.host, () => {
        console.log(`🚀 pi-remote listening on ${config.host}:${config.port}`);
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    await this.sessions.stopAll();
    await this.sandbox.cleanupOrphanedContainers();
    await this.gate.shutdown();
    this.push.shutdown();
    this.wss.close();
    this.httpServer.close();
  }

  // ─── Permission Forwarding ───

  private forwardPermissionRequest(pending: PendingDecision): void {
    const msg: ServerMessage = {
      type: "permission_request",
      id: pending.id,
      sessionId: pending.sessionId,
      tool: pending.tool,
      input: pending.input,
      displaySummary: pending.displaySummary,
      risk: pending.risk,
      reason: pending.reason,
      timeoutAt: pending.timeoutAt,
    };

    this.broadcastToUser(pending.userId, msg);
    console.log(`[gate] Permission request ${pending.id} → ${pending.userId}: ${pending.displaySummary}`);
  }

  // ─── User Connection Tracking ───

  private broadcastToUser(userId: string, msg: ServerMessage): void {
    const conns = this.userConnections.get(userId);
    const hasWS = conns && conns.size > 0 &&
      Array.from(conns).some(ws => ws.readyState === WebSocket.OPEN);

    if (hasWS) {
      const json = JSON.stringify(msg);
      for (const ws of conns!) {
        if (ws.readyState === WebSocket.OPEN) ws.send(json, { compress: false });
      }
    } else {
      // No WebSocket connected — fall back to push notification
      this.pushFallback(userId, msg);
    }
  }

  /**
   * Send a push notification when no WebSocket client is connected.
   * Only fires for permission requests and session lifecycle events.
   */
  private pushFallback(userId: string, msg: ServerMessage): void {
    const tokens = this.storage.getDeviceTokens(userId);
    if (tokens.length === 0) return;

    if (msg.type === "permission_request") {
      const session = this.findSessionById(msg.sessionId);
      for (const token of tokens) {
        this.push.sendPermissionPush(token, {
          permissionId: msg.id,
          sessionId: msg.sessionId,
          sessionName: session?.name,
          tool: msg.tool,
          displaySummary: msg.displaySummary,
          risk: msg.risk,
          reason: msg.reason,
          timeoutAt: msg.timeoutAt,
        }).then(ok => {
          if (!ok) {
            // Token might be expired — don't remove yet, APNs 410 handler does that
          }
        });
      }
    } else if (msg.type === "session_ended") {
      const session = this.findSessionByReason(userId, msg);
      for (const token of tokens) {
        this.push.sendSessionEventPush(token, {
          sessionId: session?.id || "unknown",
          sessionName: session?.name,
          event: "ended",
          reason: msg.reason,
        });
      }
    } else if (msg.type === "error") {
      // Only push errors that aren't retries
      if (!msg.error.startsWith("Retrying (")) {
        for (const token of tokens) {
          this.push.sendSessionEventPush(token, {
            sessionId: "unknown",
            event: "error",
            reason: msg.error,
          });
        }
      }
    }
  }

  /**
   * Find session from a session_ended message context.
   * We track which user's sessions are active to find the match.
   */
  private findSessionByReason(userId: string, _msg: ServerMessage): Session | undefined {
    const sessions = this.storage.listUserSessions(userId);
    // Return the most recently active session (best effort)
    return sessions.find(s => s.status === "stopped") || sessions[0];
  }

  private trackConnection(userId: string, ws: WebSocket): void {
    let conns = this.userConnections.get(userId);
    if (!conns) { conns = new Set(); this.userConnections.set(userId, conns); }
    conns.add(ws);
  }

  private untrackConnection(userId: string, ws: WebSocket): void {
    const conns = this.userConnections.get(userId);
    if (conns) {
      conns.delete(ws);
      if (conns.size === 0) this.userConnections.delete(userId);
    }
  }

  private findSessionById(sessionId: string): Session | undefined {
    for (const user of this.storage.listUsers()) {
      const sessions = this.storage.listUserSessions(user.id);
      const match = sessions.find(s => s.id === sessionId);
      if (match) return match;
    }
    return undefined;
  }

  // ─── Auth ───

  private authenticate(req: IncomingMessage): User | null {
    const auth = req.headers.authorization;
    if (!auth?.startsWith("Bearer ")) return null;
    const user = this.storage.getUserByToken(auth.slice(7));
    if (user) this.storage.updateUserLastSeen(user.id);
    return user || null;
  }

  // ─── HTTP Routes ───

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");

    if (method === "OPTIONS") { res.writeHead(204); res.end(); return; }
    if (path === "/health") { this.json(res, { ok: true }); return; }

    const user = this.authenticate(req);
    if (!user) { this.error(res, 401, "Unauthorized"); return; }

    try {
      if (path === "/me" && method === "GET") {
        this.json(res, { user: user.id, name: user.name });
        return;
      }

      // Device token registration (APNs + Live Activity)
      if (path === "/me/device-token" && method === "POST") {
        const body = await this.parseBody<RegisterDeviceTokenRequest>(req);
        if (!body.deviceToken) {
          this.error(res, 400, "deviceToken required");
          return;
        }

        const tokenType = body.tokenType || "apns";
        if (tokenType === "liveactivity") {
          this.storage.setLiveActivityToken(user.id, body.deviceToken);
          console.log(`[push] Live Activity token registered for ${user.name}`);
        } else {
          this.storage.addDeviceToken(user.id, body.deviceToken);
          console.log(`[push] Device token registered for ${user.name}`);
        }

        this.json(res, { ok: true });
        return;
      }

      if (path === "/me/device-token" && method === "DELETE") {
        const body = await this.parseBody<{ deviceToken: string }>(req);
        if (body.deviceToken) {
          this.storage.removeDeviceToken(user.id, body.deviceToken);
          console.log(`[push] Device token removed for ${user.name}`);
        }
        this.json(res, { ok: true });
        return;
      }

      if (path === "/sessions" && method === "GET") {
        this.json(res, { sessions: this.storage.listUserSessions(user.id) });
        return;
      }

      if (path === "/sessions" && method === "POST") {
        const body = await this.parseBody<CreateSessionRequest>(req);
        const session = this.storage.createSession(user.id, body.name, body.model);
        this.json(res, { session }, 201);
        return;
      }

      const stopMatch = path.match(/^\/sessions\/([^/]+)\/stop$/);
      if (stopMatch && method === "POST") {
        const sessionId = stopMatch[1];
        const session = this.storage.getSession(user.id, sessionId);
        if (!session) { this.error(res, 404, "Session not found"); return; }

        if (this.sessions.isActive(user.id, sessionId)) {
          await this.sessions.stopSession(user.id, sessionId);
        } else {
          session.status = "stopped";
          session.lastActivity = Date.now();
          this.storage.saveSession(session);
        }

        const updatedSession = this.storage.getSession(user.id, sessionId);
        this.json(res, { ok: true, session: updatedSession });
        return;
      }

      // Trace endpoint — full pi JSONL with tool calls
      const traceMatch = path.match(/^\/sessions\/([^/]+)\/trace$/);
      if (traceMatch && method === "GET") {
        const sessionId = traceMatch[1];
        const session = this.storage.getSession(user.id, sessionId);
        if (!session) { this.error(res, 404, "Session not found"); return; }

        const sandboxBaseDir = this.sandbox.getBaseDir();
        const trace = readSessionTrace(sandboxBaseDir, user.id);
        this.json(res, { session, trace: trace || [] });
        return;
      }

      const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
      if (sessionMatch) {
        const sessionId = sessionMatch[1];
        const session = this.storage.getSession(user.id, sessionId);
        if (!session) { this.error(res, 404, "Session not found"); return; }

        if (method === "GET") {
          const messages = this.storage.getSessionMessages(user.id, sessionId);
          this.json(res, { session, messages });
          return;
        }

        if (method === "DELETE") {
          await this.sessions.stopSession(user.id, sessionId);
          this.storage.deleteSession(user.id, sessionId);
          this.json(res, { ok: true });
          return;
        }
      }

      this.error(res, 404, "Not found");
    } catch (err: any) {
      console.error("HTTP error:", err);
      this.error(res, 500, err.message || "Internal error");
    }
  }

  private async parseBody<T>(req: IncomingMessage): Promise<T> {
    return new Promise((resolve, reject) => {
      let body = "";
      req.on("data", (chunk: Buffer) => body += chunk);
      req.on("end", () => {
        try { resolve(body ? JSON.parse(body) : {}); }
        catch { reject(new Error("Invalid JSON")); }
      });
      req.on("error", reject);
    });
  }

  private json(res: ServerResponse, data: any, status = 200): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(data));
  }

  private error(res: ServerResponse, status: number, message: string): void {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: message } as ApiError));
  }

  // ─── WebSocket ───

  private handleUpgrade(req: IncomingMessage, socket: any, head: Buffer): void {
    socket.setNoDelay?.(true);

    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const user = this.authenticate(req);
    if (!user) { socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n"); socket.destroy(); return; }

    const match = url.pathname.match(/^\/sessions\/([^/]+)\/stream$/);
    if (!match) { socket.write("HTTP/1.1 404 Not Found\r\n\r\n"); socket.destroy(); return; }

    const session = this.storage.getSession(user.id, match[1]);
    if (!session) { socket.write("HTTP/1.1 404 Not Found\r\n\r\n"); socket.destroy(); return; }

    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.handleWebSocket(ws, user, session);
    });
  }

  private async handleWebSocket(ws: WebSocket, user: User, session: Session): Promise<void> {
    console.log(`[ws] Connected: ${user.name} → ${session.id}`);
    this.trackConnection(user.id, ws);

    const send = (msg: ServerMessage) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg), { compress: false });
      }
    };

    try {
      const activeSession = await this.sessions.startSession(user.id, session.id);
      send({ type: "connected", session: activeSession });

      // Send pending permission requests
      for (const pending of this.gate.getPendingForUser(user.id)) {
        send({
          type: "permission_request",
          id: pending.id,
          sessionId: pending.sessionId,
          tool: pending.tool,
          input: pending.input,
          displaySummary: pending.displaySummary,
          risk: pending.risk,
          reason: pending.reason,
          timeoutAt: pending.timeoutAt,
        });
      }

      // Subscribe to session events
      const unsubscribe = this.sessions.subscribe(user.id, session.id, send);

      ws.on("message", async (data) => {
        try {
          const msg = JSON.parse(data.toString()) as ClientMessage;
          await this.handleClientMessage(user, activeSession, msg, send);
        } catch (err: any) {
          send({ type: "error", error: err.message });
        }
      });

      ws.on("close", () => {
        console.log(`[ws] Disconnected: ${user.name} → ${session.id}`);
        unsubscribe();
        this.untrackConnection(user.id, ws);
      });

      ws.on("error", (err) => {
        console.error(`[ws] Error: ${user.name} → ${session.id}`, err);
        unsubscribe();
        this.untrackConnection(user.id, ws);
      });

    } catch (err: any) {
      console.error(`[ws] Setup error:`, err);
      send({ type: "error", error: err.message });
      this.untrackConnection(user.id, ws);
      ws.close();
    }
  }

  private async handleClientMessage(
    user: User,
    session: Session,
    msg: ClientMessage,
    send: (msg: ServerMessage) => void,
  ): Promise<void> {
    switch (msg.type) {
      case "prompt": {
        const timestamp = Date.now();
        this.storage.addSessionMessage(user.id, session.id, {
          role: "user",
          content: msg.message,
          timestamp,
        });
        this.sessions.recordUserMessage(user.id, session.id, msg.message, timestamp);

        // RPC image format: { type: "image", data: "base64...", mimeType: "image/png" }
        const images = msg.images?.map(img => ({
          type: "image" as const,
          data: img.data,
          mimeType: img.mimeType,
        }));

        await this.sessions.sendPrompt(user.id, session.id, msg.message, {
          images,
          streamingBehavior: msg.streamingBehavior,
        });
        break;
      }

      case "steer":
        await this.sessions.sendSteer(user.id, session.id, msg.message);
        break;

      case "follow_up":
        await this.sessions.sendFollowUp(user.id, session.id, msg.message);
        break;

      case "abort":
      case "stop":
        await this.sessions.sendAbort(user.id, session.id);
        break;

      case "get_state": {
        const active = this.sessions.getActiveSession(user.id, session.id);
        if (active) send({ type: "state", session: active });
        break;
      }

      case "permission_response": {
        const resolved = this.gate.resolveDecision(msg.id, msg.action);
        if (!resolved) {
          send({ type: "error", error: `Permission request not found: ${msg.id}` });
        }
        break;
      }

      case "extension_ui_response": {
        const ok = this.sessions.respondToUIRequest(user.id, session.id, {
          type: "extension_ui_response",
          id: msg.id,
          value: msg.value,
          confirmed: msg.confirmed,
          cancelled: msg.cancelled,
        });
        if (!ok) {
          send({ type: "error", error: `UI request not found: ${msg.id}` });
        }
        break;
      }
    }
  }
}
