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
    let client: TelemetryClientInfo
    let payloads: [MetricKitPayloadItem]
}
