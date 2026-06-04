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

function runtimeLogTag(session: Session): "oppi" | "pi-tui" {
  return session.runtime === "pi-tui" ? "pi-tui" : "oppi";
}

export type SdkImageInput = { type: "image"; data: string; mimeType: string };
type StreamingInputKind = "steer" | "follow_up";

export interface SessionInputDispatchResult {
  duplicate: boolean;
}

function isPromiseLike(value: void | Promise<unknown>): value is Promise<unknown> {
  return Boolean(
    value && typeof value === "object" && typeof (value as { then?: unknown }).then === "function",
  );
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
  isDuplicateTurnIntent: (
    active: SessionInputSessionState,
    command: TurnCommand,
    clientTurnId: string | undefined,
    payload: unknown,
  ) => boolean;
  markTurnDispatched: (
    key: string,
    active: SessionInputSessionState,
    command: TurnCommand,
    turn: { clientTurnId?: string; duplicate: boolean },
    requestId?: string,
  ) => void;
  sendCommand: (key: string, command: Record<string, unknown>) => void | Promise<unknown>;
  onCommandResult?: (
    key: string,
    command: Record<string, unknown>,
    data: unknown,
  ) => void | Promise<void>;
  enqueueQueuedMessage?: (
    key: string,
    kind: "steer" | "follow_up",
    message: string,
    attachments?: ChatAttachmentRef[],
    idHint?: string,
    sdkMessage?: string,
    sdkImages?: SdkImageInput[],
  ) => void;
  resolveWorkspaceRoot?: (session: Session) => string | null;
  maxTurnAttachmentBytes?: number;
  uploadStoreConfig?: UploadStoreConfigResolved;
  onFirstMessage?: (session: Session) => void;
  recordPromptLocally?: boolean;
  promptBusyErrorMessage?: string;
  streamingInputBusyErrorMessage?: (kind: StreamingInputKind) => string;
  attachmentWorkspaceErrorMessage?: string;
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
    images: SdkImageInput[];
  }> {
    if (!opts?.attachments?.length) {
      return { message, images: [] };
    }

    const workspaceRoot = this.deps.resolveWorkspaceRoot?.(active.session);
    const workspaceError =
      this.deps.attachmentWorkspaceErrorMessage ?? "Attachments require a workspace-backed session";
    if (!workspaceRoot) {
      throw new Error(workspaceError);
    }

    if (!active.session.workspaceId) {
      throw new Error(workspaceError);
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
      attachments?: ChatAttachmentRef[];
      streamingBehavior?: "steer" | "followUp";
      clientTurnId?: string;
      requestId?: string;
      timestamp?: number;
    },
  ): Promise<SessionInputDispatchResult> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    const turnPayload = {
      message,
      attachments: opts?.attachments ?? [],
      streamingBehavior: opts?.streamingBehavior,
    };

    if (
      active.session.status === "busy" &&
      !opts?.streamingBehavior &&
      !this.deps.isDuplicateTurnIntent(active, "prompt", opts?.clientTurnId, turnPayload)
    ) {
      throw new Error(
        this.deps.promptBusyErrorMessage ??
          "Prompt requires an idle session; use steer or follow_up while a turn is streaming",
      );
    }

    const turn = this.deps.beginTurnIntent(
      key,
      active,
      "prompt",
      turnPayload,
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return { duplicate: true };
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = prepared.images;
    const dispatchMessage = prepared.message;

    if (this.deps.recordPromptLocally !== false) {
      const capturedFirst = appendSessionMessage(active.session, {
        role: "user",
        content: dispatchMessage,
        timestamp: opts?.timestamp ?? Date.now(),
      });

      if (capturedFirst) {
        this.deps.onFirstMessage?.(active.session);
      }
    }

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message: dispatchMessage,
      ...(opts?.requestId ? { requestId: opts.requestId } : {}),
      ...(turn.clientTurnId ? { clientTurnId: turn.clientTurnId } : {}),
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
      runtime: runtimeLogTag(active.session),
      status: active.session.status,
      requestId: opts?.requestId,
      clientTurnId: turn.clientTurnId,
      chars: dispatchMessage.length,
      imageCount: dispatchImages.length,
      attachmentCount: opts?.attachments?.length ?? 0,
      streamingBehavior: cmd.streamingBehavior as string | undefined,
      recordPromptLocally: this.deps.recordPromptLocally !== false,
    });

    const commandResult = this.deps.sendCommand(key, cmd);
    if (isPromiseLike(commandResult)) {
      const data = await commandResult;
      await this.deps.onCommandResult?.(key, cmd, data);
    } else if (this.deps.onCommandResult) {
      await this.deps.onCommandResult(key, cmd, commandResult);
    }
    this.deps.markTurnDispatched(key, active, "prompt", turn, opts?.requestId);

    if (active.session.status === "busy" && opts?.streamingBehavior) {
      const kind = opts.streamingBehavior === "steer" ? "steer" : "follow_up";
      this.deps.enqueueQueuedMessage?.(
        key,
        kind,
        message,
        opts.attachments,
        turn.clientTurnId,
        dispatchMessage,
        dispatchImages,
      );
    }

    return { duplicate: false };
  }

  async sendSteer(
    key: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    await this.sendStreamingInput(key, "steer", message, opts);
  }

  async sendFollowUp(
    key: string,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<void> {
    await this.sendStreamingInput(key, "follow_up", message, opts);
  }

  private async sendStreamingInput(
    key: string,
    kind: StreamingInputKind,
    message: string,
    opts?: {
      attachments?: ChatAttachmentRef[];
      clientTurnId?: string;
      requestId?: string;
    },
  ): Promise<SessionInputDispatchResult> {
    const active = this.deps.getActiveSession(key);
    if (!active) {
      throw new Error(`Session not active: ${key}`);
    }

    if (active.session.status !== "busy") {
      const label = kind === "steer" ? "Steer" : "Follow-up";
      throw new Error(
        this.deps.streamingInputBusyErrorMessage?.(kind) ??
          `${label} requires an active streaming turn`,
      );
    }

    const turn = this.deps.beginTurnIntent(
      key,
      active,
      kind,
      {
        message,
        attachments: opts?.attachments ?? [],
      },
      opts?.clientTurnId,
      opts?.requestId,
    );

    if (turn.duplicate) {
      return { duplicate: true };
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = prepared.images;
    const dispatchMessage = prepared.message;

    const cmd: Record<string, unknown> = {
      type: kind,
      message: dispatchMessage,
      ...(opts?.requestId ? { requestId: opts.requestId } : {}),
      ...(turn.clientTurnId ? { clientTurnId: turn.clientTurnId } : {}),
    };
    if (dispatchImages.length) {
      cmd.images = dispatchImages;
    }

    log.info("session_input.streaming_sent", {
      sessionId: active.session.id,
      runtime: runtimeLogTag(active.session),
      status: active.session.status,
      command: kind,
      requestId: opts?.requestId,
      clientTurnId: turn.clientTurnId,
      chars: dispatchMessage.length,
      imageCount: dispatchImages.length,
      attachmentCount: opts?.attachments?.length ?? 0,
    });

    const commandResult = this.deps.sendCommand(key, cmd);
    if (isPromiseLike(commandResult)) {
      const data = await commandResult;
      await this.deps.onCommandResult?.(key, cmd, data);
    } else if (this.deps.onCommandResult) {
      await this.deps.onCommandResult(key, cmd, commandResult);
    }
    this.deps.markTurnDispatched(key, active, kind, turn, opts?.requestId);
    this.deps.enqueueQueuedMessage?.(
      key,
      kind,
      message,
      opts?.attachments,
      turn.clientTurnId,
      dispatchMessage,
      dispatchImages,
    );

    return { duplicate: false };
  }
}
