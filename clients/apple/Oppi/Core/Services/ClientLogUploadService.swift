import Foundation

final class ClientLogUploadDispatcher: @unchecked Sendable {
    private let queue: ClientLogUploadQueue
    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?

    init(queue: ClientLogUploadQueue) {
        self.queue = queue
    }

    func configureUploader(_ uploader: (any ClientLogUploading)?, metadata: ClientLogUploadMetadata?) {
        enqueue { [queue] in
            if let metadata {
                await queue.setMetadata(metadata)
            }
            await queue.setUploader(uploader)
        }
    }

    func record(
        level: ClientLogUploadLevel,
        category: String,
        message: String,
        metadata: [String: String],
        flush: Bool = false
    ) {
        enqueue { [queue] in
            await queue.record(
                level: level,
                category: category,
                message: message,
                metadata: metadata
            )
            if flush {
                await queue.flushNow()
            }
        }
    }

    func flush() {
        enqueue { [queue] in
            await queue.flushNow()
        }
    }

    // periphery:ignore - deterministic barrier for dispatcher ordering tests
    func waitUntilIdleForTesting() async {
        await currentTailTask()?.value
    }

    private func currentTailTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return tailTask
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let predecessor = tailTask
        let task = Task.detached(priority: .utility) {
            await predecessor?.value
            await operation()
        }
        tailTask = task
        lock.unlock()
    }
}

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
    private static let dispatcher = ClientLogUploadDispatcher(queue: shared)

    static func configureUploader(_ client: APIClient?) {
        dispatcher.configureUploader(
            client,
            metadata: client == nil ? nil : makeMetadata()
        )
    }

    static func record(
        level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String],
        flush: Bool = false
    ) {
        guard shouldUpload(level: level, category: category) else { return }

        dispatcher.record(
            level: uploadLevel(for: level),
            category: category,
            message: message,
            metadata: metadata,
            flush: flush
        )
    }

    static func flush() {
        dispatcher.flush()
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
        "Lifecycle",
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
