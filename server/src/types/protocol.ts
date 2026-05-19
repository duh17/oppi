import type { GitStatus } from "./git.js";
import type { Session, SessionSummary } from "./session.js";
import type { StyledSegment } from "./shared.js";

// ─── WebSocket Messages ───

export interface ImageAttachment {
  data: string; // base64
  mimeType: string; // image/jpeg, image/png, etc.
}

export type AttachmentKind = "image" | "text" | "pdf" | "audio" | "video" | "archive" | "unknown";

export type AttachmentSource = "upload" | "workspace";

export interface ChatAttachmentRef {
  type: "attachment";
  id: string;
  source: AttachmentSource;
  name: string;
  mimeType: string;
  sizeBytes: number;
  sha256?: string;
  kind?: AttachmentKind;
  workspacePath?: string;
}

export type MessageQueueKind = "steer" | "follow_up";

export interface MessageQueueItem {
  id: string;
  message: string;
  images?: ImageAttachment[];
  attachments?: ChatAttachmentRef[];
  createdAt: number;
}

export interface MessageQueueState {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
}

export interface MessageQueueDraftItem {
  id?: string;
  message: string;
  images?: ImageAttachment[];
  attachments?: ChatAttachmentRef[];
  createdAt?: number;
}

export interface ShareSessionRedactionPolicy {
  secrets?: boolean;
  emails?: boolean;
  phones?: boolean;
  userPaths?: boolean;
  ipAddresses?: boolean;
  jwtAndBearer?: boolean;
  namesHeuristic?: boolean;
  skills?: boolean;
}

export type TurnCommand = "prompt" | "steer" | "follow_up";
export type TurnAckStage = "accepted" | "dispatched" | "started";

/**
 * Client → Server messages.
 *
 * All messages may include an optional `requestId` for response correlation.
 * Commands return a `command_result` with the same requestId.
 */
export type ClientMessage = // ── Prompting ──
  (
    | {
        type: "prompt";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        streamingBehavior?: "steer" | "followUp";
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "steer";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "follow_up";
        message: string;
        images?: ImageAttachment[];
        attachments?: ChatAttachmentRef[];
        requestId?: string;
        clientTurnId?: string;
      }
    | { type: "abort"; requestId?: string }
    | { type: "stop"; requestId?: string } // Abort current turn (alias for mobile UX)
    | { type: "stop_session"; requestId?: string } // Kill session process entirely
    // ── State ──
    | { type: "get_state"; requestId?: string }
    | { type: "get_messages"; requestId?: string }
    | { type: "get_session_stats"; requestId?: string }
    // ── Message queue ──
    | { type: "get_queue"; requestId?: string }
    | {
        type: "set_queue";
        baseVersion: number;
        steering: MessageQueueDraftItem[];
        followUp: MessageQueueDraftItem[];
        requestId?: string;
      }
    // ── Model ──
    | { type: "set_model"; provider: string; modelId: string; requestId?: string }
    | { type: "cycle_model"; requestId?: string }
    | { type: "get_available_models"; requestId?: string }
    // ── Thinking ──
    | {
        type: "set_thinking_level";
        level: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
        requestId?: string;
      }
    | { type: "cycle_thinking_level"; requestId?: string }
    // ── Session ──
    | { type: "reload"; requestId?: string }
    | { type: "new_session"; requestId?: string }
    | { type: "set_session_name"; name: string; requestId?: string }
    | { type: "compact"; customInstructions?: string; requestId?: string }
    | { type: "set_auto_compaction"; enabled: boolean; requestId?: string }
    | { type: "fork"; entryId: string; requestId?: string }
    | { type: "get_fork_messages"; requestId?: string }
    | {
        type: "get_session_tree";
        filterMode?: "default" | "no-tools" | "user-only" | "labeled-only" | "all";
        requestId?: string;
      }
    | {
        type: "navigate_tree";
        targetId: string;
        summarize?: boolean;
        customInstructions?: string;
        replaceInstructions?: boolean;
        label?: string;
        requestId?: string;
      }
    | { type: "switch_session"; sessionPath: string; requestId?: string }
    // ── Queue modes ──
    | { type: "set_steering_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    | { type: "set_follow_up_mode"; mode: "all" | "one-at-a-time"; requestId?: string }
    // ── Retry ──
    | { type: "set_auto_retry"; enabled: boolean; requestId?: string }
    | { type: "abort_retry"; requestId?: string }
    // ── Bash ──
    | { type: "abort_bash"; requestId?: string }
    // ── Commands ──
    | { type: "get_commands"; requestId?: string }
    | {
        type: "share_session";
        action?: "prepare" | "publish";
        redactionPolicy?: ShareSessionRedactionPolicy;
        requestId?: string;
      }
    // ── File suggestions ──
    | { type: "get_file_suggestions"; query: string; requestId?: string }
    // ── Permission gate ──
    | {
        type: "permission_response";
        id: string;
        action: "allow" | "deny";
        scope?: "once" | "session" | "global";
        /** Optional TTL for learned rule persistence (milliseconds). Ignored for scope="once". */
        expiresInMs?: number;
        requestId?: string;
      }
    // ── Extension UI dialog responses ──
    | {
        type: "extension_ui_response";
        id: string;
        value?: string;
        confirmed?: boolean;
        cancelled?: boolean;
        requestId?: string;
      }
    // ── Dictation (session audio stream) ──
    | { type: "dictation_start" }
    | { type: "dictation_stop" }
    | { type: "dictation_cancel" }
  ) & {
    /**
     * Optional target session for split stream routing.
     * Focused session streams bind this in the URL.
     */
    sessionId?: string;
  };

/** Structured option for the ask extension UI. */
export interface AskOption {
  value: string;
  label: string;
  description?: string;
}

/** A single question in an ask request, with its own options and selection mode. */
export interface AskQuestion {
  id: string;
  question: string;
  options: AskOption[];
  multiSelect?: boolean;
}

// Server → Client
export type ServerMessage = // ── Connection ──
  (
    | { type: "connected"; session: Session; currentSeq?: number }
    | { type: "stream_connected"; userName: string; serverDictationAvailable: boolean }
    | { type: "state"; session: Session }
    | { type: "session_summary"; summary: SessionSummary }
    | { type: "session_ended"; reason: string }
    | { type: "session_deleted"; sessionId: string }
    | { type: "stop_requested"; source: "user" | "timeout" | "server"; reason?: string }
    | { type: "stop_confirmed"; source: "user" | "timeout" | "server"; reason?: string }
    | { type: "stop_failed"; source: "user" | "timeout" | "server"; reason: string }
    | { type: "error"; error: string; code?: string; fatal?: boolean }
    // ── Agent lifecycle ──
    | { type: "agent_start" }
    | { type: "agent_end" }
    | { type: "message_end"; role: "user" | "assistant"; content: string }
    // ── Streaming ──
    | { type: "text_delta"; delta: string }
    | { type: "thinking_delta"; delta: string }
    | {
        type: "audio_stream";
        kind: "audio-stream";
        id: string;
        event: "metadata" | "chunk" | "done" | "error";
        mimeType: "audio/wav" | "audio/pcm; codecs=s16le";
        sampleRate?: number;
        channels?: number;
        chunkIndex?: number;
        audioBase64?: string;
        text?: string;
        durationSeconds?: number;
        metrics?: Record<string, unknown>;
        playbackBehavior?: "tapToPlay" | "playNow";
      }
    // ── Tool execution ──
    | {
        type: "tool_start";
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_update";
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_output";
        output: string;
        isError?: boolean;
        toolCallId?: string;
        /** "append" (default) or "replace" — replace means output is a bounded tail preview. */
        mode?: "append" | "replace";
        /** True when the server truncated output to a tail preview. */
        truncated?: boolean;
        /** Total bytes of full output on the server (hint for UI). */
        totalBytes?: number;
        /** Optional structured details for in-flight tool presentation updates. */
        details?: unknown;
      }
    | {
        type: "tool_end";
        tool: string;
        toolCallId?: string;
        details?: unknown;
        isError?: boolean;
        resultSegments?: StyledSegment[];
      }
    // ── Message queue ──
    | { type: "queue_state"; queue: MessageQueueState }
    | {
        type: "queue_item_started";
        kind: MessageQueueKind;
        item: MessageQueueItem;
        queueVersion: number;
      }
    // ── Turn delivery acknowledgements (idempotent send contract) ──
    | {
        type: "turn_ack";
        command: TurnCommand;
        clientTurnId: string;
        stage: TurnAckStage;
        requestId?: string;
        duplicate?: boolean;
      }
    // ── Command responses (keyed by requestId for correlation) ──
    // Lifecycle commands such as abort/stop report request acceptance here.
    // Clients must wait for stop_confirmed/stop_failed to observe settled stop state.
    | {
        type: "command_result";
        command: string;
        requestId?: string;
        success: boolean;
        data?: unknown;
        error?: string;
      }
    // ── Compaction ──
    | { type: "compaction_start"; reason: string }
    | {
        type: "compaction_end";
        aborted: boolean;
        willRetry: boolean;
        summary?: string;
        tokensBefore?: number;
      }
    // ── Retry ──
    | {
        type: "retry_start";
        attempt: number;
        maxAttempts: number;
        delayMs: number;
        errorMessage: string;
      }
    | { type: "retry_end"; success: boolean; attempt: number; finalError?: string }
    // ── Permission gate ──
    | {
        type: "permission_request";
        id: string;
        sessionId: string;
        workspaceId: string;
        tool: string;
        input: Record<string, unknown>;
        displaySummary: string;
        reason: string;
        timeoutAt: number;
        expires?: boolean;
      }
    | { type: "permission_expired"; id: string; reason: string }
    | { type: "permission_cancelled"; id: string }
    | { type: "permission_resolved"; id: string; action: "allow" | "deny" }
    // ── Extension UI forwarding ──
    | {
        type: "extension_ui_request";
        id: string;
        sessionId: string;
        method: string;
        title?: string;
        options?: string[];
        message?: string;
        placeholder?: string;
        prefill?: string;
        timeout?: number;
        timeoutAt?: number;
        // ── Ask extension fields (method: "ask") ──
        questions?: AskQuestion[];
        allowCustom?: boolean;
      }
    | {
        type: "extension_ui_notification";
        method: string;
        message?: string;
        notifyType?: string;
        statusKey?: string;
        statusText?: string;
        title?: string;
        text?: string;
        widgetKey?: string;
        widgetLines?: string[];
        widgetPlacement?: string;
      }
    // ── Git status (workspace-level, pushed after file-mutating tool calls) ──
    | {
        type: "git_status";
        workspaceId: string;
        status: GitStatus;
      }
    // ── Dictation ──
    | {
        type: "dictation_ready";
        sttProvider?: string;
        sttModel?: string;
      }
    | {
        type: "dictation_result";
        text: string;
        committedText?: string;
        activeText?: string;
        snap?: boolean;
      }
    | {
        type: "dictation_final";
        text: string;
        committedText?: string;
        activeText?: string;
      }
    | { type: "dictation_error"; error: string; fatal: boolean }
  ) & {
    seq?: number;
    /**
     * Session scope for split stream routing.
     * Bound session streams bind this in the URL but may still echo it on frames.
     */
    sessionId?: string;
  };
