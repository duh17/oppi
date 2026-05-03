import Foundation

struct MetricKitPayloadItem: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case metric
        case diagnostic
    }

    let kind: Kind
    let windowStartMs: Int64
    let windowEndMs: Int64
    let summary: [String: String]
    let raw: [String: String]
}

struct MetricKitUploadRequest: Codable, Sendable {
    let generatedAt: Int64
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let payloads: [MetricKitPayloadItem]
}

enum ChatMetricName: String, Codable, Sendable {
    case ttftMs = "chat.ttft_ms"
    case catchupMs = "chat.catchup_ms"
    case catchupRingMiss = "chat.catchup_ring_miss"
    case timelineApplyMs = "chat.timeline_apply_ms"
    case timelineLayoutMs = "chat.timeline_layout_ms"
    // Removed: wsDecodeMs — high-volume noise (32% of samples, almost always 0ms)
    case coalescerFlushEvents = "chat.coalescer_flush_events"
    case coalescerFlushBytes = "chat.coalescer_flush_bytes"
    case fullReloadMs = "chat.full_reload_ms"
    case freshContentLagMs = "chat.fresh_content_lag_ms"
    case cacheLoadMs = "chat.cache_load_ms"
    case reducerLoadMs = "chat.reducer_load_ms"
    case wsWaitForConnectedMs = "chat.ws_wait_for_connected_ms"
    case commandSendMs = "chat.command_send_ms"
    case commandRoundtripMs = "chat.command_roundtrip_ms"
    case commandResolveLagMs = "chat.command_resolve_lag_ms"
    case sessionLoadMs = "chat.session_load_ms"
    case jankPct = "chat.jank_pct"
    case subscribeGateMs = "chat.subscribe_gate_ms"
    case queueSyncMs = "chat.queue_sync_ms"
    case resubscribeMs = "chat.resubscribe_ms"
    case silentResubscribeCount = "chat.silent_resubscribe_count"
    case subscriptionRaceCount = "chat.subscription_race_count"
    case messageQueueAckMs = "chat.message_queue_ack_ms"
    case messageQueueStaleDrop = "chat.message_queue_stale_drop"
    case messageQueueStartMiss = "chat.message_queue_start_miss"
    case sessionMessageCount = "chat.session_message_count"
    case sessionInputTokens = "chat.session_input_tokens"
    case sessionOutputTokens = "chat.session_output_tokens"
    case sessionMutatingToolCalls = "chat.session_mutating_tool_calls"
    case sessionFilesChanged = "chat.session_files_changed"
    case sessionAddedLines = "chat.session_added_lines"
    case sessionRemovedLines = "chat.session_removed_lines"
    case sessionContextTokens = "chat.session_context_tokens"
    case sessionContextWindow = "chat.session_context_window"
    case voicePrewarmMs = "chat.voice_prewarm_ms"
    case voiceSetupMs = "chat.voice_setup_ms"
    case voiceFirstResultMs = "chat.voice_first_result_ms"
    case voicePlaybackStartMs = "chat.voice_playback_start_ms"
    case voicePlaybackError = "chat.voice_playback_error"
    case voiceRemoteChunkUploadMs = "chat.voice_remote_chunk_upload_ms"
    case voiceRemoteChunkAudioMs = "chat.voice_remote_chunk_audio_ms"
    case voiceRemoteChunkBytes = "chat.voice_remote_chunk_bytes"
    case voiceRemoteChunkChars = "chat.voice_remote_chunk_chars"
    case voiceRemoteChunkError = "chat.voice_remote_chunk_error"
    case dictationSetupMs = "chat.dictation_setup_ms"
    case dictationFirstResultMs = "chat.dictation_first_result_ms"
    case dictationFinalizeMs = "chat.dictation_finalize_ms"
    case dictationSessionMs = "chat.dictation_session_ms"
    case dictationAudioDurationMs = "chat.dictation_audio_duration_ms"
    case dictationError = "chat.dictation_error"
    case dictationCancel = "chat.dictation_cancel"
    case dictationResultUpdates = "chat.dictation_result_updates"
    case dictationPreviewFinalDelta = "chat.dictation_preview_final_delta"
    case cellConfigureMs = "chat.cell_configure_ms"
    case renderStrategyMs = "chat.render_strategy_ms"
    case timelineHitch = "chat.timeline_hitch"
    case appLaunchMs = "chat.app_launch_ms"
    case sessionSwitchMs = "chat.session_switch_ms"
    case shareExportMs = "chat.share_export_ms"
    case sharePrepareMs = "chat.share_prepare_ms"
    case sharePublishMs = "chat.share_publish_ms"
    case shareError = "chat.share_error"
    case quickSessionCreateMs = "chat.quick_session_create_ms"
    case quickSessionError = "chat.quick_session_error"
    case toolUpdateCount = "chat.tool_update_count"
    case permissionOverlayMs = "chat.permission_overlay_ms"
    case sessionListComputeMs = "chat.session_list_compute_ms"
    case sessionListBodyRate = "chat.session_list_body_rate"
    case sessionListRowComputeMs = "chat.session_list_row_compute_ms"
    case markdownStreamingMs = "chat.markdown_streaming_ms"
    case deviceCpuPct = "device.cpu_pct"
    case deviceMemoryMb = "device.memory_mb"
    case deviceMemoryAvailableMb = "device.memory_available_mb"
    case deviceThermalState = "device.thermal_state"
}

enum ChatMetricUnit: String, Codable, Sendable {
    case ms
    case count
    case ratio
}

struct ChatMetricSample: Codable, Sendable {
    let ts: Int64
    let metric: ChatMetricName
    let value: Double
    let unit: ChatMetricUnit
    let sessionId: String?
    let workspaceId: String?
    let tags: [String: String]?
}

struct ChatMetricUploadRequest: Codable, Sendable {
    let generatedAt: Int64
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let samples: [ChatMetricSample]
}
