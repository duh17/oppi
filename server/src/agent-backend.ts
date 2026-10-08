import type {
  BranchSummaryEntry,
  CompactionResult,
  SessionStats,
} from "@earendil-works/pi-coding-agent";

import type { CacheMissModelPriceSource } from "./cache-miss.js";
import type { CanonicalSessionTree } from "./canonical-message.js";
import type { ExtensionUIResponsePayload } from "./extension-ui-contract.js";
import type { PiMessage, PiStateSnapshot } from "./pi-events.js";
import type { QueuedModelTurnBatch, SdkBackendDisposeResult } from "./sdk-backend.js";
import type { SessionRuntimeTransactionPermit } from "./session-runtime-transaction.js";
import type { SessionTreeManager } from "./session-tree.js";
import type { ThinkingLevel } from "./thinking-levels.js";
import type { LiveEntryRendererSet } from "./trace.js";
import type { ChatAttachmentRef, MessageQueueState, SessionPromptCacheWarmer } from "./types.js";

type BackendToolDefinition = { label?: string; namespace?: { name: string } };

/** Managed-session capabilities. No live Pi AgentSession escapes this seam. */
export interface AgentBackend {
  readonly isDisposed: boolean;
  readonly isStreaming: boolean;
  readonly isCompacting: boolean;
  readonly isRuntimeLifecycleTransactionExclusive: boolean;
  readonly isQueueReconciliationRequired: boolean;
  /** Native abort atomically withdraws its inbox; no host queue replacement. */
  readonly abortClearsQueuedModelTurns?: boolean;
  /** Idle edits stay queued. The next real admission places them; do not start a prompt here. */
  readonly retainsIdleQueueUntilAdmission?: boolean;
  /** Abort owns UI cancellation; don't answer the waiting tool just before stopping it. */
  readonly cancelsExtensionUIOnAbort?: boolean;
  /** History lives in a store, not a Pi session file, so share has no file to require. */
  readonly persistsWithoutSessionFile?: boolean;
  readonly showCacheMissNotices: boolean;
  readonly cacheMissModelPriceSource: CacheMissModelPriceSource;

  prompt(
    message: string,
    options?: {
      images?: Array<{ type: "image"; data: string; mimeType: string }>;
      streamingBehavior?: "steer" | "followUp";
      clientTurnId?: string;
      queueDisplay?: { message: string; attachments?: ChatAttachmentRef[] };
      onPreflightAccepted?: () => void;
    },
    permit?: SessionRuntimeTransactionPermit,
  ): Promise<void | { duplicate: true }>;
  abort(permit?: SessionRuntimeTransactionPermit): Promise<void>;
  abortBash(): void;
  dispose(permit?: SessionRuntimeTransactionPermit): Promise<SdkBackendDisposeResult>;
  captureEmergencyDisposalForStop(): (
    timeoutMs: number,
  ) => SdkBackendDisposeResult | Promise<SdkBackendDisposeResult>;
  /** Detach projection without cancelling recorded restart work, when supported. */
  detachForRestart?(): Promise<void>;
  withModelTurnAdmission<T>(
    commandType: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
  ): Promise<T>;
  withRuntimeLifecycleTransaction<T>(
    operationName: string,
    operation: (permit: SessionRuntimeTransactionPermit) => Promise<T>,
    options?: { allowDisposed?: boolean },
  ): Promise<T>;
  replaceQueuedModelTurns(
    batch: QueuedModelTurnBatch,
    rollback?: QueuedModelTurnBatch,
    permit?: SessionRuntimeTransactionPermit,
  ): Promise<void>;
  clearQueuedModelTurns(permit: SessionRuntimeTransactionPermit): void;
  nativeMessageQueue?(): Promise<MessageQueueState>;
  withdrawNativeQueue?(
    itemId: string | undefined,
    permit: SessionRuntimeTransactionPermit,
  ): Promise<MessageQueueState>;
  queuedMessages(): { steering: readonly string[]; followUp: readonly string[] };
  respondToExtensionUIRequest(response: ExtensionUIResponsePayload): boolean | Promise<boolean>;
  reloadResources(reloadRuntimeConfig?: () => void): Promise<{ success: true }>;
  setModel(
    modelId: string,
    options?: { persist?: boolean },
  ): Promise<{
    success: boolean;
    provider?: string;
    id?: string;
    name?: string;
    thinkingLevel?: string;
    error?: string;
  }>;
  cycleModel(
    direction?: "forward" | "backward",
  ): Promise<{ model: { provider: string; id: string }; thinkingLevel: ThinkingLevel } | undefined>;
  setThinkingLevel(level: ThinkingLevel, options?: { persist?: boolean }): void | Promise<void>;
  cycleThinkingLevel(): ThinkingLevel | undefined | Promise<ThinkingLevel | undefined>;
  setSessionName(name: string): void;
  getStateSnapshot(): PiStateSnapshot;
  getSessionStats():
    (SessionStats & Record<string, unknown>) | Promise<SessionStats & Record<string, unknown>>;
  messages(): PiMessage[];
  forkMessages():
    Array<{ entryId: string; text: string }> | Promise<Array<{ entryId: string; text: string }>>;
  sessionTree(): SessionTreeManager & CanonicalSessionTree;
  leafId(): string | null;
  toolDefinition(name: string): BackendToolDefinition | undefined;
  navigateTree(
    targetId: string,
    options?: {
      summarize?: boolean;
      customInstructions?: string;
      replaceInstructions?: boolean;
      label?: string;
    },
  ): Promise<{
    editorText?: string;
    cancelled: boolean;
    aborted?: boolean;
    summaryEntry?: BranchSummaryEntry;
  }>;
  commands(): {
    commands: Array<{
      name: string;
      description?: string;
      source: "builtin" | "extension" | "prompt" | "skill";
      location?: "user" | "project" | "path";
      path?: string;
    }>;
  };
  exportToHtml(outputPath: string): Promise<string>;
  compact(customInstructions?: string): Promise<CompactionResult>;
  setAutoCompactionEnabled(enabled: boolean): void;
  setSteeringMode(mode: "all" | "one-at-a-time"): void;
  setFollowUpMode(mode: "all" | "one-at-a-time"): void;
  setAutoRetryEnabled(enabled: boolean): void;
  abortRetry(): void | Promise<void>;
  getEntryRenderers(): LiveEntryRendererSet | undefined;
  appendAssistantMessage(content: string, fallbackModel?: string): void;
  promptCacheRuntime(): {
    warmer?: SessionPromptCacheWarmer;
    promptCache?: { short?: number; long?: number };
  };
}
