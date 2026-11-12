import Foundation
import Security

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
    static let appInstanceId = loadAppInstanceId()
    static let bootId = UUID().uuidString

    static let shared = ClientLogUploadQueue(
        clientKind: PlatformCapabilities.reportsAsMac ? .mac : .ios,
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
        // App Lock timeout changes: the one App Lock event a report needs.
        "AppLock",
        "Cache",
        "ChatSession",
        "Diagnostics",
        "Lifecycle",
        "Memory",
        "Network",
        "StreamSession",
        // Bounded capture-start/first-audio evidence distinguishes HFP from fallback.
        "VoiceInput",
        "WebSocket",
        // User-driven navigation breadcrumbs. A handful per minute, flushed
        // so a later crash still has the route that preceded it.
        "Navigation",
        "LiveVoice",
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

    /// One id per device install. It is a this-device-only keychain item, so a backup
    /// restored onto another device starts a new id; in UserDefaults a restore copied
    /// it, and two devices reported as one.
    private static func loadAppInstanceId() -> String {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(AppIdentifiers.subsystem).telemetry",
            kSecAttrAccount as String: "appInstanceId",
        ]
        var lookup = item
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess,
           let data = found as? Data, let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
            return existing
        }

        let value = UUID().uuidString
        var add = item
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // A failed add (before first unlock) leaves this launch's id unsaved; the next launch stores one.
        SecItemAdd(add as CFDictionary, nil)
        return value
    }

    private static func makeMetadata() -> ClientLogUploadMetadata {
        let client = TelemetryClientIdentity.current
        return ClientLogUploadMetadata(
            appVersion: client.appVersion ?? "unknown",
            buildNumber: client.buildNumber ?? "unknown",
            osVersion: client.osVersion ?? "unknown",
            deviceModel: client.deviceModel ?? "unknown",
            gitCommit: client.gitCommit,
            debugBuild: client.debugBuild
        )
    }
}
