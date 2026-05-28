import Foundation

/// Bridges app-facing `ClientLog` calls to the shared upload queue.
///
/// The queue and wire models live in `Shared` so the future Mac client can use
/// the same server contract with a Mac-specific uploader.
enum ClientLogUploadService {
    private static let appInstanceDefaultsKey = "oppi.clientLog.appInstanceId"

    static let appInstanceId = loadAppInstanceId()
    static let bootId = UUID().uuidString

    static let shared = ClientLogUploadQueue(
        clientKind: .ios,
        appInstanceId: appInstanceId,
        bootId: bootId,
        isUploadAllowed: { TelemetrySettings.allowsRemoteDiagnosticsUpload }
    )

    static func configureUploader(_ client: APIClient?) {
        Task.detached(priority: .utility) {
            if let client {
                await shared.setMetadata(makeMetadata())
                await shared.setUploader(client)
            } else {
                await shared.setUploader(nil)
            }
        }
    }

    static func record(
        level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String]
    ) {
        guard shouldUpload(level: level, category: category) else { return }

        Task.detached(priority: .utility) {
            await shared.record(
                level: uploadLevel(for: level),
                category: category,
                message: message,
                metadata: metadata
            )
        }
    }

    private static func shouldUpload(level: ClientLogLevel, category: String) -> Bool {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return false }

        switch level {
        case .warning, .error:
            return true
        case .info:
            return highValueInfoCategories.contains(category)
        case .debug:
            return false
        }
    }

    private static let highValueInfoCategories: Set<String> = [
        "Cache",
        "ChatSession",
        "Diagnostics",
        "Memory",
        "Network",
        "StreamSession",
        "WebSocket",
    ]

    private static func uploadLevel(for level: ClientLogLevel) -> ClientLogUploadLevel {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warn
        case .error:
            return .error
        }
    }

    private static func loadAppInstanceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: appInstanceDefaultsKey), !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString
        defaults.set(value, forKey: appInstanceDefaultsKey)
        return value
    }

    private static func makeMetadata() -> ClientLogUploadMetadata {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return ClientLogUploadMetadata(
            appVersion: version,
            buildNumber: build,
            osVersion: osVersion,
            deviceModel: "iPhone"
        )
    }
}
