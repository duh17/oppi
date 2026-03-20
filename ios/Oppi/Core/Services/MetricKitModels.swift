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
    case inboundQueueDepth = "chat.inbound_queue_depth"
    case fullReloadMs = "chat.full_reload_ms"
    case freshContentLagMs = "chat.fresh_content_lag_ms"
    case cacheLoadMs = "chat.cache_load_ms"
    case reducerLoadMs = "chat.reducer_load_ms"
    case wsConnectMs = "chat.ws_connect_ms"
    case sessionLoadMs = "chat.session_load_ms"
    case jankPct = "chat.jank_pct"
    case subscribeAckMs = "chat.subscribe_ack_ms"
    case queueSyncMs = "chat.queue_sync_ms"
    case messageQueueAckMs = "chat.message_queue_ack_ms"
    case messageQueueStaleDrop = "chat.message_queue_stale_drop"
    case messageQueueStartMiss = "chat.message_queue_start_miss"
    case connectedDispatchMs = "chat.connected_dispatch_ms"
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
    case voiceRemoteProbeMs = "chat.voice_remote_probe_ms"
    case voiceRemoteChunkUploadMs = "chat.voice_remote_chunk_upload_ms"
    case voiceRemoteChunkAudioMs = "chat.voice_remote_chunk_audio_ms"
    case voiceRemoteChunkBytes = "chat.voice_remote_chunk_bytes"
    case voiceRemoteChunkChars = "chat.voice_remote_chunk_chars"
    case voiceRemoteChunkError = "chat.voice_remote_chunk_error"
    case cellConfigureMs = "chat.cell_configure_ms"
    case renderStrategyMs = "chat.render_strategy_ms"
    case timelineHitch = "chat.timeline_hitch"
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
