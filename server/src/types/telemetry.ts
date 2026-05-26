export function telemetryUploadsEnabledFromEnv(mode = process.env.OPPI_TELEMETRY_MODE): boolean {
  const raw = mode?.trim().toLowerCase() ?? "";
  if (!raw) {
    return true;
  }

  switch (raw) {
    case "internal":
    case "debug":
    case "test":
    case "qa":
    case "staging":
    case "dev":
    case "development":
    case "enabled":
    case "on":
    case "true":
    case "1":
      return true;
    case "public":
    case "release":
    case "prod":
    case "production":
    case "off":
    case "disabled":
    case "none":
    case "false":
    case "0":
      return false;
    default:
      return false;
  }
}

export interface MetricKitPayloadItem {
  /** "metric" (MXMetricPayload) or "diagnostic" (MXDiagnosticPayload). */
  kind: "metric" | "diagnostic";
  /** Window start of telemetry sample (ms since epoch). */
  windowStartMs: number;
  /** Window end of telemetry sample (ms since epoch). */
  windowEndMs: number;
  /** Low-cardinality summary suitable for dashboards/alerts. */
  summary: Record<string, string>;
  /** Sanitized raw payload JSON for later inspection/replay. */
  raw: Record<string, unknown> | string;
}

export interface MetricKitUploadRequest {
  generatedAt: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  payloads: MetricKitPayloadItem[];
}

export type ChatMetricUnit = "ms" | "count" | "ratio";

export interface ChatMetricDefinition {
  unit: ChatMetricUnit;
  description: string;
}

/**
 * Single source of truth for chat metric contracts.
 *
 * Add new metrics here first, then emit from clients and surface in dashboards.
 */
export const CHAT_METRIC_REGISTRY = {
  "chat.ttft_ms": {
    unit: "ms",
    description: "Time-to-first-token latency for a user turn.",
  },
  "chat.catchup_ms": {
    unit: "ms",
    description: "Catch-up replay latency when (re)subscribing to a session stream.",
  },
  "chat.catchup_ring_miss": {
    unit: "count",
    description: "Count of catch-up ring misses that required a fallback path.",
  },
  "chat.timeline_apply_ms": {
    unit: "ms",
    description: "Reducer apply latency (threshold-gated, only emitted when >= 4ms).",
  },
  "chat.timeline_layout_ms": {
    unit: "ms",
    description: "Timeline layout latency (threshold-gated, only emitted when >= 2ms).",
  },
  // Removed: chat.ws_decode_ms (high-volume noise, build 21)
  "chat.session_load_ms": {
    unit: "ms",
    description: "End-to-end session load latency from tap to content visible.",
  },
  "chat.jank_pct": {
    unit: "ratio",
    description: "Percentage of render cycles exceeding 16ms frame budget during streaming.",
  },
  "chat.timeline_hitch": {
    unit: "count",
    description: "Frame budget hitch detected during collection view apply cycle.",
  },
  "chat.coalescer_flush_events": {
    unit: "count",
    description: "Event count flushed per coalescer batch.",
  },
  "chat.coalescer_flush_bytes": {
    unit: "count",
    description: "Payload byte count flushed per coalescer batch.",
  },
  "chat.full_reload_ms": {
    unit: "ms",
    description: "Latency for full timeline reload fallback path.",
  },
  "chat.fresh_content_lag_ms": {
    unit: "ms",
    description: "Lag between new content arrival and visible timeline freshness.",
  },
  "chat.cache_load_ms": {
    unit: "ms",
    description: "Client-side cache load latency.",
  },
  "chat.reducer_load_ms": {
    unit: "ms",
    description: "Reducer reconstruction/load latency from cached state.",
  },
  "chat.ws_wait_for_connected_ms": {
    unit: "ms",
    description: "Client wait for the active session WebSocket to reach connected.",
  },
  "chat.command_send_ms": {
    unit: "ms",
    description: "Client command send path duration until WebSocket send returns.",
  },
  "chat.command_roundtrip_ms": {
    unit: "ms",
    description:
      "Client command request/response duration until correlated command_result resolves.",
  },
  "chat.command_resolve_lag_ms": {
    unit: "ms",
    description: "Client lag from command_result frame receipt to command waiter resolution.",
  },
  "chat.queue_sync_ms": {
    unit: "ms",
    description: "Latency for initial queue snapshot refresh (get_queue command).",
  },
  "chat.message_queue_ack_ms": {
    unit: "ms",
    description: "Latency from message queue send to server acknowledgement.",
  },
  "chat.message_queue_stale_drop": {
    unit: "count",
    description: "Messages dropped from queue due to stale session state.",
  },
  "chat.message_queue_start_miss": {
    unit: "count",
    description: "Queue messages sent before session start was confirmed.",
  },
  "chat.session_message_count": {
    unit: "count",
    description: "Per-session cumulative message count snapshot.",
  },
  "chat.session_input_tokens": {
    unit: "count",
    description: "Per-session cumulative input token count snapshot.",
  },
  "chat.session_output_tokens": {
    unit: "count",
    description: "Per-session cumulative output token count snapshot.",
  },
  // Removed: chat.session_total_tokens — 100% redundant (input + output)
  "chat.session_mutating_tool_calls": {
    unit: "count",
    description: "Per-session cumulative mutating tool call count snapshot.",
  },
  "chat.session_files_changed": {
    unit: "count",
    description: "Per-session cumulative unique changed file count snapshot.",
  },
  "chat.session_added_lines": {
    unit: "count",
    description: "Per-session cumulative added line count snapshot.",
  },
  "chat.session_removed_lines": {
    unit: "count",
    description: "Per-session cumulative removed line count snapshot.",
  },
  "chat.session_context_tokens": {
    unit: "count",
    description: "Latest session context token usage snapshot.",
  },
  "chat.session_context_window": {
    unit: "count",
    description: "Latest session context window size snapshot.",
  },
  "chat.voice_prewarm_ms": {
    unit: "ms",
    description: "Voice pipeline prewarm latency.",
  },
  "chat.voice_setup_ms": {
    unit: "ms",
    description: "Voice capture/setup latency.",
  },
  "chat.voice_first_result_ms": {
    unit: "ms",
    description: "Voice first-result latency.",
  },
  "chat.voice_playback_start_ms": {
    unit: "ms",
    description:
      "Audio playback startup latency for voice replies and replayable voice media. Tags: source, mode, status.",
  },
  "chat.voice_playback_error": {
    unit: "count",
    description: "Audio playback failure count. Tags: source, phase, error_kind.",
  },
  "chat.voice_remote_chunk_upload_ms": {
    unit: "ms",
    description: "Remote ASR chunk upload/request latency.",
  },
  "chat.voice_remote_chunk_audio_ms": {
    unit: "ms",
    description: "Audio duration covered by each uploaded remote ASR chunk.",
  },
  "chat.voice_remote_chunk_bytes": {
    unit: "count",
    description: "Encoded WAV byte size for each remote ASR chunk.",
  },
  "chat.voice_remote_chunk_chars": {
    unit: "count",
    description: "Character count returned per successful remote ASR chunk.",
  },
  "chat.voice_remote_chunk_error": {
    unit: "count",
    description: "Count of remote ASR chunk upload/transcription errors.",
  },
  // ── Dictation session metrics ──
  "chat.dictation_setup_ms": {
    unit: "ms",
    description: "Server dictation session setup latency (WS connect + ready).",
  },
  "chat.dictation_first_result_ms": {
    unit: "ms",
    description: "Time from recording start to first transcription result.",
  },
  "chat.dictation_finalize_ms": {
    unit: "ms",
    description: "Server-side finalization latency (stop to final text).",
  },
  "chat.dictation_session_ms": {
    unit: "ms",
    description: "Total dictation session duration from start to stop.",
  },
  "chat.dictation_audio_duration_ms": {
    unit: "ms",
    description: "Audio recording duration within a dictation session.",
  },
  "chat.dictation_result_updates": {
    unit: "count",
    description: "Number of transcript update events during a dictation session.",
  },
  "chat.dictation_preview_final_delta": {
    unit: "ratio",
    description:
      "Edit distance ratio between preview and final transcript (0=identical, 1=completely different).",
  },
  "chat.dictation_error": {
    unit: "count",
    description: "Dictation error count. Tags: phase, error_kind.",
  },
  "chat.dictation_cancel": {
    unit: "count",
    description: "Dictation session cancellation count.",
  },

  "chat.cell_configure_ms": {
    unit: "ms",
    description:
      "Cell configure latency for tool rows. Tags: expanded, content_type, tool, output_bytes.",
  },
  "chat.render_strategy_ms": {
    unit: "ms",
    description:
      "Internal render strategy time for tool row content. Tags: mode, input_bytes, language.",
  },

  "chat.markdown_streaming_ms": {
    unit: "ms",
    description:
      "Streaming markdown full-cycle render cost (parse + build + view apply). Tags: surface, segments.",
  },

  // ── App-level UX latency ──
  "chat.app_launch_ms": {
    unit: "ms",
    description: "Cold/warm app launch to first meaningful content visible.",
  },
  "chat.session_switch_ms": {
    unit: "ms",
    description: "Session switch latency: tap session row to chat content visible. Tags: cached.",
  },
  "chat.permission_overlay_ms": {
    unit: "ms",
    description: "Permission overlay display to user tap (allow/deny). Tags: action.",
  },
  "chat.share_export_ms": {
    unit: "ms",
    description:
      "Share sheet export rendering duration (offscreen render to shareable format). Tags: format, content_type.",
  },
  "chat.share_prepare_ms": {
    unit: "ms",
    description:
      "Shared-session redaction preflight duration. Tags: status, blocked, can_publish, findings, replacements, emails, phones, user_paths, ip_addresses, jwt_bearer, names, skills.",
  },
  "chat.share_publish_ms": {
    unit: "ms",
    description:
      "Shared-session publish duration. Tags: status, findings, replacements, emails, phones, user_paths, ip_addresses, jwt_bearer, names, skills.",
  },
  "chat.share_error": {
    unit: "count",
    description: "Shared-session request failure count. Tags: action, error_kind.",
  },
  "chat.quick_session_create_ms": {
    unit: "ms",
    description:
      "Quick session creation duration. Tags: source, status, selection, has_message, has_attachments, has_repo_refs, has_model.",
  },
  "chat.quick_session_error": {
    unit: "count",
    description: "Quick session failure count. Tags: source, selection, error_kind.",
  },
  "chat.tool_update_count": {
    unit: "count",
    description:
      "Ephemeral tool update messages received by the active chat session. Tags: tool, has_segments.",
  },

  // ── Session list rendering ──
  "chat.session_list_compute_ms": {
    unit: "ms",
    description:
      "Session list viewData computation latency. Tags: active_count, stopped_count, workspace_id.",
  },
  "chat.session_list_body_rate": {
    unit: "count",
    description:
      "Session list body evaluation count per 5-second window. High values indicate store churn.",
  },
  "chat.session_list_row_compute_ms": {
    unit: "ms",
    description:
      "Aggregate per-row computation latency for visible session rows. Tags: row_count, workspace_id.",
  },
  "chat.workspace_load_ms": {
    unit: "ms",
    description:
      "Workspace screen load latency from view entry until the list is usable. Tags: path, workspace_id.",
  },

  // ── Device resource samples (10s interval) ──
  "device.cpu_pct": {
    unit: "count",
    description:
      "Device CPU usage percentage (0-100+) computed from Mach task_info deltas over 10s window.",
  },
  "device.memory_mb": {
    unit: "count",
    description: "Device physical memory footprint in MB (phys_footprint from task_vm_info).",
  },
  "device.memory_available_mb": {
    unit: "count",
    description: "Available memory headroom in MB before jetsam (os_proc_available_memory).",
  },
  "device.thermal_state": {
    unit: "count",
    description: "Device thermal state: 0=nominal, 1=fair, 2=serious, 3=critical.",
  },
} as const satisfies Readonly<Record<string, ChatMetricDefinition>>;

export type ChatMetricName = keyof typeof CHAT_METRIC_REGISTRY;

export const CHAT_METRIC_NAME_VALUES = Object.freeze(
  Object.keys(CHAT_METRIC_REGISTRY) as ChatMetricName[],
);

export interface ChatMetricSample {
  ts: number;
  metric: ChatMetricName;
  value: number;
  unit: ChatMetricUnit;
  sessionId?: string;
  workspaceId?: string;
  tags?: Record<string, string>;
}

export interface ChatMetricUploadRequest {
  generatedAt: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  samples: ChatMetricSample[];
}

export type ClientLogLevel = "debug" | "info" | "warn" | "error";
export type ClientKind = "ios" | "mac";

export interface ClientLogEntry {
  /** Client-side timestamp (ms since epoch). */
  ts: number;
  /** Monotonic per-process sequence assigned before upload. */
  seq: number;
  level: ClientLogLevel;
  category: string;
  message: string;
  metadata?: Record<string, string>;
  sessionId?: string;
  workspaceId?: string;
}

export interface ClientLogUploadRequest {
  generatedAt: number;
  appVersion?: string;
  buildNumber?: string;
  osVersion?: string;
  deviceModel?: string;
  clientKind: ClientKind;
  appInstanceId: string;
  bootId: string;
  droppedCount?: number;
  entries: ClientLogEntry[];
}
