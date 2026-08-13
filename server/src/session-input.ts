import { appendSessionMessage } from "./session-protocol.js";
import type { SessionTurnCoordinator, TurnSessionState } from "./session-turns.js";
import type { ChatAttachmentRef, ServerConfig, Session } from "./types.js";
import { createLogger } from "./logger.js";
import { materializeChatAttachments } from "./chat-attachments.js";
import {
  resolveUploadStoreConfig,
  type UploadStoreConfigResolved,
} from "./uploads/local-upload-store.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type {
  ResourceUsagePromptEvidence,
  ResourceUsageService,
} from "./resource-usage-service.js";

export interface SessionInputSessionState extends TurnSessionState {
  session: Session;
  sdkBackend?: {
    isStreaming?: boolean;
    isCompacting?: boolean;
    isDisposed?: boolean;
    withModelTurnAdmission?<T>(
      commandType: string,
      operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
    ): Promise<T>;
    resourceUsagePromptEvidence?(message: string): ResourceUsagePromptEvidence | undefined;
    resourceUsageEntryIds?(): ReadonlySet<string>;
    appendResourceUsageHistoryMarker?(
      marker: ReturnType<ResourceUsageService["captureAcceptedPrompt"]>,
      priorEntryIds?: ReadonlySet<string>,
    ): void;
  };
}

const log = createLogger({ base: { component: "session_input" } });

function runtimeLogTag(session: Session): "oppi" | "pi-tui" {
  return session.runtime === "pi-tui" ? "pi-tui" : "oppi";
}

function isPiTuiSession(session: Session): boolean {
  return session.runtime === "pi-tui";
}

function shouldRecordPromptLocally(session: Session): boolean {
  // Terminal-owned turns are authoritative in pi-tui; Oppi only projects them.
  return !isPiTuiSession(session);
}

function promptBusyErrorMessage(session: Session): string {
  return isPiTuiSession(session)
    ? "Prompt requires an idle terminal session; use steer or follow_up while a turn is streaming"
    : "Prompt requires an idle session; use steer or follow_up while a turn is streaming";
}

function streamingInputBusyErrorMessage(session: Session, kind: StreamingInputKind): string {
  const label = kind === "steer" ? "Steer" : "Follow-up";
  return isPiTuiSession(session)
    ? `${label} requires an active streaming terminal turn`
    : `${label} requires an active streaming turn`;
}

function attachmentWorkspaceErrorMessage(session: Session): string {
  return isPiTuiSession(session)
    ? "Attachments require a workspace-backed pi-tui session"
    : "Attachments require a workspace-backed session";
}

export type SdkImageInput = { type: "image"; data: string; mimeType: string };
export type StreamingInputKind = "steer" | "follow_up";

export interface SessionInputDispatchResult {
  duplicate: boolean;
}

type EnqueueQueuedMessage = (
  key: string,
  kind: "steer" | "follow_up",
  message: string,
  attachments?: ChatAttachmentRef[],
  idHint?: string,
  sdkMessage?: string,
  sdkImages?: SdkImageInput[],
) => void;

function requireAcceptedTurn(turn: { clientTurnId?: string; duplicate: boolean } | undefined): {
  clientTurnId?: string;
  duplicate: boolean;
} {
  if (!turn) throw new Error("Runtime command completed without accepting prompt preflight");
  return turn;
}

function isPromiseLike(value: void | Promise<unknown>): value is Promise<unknown> {
  return Boolean(
    value && typeof value === "object" && typeof (value as { then?: unknown }).then === "function",
  );
}

export interface SessionInputCoordinatorDeps {
  config: ServerConfig;
  getActiveSession: (key: string) => SessionInputSessionState | undefined;
  turnCoordinator: Pick<
    SessionTurnCoordinator,
    "beginTurnIntent" | "isDuplicateTurnIntent" | "markTurnDispatched"
  >;
  sendCommand: (
    key: string,
    command: Record<string, unknown>,
    permit?: SessionRuntimeTransactionPermit,
    onPreflightAccepted?: () => void,
  ) => void | Promise<unknown>;
  uploadStoreConfig?: UploadStoreConfigResolved;
  onCommandResult?: (
    key: string,
    command: Record<string, unknown>,
    data: unknown,
  ) => void | Promise<void>;
  enqueueQueuedMessage?: EnqueueQueuedMessage;
  resolveWorkspaceRoot?: (session: Session) => string | null;
  onFirstMessage?: (session: Session) => void;
  assertModelTurnAdmissionAllowed?: (key: string) => void;
  resourceUsage?: Pick<ResourceUsageService, "captureAcceptedPrompt">;
}

export class SessionInputCoordinator {
  private readonly uploadStoreConfig: UploadStoreConfigResolved;
  private readonly inputAdmissionTails = new WeakMap<SessionInputSessionState, Promise<void>>();

  constructor(private readonly deps: SessionInputCoordinatorDeps) {
    this.uploadStoreConfig = deps.uploadStoreConfig ?? resolveUploadStoreConfig(deps.config);
  }

  private isRuntimeBusy(active: SessionInputSessionState): boolean {
    return (
      active.session.status === "busy" ||
      active.sdkBackend?.isStreaming === true ||
      active.sdkBackend?.isCompacting === true
    );
  }

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
    if (!workspaceRoot) {
      throw new Error(attachmentWorkspaceErrorMessage(active.session));
    }

    const materialized = await materializeChatAttachments({
      workspaceRoot,
      workspaceId: active.session.workspaceId,
      sessionId: active.session.id,
      turnId: opts.clientTurnId ?? opts.requestId,
      message,
      attachments: opts.attachments,
      maxTurnBytes: this.uploadStoreConfig.maxTurnBytes,
      uploadStore: this.uploadStoreConfig,
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
    if (!active) throw new Error(`Session not active: ${key}`);
    return this.withSerializedModelTurnAdmission(key, active, "prompt", (permit) =>
      this.sendPromptAdmitted(key, active, message, opts, permit),
    );
  }

  private async sendPromptAdmitted(
    key: string,
    active: SessionInputSessionState,
    message: string,
    opts:
      | {
          attachments?: ChatAttachmentRef[];
          streamingBehavior?: "steer" | "followUp";
          clientTurnId?: string;
          requestId?: string;
          timestamp?: number;
        }
      | undefined,
    permit: SessionRuntimeTransactionPermit | undefined,
  ): Promise<SessionInputDispatchResult> {
    if (this.deps.getActiveSession(key) !== active) {
      throw new Error(`Session not active: ${key}`);
    }

    const turnPayload = {
      message,
      attachments: opts?.attachments ?? [],
      streamingBehavior: opts?.streamingBehavior,
    };

    const runtimeBusy = this.isRuntimeBusy(active);

    if (
      runtimeBusy &&
      !opts?.streamingBehavior &&
      !this.deps.turnCoordinator.isDuplicateTurnIntent(
        active,
        "prompt",
        opts?.clientTurnId,
        turnPayload,
      )
    ) {
      throw new Error(promptBusyErrorMessage(active.session));
    }

    if (
      this.deps.turnCoordinator.isDuplicateTurnIntent(
        active,
        "prompt",
        opts?.clientTurnId,
        turnPayload,
      )
    ) {
      this.deps.turnCoordinator.beginTurnIntent(
        key,
        active,
        "prompt",
        turnPayload,
        opts?.clientTurnId,
        opts?.requestId,
      );
      return { duplicate: true };
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = prepared.images;
    const dispatchMessage = prepared.message;
    const actionId = opts?.clientTurnId ?? opts?.requestId;
    let acceptedTurn: { clientTurnId?: string; duplicate: boolean } | undefined;
    let turnDispatched = false;
    const acceptPreflight = (): void => {
      if (acceptedTurn) return;
      this.assertPreflightOwnerActive(key, active);
      acceptedTurn = this.deps.turnCoordinator.beginTurnIntent(
        key,
        active,
        "prompt",
        turnPayload,
        opts?.clientTurnId,
        opts?.requestId,
      );
      if (acceptedTurn.duplicate) {
        throw new Error("Prompt turn became duplicate during serialized preflight admission");
      }

      this.captureAcceptedPromptUsage(active, message, actionId, opts?.timestamp ?? Date.now());
      if (shouldRecordPromptLocally(active.session)) {
        const capturedFirst = appendSessionMessage(active.session, {
          role: "user",
          content: dispatchMessage,
          timestamp: opts?.timestamp ?? Date.now(),
        });

        if (capturedFirst) {
          this.deps.onFirstMessage?.(active.session);
        }
      }
    };
    const dispatchAcceptedTurn = (): { clientTurnId?: string; duplicate: boolean } => {
      const turn = requireAcceptedTurn(acceptedTurn);
      if (!turnDispatched) {
        turnDispatched = true;
        this.deps.turnCoordinator.markTurnDispatched(key, active, "prompt", turn, opts?.requestId);
      }
      return turn;
    };

    const cmd: Record<string, unknown> = {
      type: "prompt",
      message: dispatchMessage,
      ...(opts?.requestId ? { requestId: opts.requestId } : {}),
      ...(opts?.clientTurnId ? { clientTurnId: opts.clientTurnId } : {}),
    };

    // SDK image format: {type:"image", data:"base64...", mimeType:"image/png"}
    if (dispatchImages.length) {
      cmd.images = dispatchImages;
    }

    // If agent is busy, add streaming behavior
    if (runtimeBusy && opts?.streamingBehavior) {
      cmd.streamingBehavior = opts.streamingBehavior;
    }

    log.info("session_input.prompt_sent", {
      sessionId: active.session.id,
      runtime: runtimeLogTag(active.session),
      status: active.session.status,
      requestId: opts?.requestId,
      clientTurnId: opts?.clientTurnId,
      chars: dispatchMessage.length,
      imageCount: dispatchImages.length,
      attachmentCount: opts?.attachments?.length ?? 0,
      streamingBehavior: cmd.streamingBehavior as string | undefined,
      recordPromptLocally: shouldRecordPromptLocally(active.session),
    });

    const commandResult = this.deps.sendCommand(key, cmd, permit, () => {
      acceptPreflight();
      // Pi can synchronously emit agent_start immediately after preflight.
      dispatchAcceptedTurn();
    });
    // Promise-returning runtimes resolve only after authoritative preflight acceptance.
    // Sync managed sendCommand still runs onPreflightAccepted first via the callback above.
    const data = isPromiseLike(commandResult) ? await commandResult : commandResult;
    acceptPreflight();
    if (this.deps.onCommandResult) {
      await this.deps.onCommandResult(key, cmd, data);
    }
    const dispatchedTurn = dispatchAcceptedTurn();

    if (runtimeBusy && opts?.streamingBehavior) {
      const kind = opts.streamingBehavior === "steer" ? "steer" : "follow_up";
      this.deps.enqueueQueuedMessage?.(
        key,
        kind,
        message,
        opts.attachments,
        dispatchedTurn.clientTurnId,
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
    if (!active) throw new Error(`Session not active: ${key}`);
    return this.withSerializedModelTurnAdmission(key, active, kind, (permit) =>
      this.sendStreamingInputAdmitted(key, active, kind, message, opts, permit),
    );
  }

  private async sendStreamingInputAdmitted(
    key: string,
    active: SessionInputSessionState,
    kind: StreamingInputKind,
    message: string,
    opts:
      | {
          attachments?: ChatAttachmentRef[];
          clientTurnId?: string;
          requestId?: string;
        }
      | undefined,
    permit: SessionRuntimeTransactionPermit | undefined,
  ): Promise<SessionInputDispatchResult> {
    if (this.deps.getActiveSession(key) !== active) {
      throw new Error(`Session not active: ${key}`);
    }

    if (!this.isRuntimeBusy(active)) {
      throw new Error(streamingInputBusyErrorMessage(active.session, kind));
    }

    const turnPayload = {
      message,
      attachments: opts?.attachments ?? [],
    };
    if (
      this.deps.turnCoordinator.isDuplicateTurnIntent(active, kind, opts?.clientTurnId, turnPayload)
    ) {
      this.deps.turnCoordinator.beginTurnIntent(
        key,
        active,
        kind,
        turnPayload,
        opts?.clientTurnId,
        opts?.requestId,
      );
      return { duplicate: true };
    }

    const prepared = await this.prepareMessageWithAttachments(active, message, {
      attachments: opts?.attachments,
      clientTurnId: opts?.clientTurnId,
      requestId: opts?.requestId,
    });
    const dispatchImages = prepared.images;
    const dispatchMessage = prepared.message;
    const actionId = opts?.clientTurnId ?? opts?.requestId;
    let acceptedTurn: { clientTurnId?: string; duplicate: boolean } | undefined;
    let turnDispatched = false;
    const acceptPreflight = (): void => {
      if (acceptedTurn) return;
      this.assertPreflightOwnerActive(key, active);
      acceptedTurn = this.deps.turnCoordinator.beginTurnIntent(
        key,
        active,
        kind,
        turnPayload,
        opts?.clientTurnId,
        opts?.requestId,
      );
      if (acceptedTurn.duplicate) {
        throw new Error("Streaming turn became duplicate during serialized preflight admission");
      }
      this.captureAcceptedPromptUsage(active, message, actionId, Date.now());
    };
    const dispatchAcceptedTurn = (): { clientTurnId?: string; duplicate: boolean } => {
      const turn = requireAcceptedTurn(acceptedTurn);
      if (!turnDispatched) {
        turnDispatched = true;
        this.deps.turnCoordinator.markTurnDispatched(key, active, kind, turn, opts?.requestId);
      }
      return turn;
    };

    const cmd: Record<string, unknown> = {
      type: kind,
      message: dispatchMessage,
      ...(opts?.requestId ? { requestId: opts.requestId } : {}),
      ...(opts?.clientTurnId ? { clientTurnId: opts.clientTurnId } : {}),
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
      clientTurnId: opts?.clientTurnId,
      chars: dispatchMessage.length,
      imageCount: dispatchImages.length,
      attachmentCount: opts?.attachments?.length ?? 0,
    });

    const commandResult = this.deps.sendCommand(key, cmd, permit, () => {
      acceptPreflight();
      dispatchAcceptedTurn();
    });
    const data = isPromiseLike(commandResult) ? await commandResult : commandResult;
    acceptPreflight();
    if (this.deps.onCommandResult) {
      await this.deps.onCommandResult(key, cmd, data);
    }
    const dispatchedTurn = dispatchAcceptedTurn();
    this.deps.enqueueQueuedMessage?.(
      key,
      kind,
      message,
      opts?.attachments,
      dispatchedTurn.clientTurnId,
      dispatchMessage,
      dispatchImages,
    );

    return { duplicate: false };
  }

  private captureAcceptedPromptUsage(
    active: SessionInputSessionState,
    message: string,
    producerId: string | undefined,
    occurredAt: number,
  ): void {
    try {
      const priorEntryIds = active.sdkBackend?.resourceUsageEntryIds?.();
      const marker = this.deps.resourceUsage?.captureAcceptedPrompt({
        session: active.session,
        runtime: active.sdkBackend ? "oppi" : "pi-tui",
        evidence: active.sdkBackend?.resourceUsagePromptEvidence?.(message),
        producerId,
        occurredAt,
      });
      active.sdkBackend?.appendResourceUsageHistoryMarker?.(marker, priorEntryIds);
    } catch (error) {
      // Accepted input must proceed even when measurement is unavailable.
      log.warn("session_input.resource_usage_capture_failed", {
        sessionId: active.session.id,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private assertPreflightOwnerActive(key: string, active: SessionInputSessionState): void {
    if (active.sdkBackend?.isDisposed) throw new Error("Session backend is disposed");
    if (this.deps.getActiveSession(key) !== active) throw new Error(`Session not active: ${key}`);
  }

  private async withSerializedModelTurnAdmission<T>(
    key: string,
    active: SessionInputSessionState,
    commandType: string,
    operation: (permit: SessionRuntimeTransactionPermit | undefined) => Promise<T>,
  ): Promise<T> {
    const previous = this.inputAdmissionTails.get(active) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => {
      release = resolve;
    });
    const tail = previous.then(() => current);
    this.inputAdmissionTails.set(active, tail);

    await previous;
    try {
      this.deps.assertModelTurnAdmissionAllowed?.(key);
      if (active.sdkBackend?.withModelTurnAdmission) {
        return await active.sdkBackend.withModelTurnAdmission(commandType, (permit) => {
          this.deps.assertModelTurnAdmissionAllowed?.(key);
          return operation(permit);
        });
      }
      return await operation(undefined);
    } finally {
      release();
      if (this.inputAdmissionTails.get(active) === tail) {
        this.inputAdmissionTails.delete(active);
      }
    }
  }
}
