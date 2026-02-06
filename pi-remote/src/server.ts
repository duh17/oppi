/**
 * HTTP + WebSocket server
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { URL } from "node:url";
import type { Storage } from "./storage.js";
import { SessionManager } from "./sessions.js";
import { PolicyEngine } from "./policy.js";
import { GateServer, type PendingDecision } from "./gate.js";
import type { 
  User, 
  Session,
  ClientMessage, 
  ServerMessage,
  CreateSessionRequest,
  ApiError,
} from "./types.js";

export class Server {
  private storage: Storage;
  private sessions: SessionManager;
  private policy: PolicyEngine;
  private gate: GateServer;
  private httpServer: ReturnType<typeof createServer>;
  private wss: WebSocketServer;

  // Track WebSocket connections per user for permission forwarding
  private userConnections: Map<string, Set<WebSocket>> = new Map();

  constructor(storage: Storage) {
    this.storage = storage;
    this.policy = new PolicyEngine("admin"); // Default preset, per-user in v2
    this.gate = new GateServer(this.policy);
    this.sessions = new SessionManager(storage, this.gate);

    this.httpServer = createServer((req, res) => this.handleHttp(req, res));
    this.wss = new WebSocketServer({ noServer: true });

    this.httpServer.on("upgrade", (req, socket, head) => {
      this.handleUpgrade(req, socket, head);
    });

    // Wire gate events to WebSocket forwarding
    this.gate.on("approval_needed", (pending: PendingDecision) => {
      this.forwardPermissionRequest(pending);
    });

    this.gate.on("approval_timeout", ({ requestId, sessionId }: { requestId: string; sessionId: string }) => {
      // Notify phone that request expired
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

  /**
   * Start the server
   */
  start(): Promise<void> {
    const config = this.storage.getConfig();
    
    return new Promise((resolve) => {
      this.httpServer.listen(config.port, config.host, () => {
        console.log(`🚀 pi-remote listening on ${config.host}:${config.port}`);
        resolve();
      });
    });
  }

  /**
   * Stop the server
   */
  async stop(): Promise<void> {
    await this.sessions.stopAll();
    await this.gate.shutdown();
    this.wss.close();
    this.httpServer.close();
  }

  // ─── Permission Forwarding ───

  /**
   * Forward a permission request to the user's connected phone(s).
   */
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
    console.log(`[gate] Permission request ${pending.id} sent to ${pending.userId}: ${pending.displaySummary}`);
  }

  /**
   * Send a message to all WebSocket connections for a user.
   */
  private broadcastToUser(userId: string, msg: ServerMessage): void {
    const connections = this.userConnections.get(userId);
    if (!connections) return;

    const json = JSON.stringify(msg);
    for (const ws of connections) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(json);
      }
    }
  }

  /**
   * Track a user's WebSocket connection.
   */
  private trackUserConnection(userId: string, ws: WebSocket): void {
    let conns = this.userConnections.get(userId);
    if (!conns) {
      conns = new Set();
      this.userConnections.set(userId, conns);
    }
    conns.add(ws);
  }

  /**
   * Remove a user's WebSocket connection.
   */
  private untrackUserConnection(userId: string, ws: WebSocket): void {
    const conns = this.userConnections.get(userId);
    if (conns) {
      conns.delete(ws);
      if (conns.size === 0) {
        this.userConnections.delete(userId);
      }
    }
  }

  /**
   * Find a session by ID across all users (for gate event handling).
   */
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

    const token = auth.slice(7);
    const user = this.storage.getUserByToken(token);
    
    if (user) {
      this.storage.updateUserLastSeen(user.id);
    }

    return user || null;
  }

  // ─── HTTP Handlers ───

  private async handleHttp(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const path = url.pathname;
    const method = req.method || "GET";

    // CORS headers
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");

    if (method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    // Health check (no auth)
    if (path === "/health") {
      this.json(res, { ok: true });
      return;
    }

    // Auth required for everything else
    const user = this.authenticate(req);
    if (!user) {
      this.error(res, 401, "Unauthorized");
      return;
    }

    try {
      // Route handling
      if (path === "/me" && method === "GET") {
        this.json(res, { user: user.id, name: user.name });
        return;
      }

      if (path === "/sessions" && method === "GET") {
        const sessions = this.storage.listUserSessions(user.id);
        this.json(res, { sessions });
        return;
      }

      if (path === "/sessions" && method === "POST") {
        const body = await this.parseBody<CreateSessionRequest>(req);
        const session = this.storage.createSession(user.id, body.name, body.model);
        this.json(res, { session }, 201);
        return;
      }

      // /sessions/:id routes
      const sessionMatch = path.match(/^\/sessions\/([^/]+)$/);
      if (sessionMatch) {
        const sessionId = sessionMatch[1];
        const session = this.storage.getSession(user.id, sessionId);
        
        if (!session) {
          this.error(res, 404, "Session not found");
          return;
        }

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
      req.on("data", chunk => body += chunk);
      req.on("end", () => {
        try {
          resolve(body ? JSON.parse(body) : {});
        } catch {
          reject(new Error("Invalid JSON"));
        }
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
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const path = url.pathname;

    // Auth
    const user = this.authenticate(req);
    if (!user) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    // Must be /sessions/:id/stream
    const match = path.match(/^\/sessions\/([^/]+)\/stream$/);
    if (!match) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    const sessionId = match[1];
    const session = this.storage.getSession(user.id, sessionId);
    
    if (!session) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    this.wss.handleUpgrade(req, socket, head, (ws) => {
      this.handleWebSocket(ws, user, session);
    });
  }

  private async handleWebSocket(ws: WebSocket, user: User, session: Session): Promise<void> {
    console.log(`[ws] Connected: ${user.name} → ${session.id}`);

    // Track this connection for permission forwarding
    this.trackUserConnection(user.id, ws);

    const send = (msg: ServerMessage) => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(msg));
      }
    };

    try {
      // Start or attach to session
      const activeSession = await this.sessions.startSession(user.id, session.id);
      send({ type: "connected", session: activeSession });

      // Send any pending permission requests for this user
      const pendingRequests = this.gate.getPendingForUser(user.id);
      for (const pending of pendingRequests) {
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

      // Subscribe to events
      const unsubscribe = this.sessions.subscribe(user.id, session.id, send);

      // Handle messages
      ws.on("message", async (data) => {
        try {
          const msg = JSON.parse(data.toString()) as ClientMessage;
          await this.handleClientMessage(user, session, msg, send);
        } catch (err: any) {
          send({ type: "error", error: err.message });
        }
      });

      // Handle close
      ws.on("close", () => {
        console.log(`[ws] Disconnected: ${user.name} → ${session.id}`);
        unsubscribe();
        this.untrackUserConnection(user.id, ws);
      });

      ws.on("error", (err) => {
        console.error(`[ws] Error: ${user.name} → ${session.id}`, err);
        unsubscribe();
        this.untrackUserConnection(user.id, ws);
      });

    } catch (err: any) {
      console.error(`[ws] Setup error:`, err);
      send({ type: "error", error: err.message });
      this.untrackUserConnection(user.id, ws);
      ws.close();
    }
  }

  private async handleClientMessage(
    user: User, 
    session: Session, 
    msg: ClientMessage,
    send: (msg: ServerMessage) => void
  ): Promise<void> {
    switch (msg.type) {
      case "prompt":
        // Save user message
        this.storage.addSessionMessage(user.id, session.id, {
          role: "user",
          content: msg.message,
          timestamp: Date.now(),
        });

        // Build pi command
        const piCommand: any = {
          type: "prompt",
          message: msg.message,
        };

        if (msg.images?.length) {
          piCommand.images = msg.images.map(img => ({
            type: "image",
            source: {
              type: "base64",
              mediaType: img.mimeType,
              data: img.data,
            },
          }));
        }

        await this.sessions.sendCommand(user.id, session.id, piCommand);
        break;

      case "abort":
        await this.sessions.sendCommand(user.id, session.id, { type: "abort" });
        break;

      case "get_state":
        const activeSession = this.sessions.getActiveSession(user.id, session.id);
        if (activeSession) {
          send({ type: "state", session: activeSession });
        }
        break;

      case "permission_response":
        const resolved = this.gate.resolveDecision(msg.id, msg.action);
        if (!resolved) {
          send({ type: "error", error: `Permission request not found: ${msg.id}` });
        }
        break;
    }
  }
}
