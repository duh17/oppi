import Foundation

enum ClientLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
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
        }
    }

    static func info(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.info, category: category, message: message, metadata: metadata)
    }

    // periphery:ignore - API surface; warning log level not yet consumed
    static func warning(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.warning, category: category, message: message, metadata: metadata)
    }

    static func error(_ category: String, _ message: String, metadata: [String: String] = [:]) {
        record(.error, category: category, message: message, metadata: metadata)
    }
}
