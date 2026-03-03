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
    case wsDecodeMs = "chat.ws_decode_ms"
    case coalescerFlushEvents = "chat.coalescer_flush_events"
    case coalescerFlushBytes = "chat.coalescer_flush_bytes"
    case inboundQueueDepth = "chat.inbound_queue_depth"
    case fullReloadMs = "chat.full_reload_ms"
    case freshContentLagMs = "chat.fresh_content_lag_ms"
    case cacheLoadMs = "chat.cache_load_ms"
    case reducerLoadMs = "chat.reducer_load_ms"
    case wsConnectMs = "chat.ws_connect_ms"
    case voicePrewarmMs = "chat.voice_prewarm_ms"
    case voiceSetupMs = "chat.voice_setup_ms"
    case voiceFirstResultMs = "chat.voice_first_result_ms"
    case plotAxisVisibleTickCount = "plot.axis_visible_tick_count"
    case plotLegendItemCount = "plot.legend_item_count"
    case plotScrollEnabled = "plot.scroll_enabled"
    case plotAutoAdjustments = "plot.auto_adjustments"
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
