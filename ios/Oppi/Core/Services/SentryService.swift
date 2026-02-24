import Foundation
import OSLog

#if canImport(Sentry)
import Sentry
#endif

private let sentryLog = Logger(subsystem: AppIdentifiers.subsystem, category: "Sentry")

/// Thin async wrapper around Sentry SDK setup + common diagnostics hooks.
///
/// Uses an actor to stay concurrency-safe under Swift 6 strict checking.
actor SentryService {
    static let shared = SentryService()

    private var hasConfigured = false
    private var sdkStarted = false

    private init() {}

    func configure() {
        guard !hasConfigured else { return }
        hasConfigured = true

        let rawValue = (Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String) ?? ""
        let dsn = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !dsn.isEmpty, !dsn.hasPrefix("$(") else {
            sentryLog.info("Sentry disabled (no DSN)")
            return
        }

#if canImport(Sentry)
        let environment = Self.environmentName()
        let releaseName = Self.releaseName()

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = releaseName
            options.maxBreadcrumbs = 300
            options.sendDefaultPii = false
            options.enableAppHangTracking = true
            options.enableAutoPerformanceTracing = true
#if DEBUG
            options.debug = true
            options.tracesSampleRate = 1.0
            // Disable watchdog termination tracking in debug builds.
            // Sentry's heuristic (no clean shutdown + no crash = watchdog)
            // produces false positives from Xcode stop/restart, debugger
            // detach, and device disconnect cycles — APPLE-IOS-6 noise.
            options.enableWatchdogTerminationTracking = false
#else
            options.debug = false
            options.tracesSampleRate = 0.2
#endif
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: environment, key: "app_environment")
            scope.setTag(value: releaseName, key: "app_release")
        }

        sdkStarted = true
        sentryLog.info("Sentry enabled for \(releaseName, privacy: .public)")
#else
        _ = dsn
        sentryLog.error("Sentry DSN configured but SDK unavailable")
#endif
    }

    func setSessionContext(sessionId: String?, workspaceId: String?) {
#if canImport(Sentry)
        guard sdkStarted else { return }

        let sessionTag: String
        if let sessionId, !sessionId.isEmpty {
            sessionTag = sessionId
        } else {
            sessionTag = "none"
        }

        let workspaceTag: String
        if let workspaceId, !workspaceId.isEmpty {
            workspaceTag = workspaceId
        } else {
            workspaceTag = "none"
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: sessionTag, key: "session_id")
            scope.setTag(value: workspaceTag, key: "workspace_id")
        }
#else
        _ = sessionId
        _ = workspaceId
#endif
    }

    func recordBreadcrumb(
        level: ClientLogLevel,
        category: String,
        message: String,
        metadata: [String: String]
    ) {
#if canImport(Sentry)
        guard sdkStarted else { return }

        let breadcrumb = Breadcrumb()
        breadcrumb.category = category
        breadcrumb.message = message
        breadcrumb.level = Self.sentryLevel(for: level)
        if !metadata.isEmpty {
            breadcrumb.data = metadata.reduce(into: [String: Any]()) { partial, item in
                partial[item.key] = item.value
            }
        }
        SentrySDK.addBreadcrumb(breadcrumb)
#else
        _ = level
        _ = category
        _ = message
        _ = metadata
#endif
    }

    func captureMainThreadStall(
        thresholdMs: Int,
        footprintMB: Int?,
        sessionId: String?
    ) {
#if canImport(Sentry)
        guard sdkStarted else { return }

        var metadata: [String: String] = [
            "thresholdMs": String(thresholdMs),
        ]
        if let footprintMB {
            metadata["footprintMB"] = String(footprintMB)
        }
        if let sessionId, !sessionId.isEmpty {
            metadata["sessionId"] = sessionId
        }

        let breadcrumb = Breadcrumb()
        breadcrumb.category = "Diagnostics"
        breadcrumb.message = "Main-thread stall watchdog triggered"
        breadcrumb.level = .error
        breadcrumb.data = metadata.reduce(into: [String: Any]()) { partial, item in
            partial[item.key] = item.value
        }

        SentrySDK.addBreadcrumb(breadcrumb)
        SentrySDK.capture(message: "Main-thread stall watchdog triggered")
#else
        _ = thresholdMs
        _ = footprintMB
        _ = sessionId
#endif
    }

    // MARK: - Memory Footprint

    /// Current physical memory footprint in MB, or nil on failure.
    /// Uses task_vm_info.phys_footprint — the same metric jetsam uses.
    static func currentFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    private static func environmentName() -> String {
#if DEBUG
        return "debug"
#else
        let configuredMode = Bundle.main.object(forInfoDictionaryKey: "OPPITelemetryMode") as? String
        let configured = configuredMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch configured {
        case "public", "release", "prod", "production":
            return "release"
        case "test", "staging", "qa", "internal":
            return "test"
        default:
            return configured ?? "release"
        }
#endif
    }

    private static func releaseName() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(AppIdentifiers.subsystem)@\(version)+\(build)"
    }

#if canImport(Sentry)
    private static func sentryLevel(for level: ClientLogLevel) -> SentryLevel {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }
#endif
}
