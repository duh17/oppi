/**
 * Permission gate — pi extension.
 *
 * Hooks tool_call events and delegates permission decisions
 * to the pi-remote server via a Unix domain socket.
 *
 * Env vars (set by pi-remote server on spawn):
 *   PI_REMOTE_GATE_SOCK  — Path to the session's Unix socket
 *   PI_REMOTE_SESSION     — Session ID
 *
 * Protocol: newline-delimited JSON over Unix socket.
 */

import { createConnection, type Socket } from "node:net";
import { createInterface, type Interface as Readline } from "node:readline";

const HEARTBEAT_INTERVAL_MS = 15_000;
const CONNECT_TIMEOUT_MS = 5_000;
const GATE_CHECK_TIMEOUT_MS = 180_000; // 3 min (slightly longer than server's 2 min approval timeout)

// ─── Types ───

interface GateResult {
  type: "gate_result";
  action: "allow" | "deny";
  reason?: string;
}

interface GuardAck {
  type: "guard_ack";
  status: string;
}

interface HeartbeatAck {
  type: "heartbeat_ack";
}

type ServerMessage = GateResult | GuardAck | HeartbeatAck;

// Minimal extension API types (subset of pi's ExtensionAPI)
// We type just what we use to avoid importing pi internals.
interface ToolCallEvent {
  toolName: string;
  toolCallId: string;
  input: Record<string, unknown>;
}

interface ToolCallResult {
  block?: boolean;
  reason?: string;
}

interface ExtensionContext {
  cwd: string;
}

type EventHandler<E, R = undefined> = (event: E, ctx: ExtensionContext) => Promise<R | void> | R | void;

interface ExtensionAPI {
  on(event: "tool_call", handler: EventHandler<ToolCallEvent, ToolCallResult>): void;
  on(event: "before_agent_start", handler: EventHandler<any, any>): void;
  on(event: "session_shutdown", handler: EventHandler<any>): void;
}

// ─── Socket Client ───

class GateClient {
  private socket: Socket | null = null;
  private readline: Readline | null = null;
  private socketPath: string;
  private connected = false;
  private responseQueue: Map<string, (msg: ServerMessage) => void> = new Map();
  private messageBuffer: ServerMessage[] = [];

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  /**
   * Connect to the gate socket.
   */
  async connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error(`Gate socket connect timeout: ${this.socketPath}`));
      }, CONNECT_TIMEOUT_MS);

      this.socket = createConnection(this.socketPath, () => {
        clearTimeout(timer);
        this.connected = true;
        resolve();
      });

      this.socket.on("error", (err) => {
        clearTimeout(timer);
        if (!this.connected) {
          reject(err);
        }
        // If already connected, errors will be caught by the readline close handler
      });

      this.socket.on("close", () => {
        this.connected = false;
        // Reject all pending responses
        for (const [key, resolve] of this.responseQueue) {
          resolve({ type: "gate_result", action: "deny", reason: "Gate connection lost" });
        }
        this.responseQueue.clear();
      });

      // Set up message reader
      this.readline = createInterface({ input: this.socket });
      this.readline.on("line", (line) => {
        try {
          const msg = JSON.parse(line) as ServerMessage;
          this.handleMessage(msg);
        } catch {}
      });
    });
  }

  /**
   * Send a message and wait for the corresponding response.
   */
  async request(msg: Record<string, unknown>, responseType: string, timeoutMs: number): Promise<ServerMessage> {
    if (!this.connected || !this.socket) {
      return { type: "gate_result", action: "deny", reason: "Not connected to gate" };
    }

    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.responseQueue.delete(responseType);
        resolve({ type: "gate_result", action: "deny", reason: "Gate request timeout" });
      }, timeoutMs);

      this.responseQueue.set(responseType, (response) => {
        clearTimeout(timer);
        resolve(response);
      });

      this.socket!.write(JSON.stringify(msg) + "\n");
    });
  }

  /**
   * Send a fire-and-forget message (heartbeat).
   */
  send(msg: Record<string, unknown>): void {
    if (this.connected && this.socket) {
      this.socket.write(JSON.stringify(msg) + "\n");
    }
  }

  /**
   * Close the connection.
   */
  close(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
    this.connected = false;
  }

  isConnected(): boolean {
    return this.connected;
  }

  // ─── Internal ───

  private handleMessage(msg: ServerMessage): void {
    // Route to waiting request handler
    const handler = this.responseQueue.get(msg.type);
    if (handler) {
      this.responseQueue.delete(msg.type);
      handler(msg);
      return;
    }

    // For gate_result, it's always the response to the current gate_check
    if (msg.type === "gate_result") {
      const handler = this.responseQueue.get("gate_result");
      if (handler) {
        this.responseQueue.delete("gate_result");
        handler(msg);
        return;
      }
    }
  }
}

// ─── Extension Entry Point ───

export default function permissionGate(pi: ExtensionAPI): void {
  const socketPath = process.env.PI_REMOTE_GATE_SOCK;
  const sessionId = process.env.PI_REMOTE_SESSION;

  // Not running under pi-remote — no-op
  if (!socketPath) return;

  const client = new GateClient(socketPath);
  let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

  // ─── Handshake on agent start ───
  pi.on("before_agent_start", async () => {
    try {
      await client.connect();

      // Send guard_ready
      const ack = await client.request(
        {
          type: "guard_ready",
          sessionId: sessionId || "unknown",
          extensionVersion: "1.0.0",
        },
        "guard_ack",
        5000,
      );

      if ((ack as GuardAck).status === "ok") {
        // Start heartbeat
        heartbeatTimer = setInterval(() => {
          client.send({ type: "heartbeat" });
        }, HEARTBEAT_INTERVAL_MS);
      }
    } catch (err) {
      console.error("[permission-gate] Failed to connect to gate socket:", err);
      // Extension continues — tool_call handler will deny everything if not connected
    }
  });

  // ─── Gate every tool call ───
  pi.on("tool_call", async (event: ToolCallEvent): Promise<ToolCallResult | void> => {
    if (!client.isConnected()) {
      return { block: true, reason: "Permission gate not connected" };
    }

    const response = await client.request(
      {
        type: "gate_check",
        tool: event.toolName,
        input: event.input,
        toolCallId: event.toolCallId,
      },
      "gate_result",
      GATE_CHECK_TIMEOUT_MS,
    );

    if (response.type === "gate_result" && response.action === "deny") {
      return { block: true, reason: response.reason || "Denied by permission gate" };
    }

    // Allow — return void, tool executes normally
  });

  // ─── Cleanup on shutdown ───
  pi.on("session_shutdown", () => {
    if (heartbeatTimer) {
      clearInterval(heartbeatTimer);
      heartbeatTimer = null;
    }
    client.close();
  });
}
