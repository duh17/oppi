import type {
  NestedToolCallRecord as PiNestedToolCallRecord,
  NestedToolCalls as PiNestedToolCalls,
} from "@earendil-works/pi-ai";
import type { GitStatus } from "./git.js";
import type { Session, SessionSummary } from "./session.js";
import type { StyledSegment } from "./shared.js";
import type { ThinkingLevel } from "../thinking-levels.js";

/** Producer-resolved identity; raw tool names remain separate. */
export interface ToolDisplay {
  title: string;
  group?: string;
  /** Preserve an actual provider title verbatim rather than humanizing a name. */
  verbatim?: boolean;
}

export interface NestedToolCallRecord extends Omit<PiNestedToolCallRecord, "status"> {
  /** Future Pi statuses remain inspectable rather than dropping the call. */
  status: string;
  display?: ToolDisplay;
}
export interface NestedToolCalls extends Omit<PiNestedToolCalls, "calls"> {
  calls: NestedToolCallRecord[];
}

/** How clients present a tool call's arguments. */
export interface ToolInputPresentation {
  /** Argument field name → semantic role and source language. */
  fields: Record<
    string,
    {
      role: "code" | "command" | "filePath" | "fileContent" | "edits" | "lineOffset" | "lineLimit";
      language?: string;
    }
  >;
}

/** Result semantics, not a requested viewer or layout. */
export interface ToolOutputPresentation {
  kind: "terminal" | "structured" | "fileContent" | "diffOfEdits" | "interactive";
  /** Requested bytes are input, never evidence of the resulting file. */
  provenance?: "requested" | "result";
  /** Registry-declared session-setting effect, never inferred from result details. */
  settingEffect?: "voiceReplyMode";
}

/**
 * Position of a terminal-kind `tool_output` chunk in the call's append-only raw byte log.
 * `epoch >= 1` identifies one log; a larger epoch means "discard prior state" and restarts
 * at offset 0. `offset`/`bytes` count raw bytes (never UTF-16 units of `output`); the next
 * chunk of an epoch starts at `offset + bytes`. `bytes: 0` is only the attach ready marker.
 */
export interface ToolOutputStreamPosition {
  epoch: number;
  offset: number;
  bytes: number;
}

/** Final length of a terminal-kind call's byte log (final epoch only). */
export interface ToolEndOutputStream {
  epoch: number;
  totalBytes: number;
}

/** Pi result text completeness; source uses toolCallId, never a private path.
 * The sidecar may become unavailable when the session stops. */
export interface ToolOutputAvailability {
  complete: boolean;
  totalBytes?: number;
  source?: "sidecar";
}

// ─── WebSocket Messages ───

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

export interface MessageQueuePayload {
  message: string;
  attachments?: ChatAttachmentRef[];
}

export interface MessageQueueItem extends MessageQueuePayload {
  id: string;
  createdAt: number;
}

export interface MessageQueueState {
  version: number;
  steering: MessageQueueItem[];
  followUp: MessageQueueItem[];
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
        attachments?: ChatAttachmentRef[];
        streamingBehavior?: "steer" | "followUp";
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "steer";
        message: string;
        attachments?: ChatAttachmentRef[];
        requestId?: string;
        clientTurnId?: string;
      }
    | {
        type: "follow_up";
        message: string;
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
    | { type: "remove_queued_message"; itemId: string; requestId?: string }
    | { type: "take_queue"; requestId?: string }
    // ── Model ──
    | {
        type: "set_model";
        provider: string;
        modelId: string;
        persist?: boolean;
        requestId?: string;
      }
    | { type: "cycle_model"; requestId?: string }
    // ── Thinking ──
    | {
        type: "set_thinking_level";
        level: ThinkingLevel;
        persist?: boolean;
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
    // ── Extension UI dialog responses ──
    | {
        type: "extension_ui_response";
        id: string;
        value?: string;
        confirmed?: boolean;
        cancelled?: boolean;
        requestId?: string;
      }
    // ── Dictation (dedicated ASR stream) ──
    | { type: "dictation_start"; contextualStrings?: string[] }
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

export interface ExtensionUIAccessibility {
  label?: string;
  value?: string;
  hint?: string;
}

export interface ExtensionUITextSpan {
  text: string;
  role?: "primary" | "secondary" | "muted" | "accent" | "success" | "warning" | "danger" | "code";
  traits?: Array<"bold" | "italic" | "monospaced" | "strikethrough" | "underline">;
  link?: string;
}

export interface ExtensionUIActivityRow {
  id: string;
  title: string;
  subtitle?: string;
  detail?: string;
  state?: "queued" | "running" | "success" | "warning" | "error" | "inactive";
  progress?: number;
  link?: string;
  children?: ExtensionUIActivityRow[];
  /** Disclosure content. Tapping the row shows or hides it; clients render it only while shown. */
  blocks?: ExtensionUINativeBlock[];
}

export type ExtensionUINativeBlock =
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "text";
      spans: ExtensionUITextSpan[];
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "markdown";
      markdown: string;
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "section";
      title?: string;
      subtitle?: string;
      blocks: ExtensionUINativeBlock[];
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "activityList";
      rows: ExtensionUIActivityRow[];
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "progress";
      label?: string;
      value?: number;
      indeterminate?: boolean;
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "terminal";
      /** Styled lines. Required unless `text` is present. */
      lines?: ExtensionUITextSpan[][];
      /** Raw terminal output (ANSI SGR, CR, cursor motion). Clients resolve it like bash output. */
      text?: string;
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "code";
      language?: string;
      text: string;
    })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & { type: "divider" })
  | ({ id?: string; accessibility?: ExtensionUIAccessibility } & {
      type: "spacer";
      size?: "small" | "medium" | "large";
    });

export interface ExtensionUINativePresentation {
  style: "surfacePanel";
  title?: string;
  subtitle?: string;
}

export interface ExtensionUINativeFallback {
  text?: string;
  lines?: string[];
}

export interface ExtensionUINativeSurface {
  version: 1;
  id: string;
  source: "widget";
  presentation: ExtensionUINativePresentation;
  blocks: ExtensionUINativeBlock[];
  fallback?: ExtensionUINativeFallback;
}

export type ExtensionUINotifyType = "info" | "warning" | "error";
export type ExtensionUIWidgetPlacement = "aboveEditor" | "belowEditor";

export interface ExtensionUIWorkingIndicator {
  frames?: string[];
  intervalMs?: number;
}

// ─── Global App Event Stream Messages ───

export type AppEventSessionLifecycleType =
  | "session_created"
  | "session_imported"
  | "session_discovered";

export interface AppEventBase {
  type: string;
  emittedAt: number;
}

export interface AppEventSessionBase extends AppEventBase {
  sessionId: string;
  workspaceId?: string;
}

export type AppEventMessage =
  | {
      type: "app_events_connected";
      serverTime: number;
      snapshotRequired: true;
    }
  | (AppEventSessionBase & {
      type: AppEventSessionLifecycleType;
      summary: SessionSummary;
    })
  | (AppEventSessionBase & {
      type: "session_summary";
      summary: SessionSummary;
    })
  | (AppEventSessionBase & {
      type: "session_deleted";
    })
  | (AppEventSessionBase & {
      type: "session_ended";
      reason: string;
    })
  | (AppEventSessionBase & {
      type: "stop_requested" | "stop_confirmed" | "stop_failed";
      source?: string;
      reason?: string;
    })
  | (AppEventSessionBase & {
      type: "session_error";
      message: string;
      code?: string;
      fatal?: boolean;
    })
  | (AppEventSessionBase & {
      type: "extension_ui_request";
      id: string;
      method: string;
      title?: string;
      options?: string[];
      message?: string;
      placeholder?: string;
      prefill?: string;
      timeout?: number;
      timeoutAt?: number;
      questions?: AskQuestion[];
      allowCustom?: boolean;
      extensionScopeId?: string;
      extensionDisplayName?: string;
    })
  | (AppEventSessionBase & {
      type: "extension_ui_notification";
      method: string;
      message?: string;
      notifyType?: ExtensionUINotifyType;
      statusKey?: string;
      statusText?: string;
      title?: string;
      text?: string;
      widgetKey?: string;
      widgetLines?: string[];
      widgetPlacement?: ExtensionUIWidgetPlacement;
      extensionScopeId?: string;
      extensionDisplayName?: string;
      nativeSurface?: ExtensionUINativeSurface;
      workingIndicator?: ExtensionUIWorkingIndicator;
      workingVisible?: boolean;
      hiddenThinkingLabel?: string;
      toolsExpanded?: boolean;
    })
  | (AppEventSessionBase & {
      type: "extension_ui_settled";
      id: string;
    })
  | (AppEventBase & {
      type: "workspace_git_changed";
      workspaceId: string;
      worktreeId?: string;
      sessionId?: string;
      reason?: string;
    });

export type AssistantMessageContentPart =
  | { kind: "text" | "thinking"; content: string; contentIndex: number; id?: string }
  | { kind: "tool"; contentIndex: number; toolCallId?: string; id?: string }
  | { kind: "boundary"; contentIndex: number; id?: string };

// Server → Client
export type ServerMessage = // ── Connection ──
  (
    | { type: "connected"; session: Session; currentSeq?: number; runtimeEpoch?: string }
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
    | { type: "agent_settled" }
    | {
        type: "message_end";
        role: "user" | "assistant";
        /** Complete text projection retained for older clients. */
        content: string;
        /** Pi SessionEntry.id once the message is persisted. */
        entryId?: string;
        /** Ordered assistant structure for clients that can render split content. */
        assistantContent?: AssistantMessageContentPart[];
      }
    | {
        /** Experimental live-only projection, emitted only while Pi's showCacheMissNotices is enabled. */
        type: "cache_miss";
        id: string;
        message: string;
      }
    | {
        /** live user notice, not transcript, not model context, not cache billing. */
        type: "notice";
        id: string;
        message: string;
      }
    // ── Streaming ──
    | { type: "text_delta"; delta: string; contentIndex?: number }
    | { type: "thinking_delta"; delta: string; contentIndex?: number }
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
        parentToolCallId?: string;
        outputPresentation?: ToolOutputPresentation;
        inputPresentation?: ToolInputPresentation;
        display?: ToolDisplay;
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_update";
        parentToolCallId?: string;
        outputPresentation?: ToolOutputPresentation;
        inputPresentation?: ToolInputPresentation;
        display?: ToolDisplay;
        tool: string;
        args: Record<string, unknown>;
        toolCallId?: string;
        callSegments?: StyledSegment[];
      }
    | {
        type: "tool_output";
        parentToolCallId?: string;
        output: string;
        outputAvailability?: ToolOutputAvailability;
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
        /**
         * Terminal-kind only: `output` is the UTF-8 decoding of exactly `bytes` raw VT bytes
         * (unstripped, codepoint-complete) at `offset`. Such chunks never carry `mode`,
         * `truncated` or `totalBytes`.
         */
        outputStream?: ToolOutputStreamPosition;
      }
    | {
        type: "tool_end";
        parentToolCallId?: string;
        outputAvailability?: ToolOutputAvailability;
        outputPresentation?: ToolOutputPresentation;
        nestedCalls?: NestedToolCalls;
        tool: string;
        toolCallId?: string;
        details?: unknown;
        isError?: boolean;
        resultSegments?: StyledSegment[];
        /** Terminal-kind only: final length of the call's raw byte log. */
        outputStream?: ToolEndOutputStream;
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
        errorMessage?: string;
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
        extensionScopeId?: string;
        extensionDisplayName?: string;
      }
    | {
        type: "extension_ui_notification";
        method: string;
        message?: string;
        notifyType?: ExtensionUINotifyType;
        statusKey?: string;
        statusText?: string;
        title?: string;
        text?: string;
        widgetKey?: string;
        widgetLines?: string[];
        widgetPlacement?: ExtensionUIWidgetPlacement;
        extensionScopeId?: string;
        extensionDisplayName?: string;
        nativeSurface?: ExtensionUINativeSurface;
        workingIndicator?: ExtensionUIWorkingIndicator;
        workingVisible?: boolean;
        hiddenThinkingLabel?: string;
        toolsExpanded?: boolean;
      }
    | {
        type: "extension_ui_settled";
        id: string;
        sessionId: string;
      }
    // ── Git status (workspace/worktree-level, pushed after file-mutating tool calls) ──
    | {
        type: "git_status";
        workspaceId: string;
        worktreeId?: string;
        status: GitStatus;
      }
    // ── Dictation ──
    | {
        type: "dictation_ready";
        sttProvider?: string;
        sttModel?: string;
        contextApplied?: boolean;
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

// ── HTTP model catalog (GET /models) ──

export type ModelAuthKind = "subscription" | "local" | "apiKey";

/** Model row returned by GET /models. */
export interface ModelInfo {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
  authKind?: ModelAuthKind;
  thinkingLevels?: ThinkingLevel[];
  isDefault?: boolean;
}
