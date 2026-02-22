import { ts } from "./log-utils.js";
import { appendSessionMessage } from "./session-protocol.js";
import type { TurnSessionState } from "./session-turns.js";
import type { Session, TurnCommand } from "./types.js";

export interface SessionInputSessionState extends TurnSessionState {
  session: Session;
}

export interface SessionInputCoordinatorDeps {
  getActiveSession: (key: string) => SessionInputSessionState | undefined;
  beginTurnIntent: (
    key: string,
    active: SessionInputSessionState,
    command: TurnCommand,
    payload: unknown,
    clientTurnId?: string,
    requestId?: string,
  ) => { clientTurnId?: string; duplicate: boolean };
  markTurnDispatched: (
    key: string,
    active: SessionInputSessionState,
    command: TurnCommand,
    turn: { clientTurnId?: string; duplicate: boolean },
    requestId?: string,
  ) => void;
  sendCommand: (key: string, command: Record<string, unknown>) => void;
}

export class SessionInputCoordinator {
  constructor(private readonly deps: SessionInputCoordinatorDeps) {}

  async sendPrompt(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
      clientTurnId?: string;
      requestId?: string;
      timestamp?: number;
    },
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const turn = this.deps.beginTurnIntent(
      key,
      active,
      "prompt",
      {
        message,
        images: opts?.images ?? [],
        streamingBehavior: opts?.streamingBehavior,
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    appendSessionMessage(active.session, {
      role: "user",
      content: message,
      timestamp: opts?.timestamp ?? Date.now(),
    });

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message,
    };

    // SDK image format: {type:"image", data:"base64...", mimeType:"image/png"}
    if (opts?.images?.length) {
      cmd.images = opts.images;
    }

    // If agent is busy, add streaming behavior
    if (active.session.status === "busy" && opts?.streamingBehavior) {
      cmd.streamingBehavior = opts.streamingBehavior;
    }

    console.log(
      `${ts()} [sdk] prompt → pi (session=${active.session.id}, status=${active.session.status})`,
    );

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "prompt", turn, opts?.requestId);
  }

  async sendSteer(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    if (active.session.status !== "busy") {
      throw new Error("Steer requires an active streaming turn");
    }

    const turn = this.deps.beginTurnIntent(
      key,
      active,
      "steer",
      {
        message,
        images: opts?.images ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const cmd: Record<string, unknown> = { type: "steer", message };
    if (opts?.images?.length) {
      cmd.images = opts.images;
    }

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "steer", turn, opts?.requestId);
  }

  async sendFollowUp(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    if (active.session.status !== "busy") {
      throw new Error("Follow-up requires an active streaming turn");
    }

    const turn = this.deps.beginTurnIntent(
      key,
      active,
      "follow_up",
      {
        message,
        images: opts?.images ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const cmd: Record<string, unknown> = { type: "follow_up", message };
    if (opts?.images?.length) {
      cmd.images = opts.images;
    }

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "follow_up", turn, opts?.requestId);
  }
}
