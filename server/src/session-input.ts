import { appendSessionMessage } from "./session-protocol.js";
import type { TurnSessionState } from "./session-turns.js";
import type { ChatAttachmentRef, Session, TurnCommand } from "./types.js";
import { createLogger } from "./logger.js";
import { materializeChatAttachments } from "./chat-attachments.js";
import type { UploadStoreConfigResolved } from "./uploads/local-upload-store.js";

export interface SessionInputSessionState extends TurnSessionState {
  session: Session;
}

const log = createLogger({ base: { component: "session_input" } });

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
  enqueueQueuedMessage?: (
    key: string,
    kind: "steer" | "follow_up",
    message: string,
    images?: Array<{ type: "image"; data: string; mimeType: string }>,
    attachments?: ChatAttachmentRef[],
    idHint?: string,
    sdkMessage?: string,
    sdkImages?: Array<{ type: "image"; data: string; mimeType: string }>,
  ) => void;
  resolveWorkspaceRoot?: (session: Session) => string | null;
  maxTurnAttachmentBytes?: number;
  uploadStoreConfig?: UploadStoreConfigResolved;
  onFirstMessage?: (session: Session) => void;
}

export class SessionInputCoordinator {
  constructor(private readonly deps: SessionInputCoordinatorDeps) {}

  private async prepareMessageWithAttachments(
    active: SessionInputSessionState,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<{
    message: string;
    images: Array<{ type: "image"; data: string; mimeType: string }>;
  }> {
    if (!opts?.attachments?.length) {
      return { message, images: [] };
    }

    const workspaceRoot = this.deps.resolveWorkspaceRoot?.(active.session);
    if (!workspaceRoot) {
      throw new Error("Attachments require a workspace-backed session");
    }

    if (!active.session.workspaceId) {
      throw new Error("Attachments require a workspace-backed session");
    }

    const materialized = await materializeChatAttachments({
      workspaceRoot,
      workspaceId: active.session.workspaceId,
      sessionId: active.session.id,
      turnId: opts.clientTurnId ?? opts.requestId,
      message,
      attachments: opts.attachments,
      maxTurnBytes: this.deps.maxTurnAttachmentBytes,
      uploadStore: this.deps.uploadStoreConfig,
    });

    return {
      message: materialized.message,
      images: materialized.imageInputs,
    };
  }

  async sendPrompt(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
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
        attachments: opts?.attachments ?? [],
        streamingBehavior: opts?.streamingBehavior,
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = [...(opts?.images ?? []), ...prepared.images];
    const dispatchMessage = prepared.message;

    const capturedFirst = appendSessionMessage(active.session, {
      role: "user",
      content: dispatchMessage,
      timestamp: opts?.timestamp ?? Date.now(),
    });

    if (capturedFirst) {
      this.deps.onFirstMessage?.(active.session);
    }

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message: dispatchMessage,
    };

    // SDK image format: {type:"image", data:"base64...", mimeType:"image/png"}
    if (dispatchImages.length) {
      cmd.images = dispatchImages;
    }

    // If agent is busy, add streaming behavior
    if (active.session.status === "busy" && opts?.streamingBehavior) {
      cmd.streamingBehavior = opts.streamingBehavior;
    }

    log.info("session_input.prompt_sent", {
      sessionId: active.session.id,
      status: active.session.status,
    });

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "prompt", turn, opts?.requestId);

    if (active.session.status === "busy" && opts?.streamingBehavior) {
      const kind = opts.streamingBehavior === "steer" ? "steer" : "follow_up";
      this.deps.enqueueQueuedMessage?.(
        key,
        kind,
        message,
        dispatchImages,
        opts.attachments,
        turn.clientTurnId,
        dispatchMessage,
        dispatchImages,
      );
    }
  }

  async sendSteer(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
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
        attachments: opts?.attachments ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = [...(opts?.images ?? []), ...prepared.images];
    const dispatchMessage = prepared.message;

    const cmd: Record<string, unknown> = { type: "steer", message: dispatchMessage };
    if (dispatchImages.length) {
      cmd.images = dispatchImages;
    }

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "steer", turn, opts?.requestId);
    this.deps.enqueueQueuedMessage?.(
      key,
      "steer",
      message,
      dispatchImages,
      opts?.attachments,
      turn.clientTurnId,
      dispatchMessage,
      dispatchImages,
    );
  }

  async sendFollowUp(
    key: string,
    message: string,
    opts?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      attachments?: ChatAttachmentRef[];
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
        attachments: opts?.attachments ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return;
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = [...(opts?.images ?? []), ...prepared.images];
    const dispatchMessage = prepared.message;

    const cmd: Record<string, unknown> = { type: "follow_up", message: dispatchMessage };
    if (dispatchImages.length) {
      cmd.images = dispatchImages;
    }

    this.deps.sendCommand(key, cmd);
    this.deps.markTurnDispatched(key, active, "follow_up", turn, opts?.requestId);
    this.deps.enqueueQueuedMessage?.(
      key,
      "follow_up",
      message,
      dispatchImages,
      opts?.attachments,
      turn.clientTurnId,
      dispatchMessage,
      dispatchImages,
    );
  }
}
