import Foundation

enum ClientLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct ClientLogEntry: Codable, Sendable {
    let timestamp: Int64
    let level: ClientLogLevel
    let category: String
    let message: String
    let metadata: [String: String]?
}

struct ClientLogUploadRequest: Encodable, Sendable {
    let generatedAt: Int64
    let trigger: String
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let entries: [ClientLogEntry]
}

actor ClientLogBuffer {
    static let shared = ClientLogBuffer()

    private var entries: [ClientLogEntry] = []
    private let maxEntries = 1_200

    func record(
        level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let trimmedCategory = String(category.prefix(64))
        let trimmedMessage = String(message.prefix(4_000))
        let trimmedMetadata = metadata.isEmpty
            ? nil
            : metadata.reduce(into: [String: String]()) { partial, item in
                partial[String(item.key.prefix(64))] = String(item.value.prefix(512))
            }

        entries.append(
            ClientLogEntry(
                timestamp: Self.nowMs(),
                level: level,
                category: trimmedCategory,
                message: trimmedMessage,
                metadata: trimmedMetadata
            )
        )

        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func snapshot(limit: Int = 400, sessionId: String? = nil) -> [ClientLogEntry] {
        guard limit > 0 else { return [] }

        let source: [ClientLogEntry]
        if let sessionId, !sessionId.isEmpty {
            let filtered = entries.filter { entry in
                guard let metadata = entry.metadata else { return false }
                return Self.sessionMetadataKeys.contains { key in
                    metadata[key] == sessionId
                }
            }
            source = filtered.isEmpty ? entries : filtered
        } else {
            source = entries
        }

        if source.count <= limit {
            return source
        }
        return Array(source.suffix(limit))
    }

    private static let sessionMetadataKeys = [
        "sessionId",
        "targetSession",
        "wsSession",
    ]

    private static func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000.0).rounded())
    }
}

enum ClientLog {
    static func record(
        _ level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
#if !DEBUG
        // Keep release breadcrumb volume low. Sentry gets warning+error only.
        guard level == .warning || level == .error else { return }
#endif

        Task.detached(priority: .utility) {
            await SentryService.shared.recordBreadcrumb(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
#if DEBUG
            await ClientLogBuffer.shared.record(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
#endif
        }
    }

    static func info(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.info, category: category, message: message, metadata: metadata)
    }

    static func warning(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.warning, category: category, message: message, metadata: metadata)
    }

    static func error(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.error, category: category, message: message, metadata: metadata)
    }
}
