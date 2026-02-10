import Darwin.Mach
import os.log
import SwiftUI
import UIKit

private let appLog = Logger(subsystem: "dev.chenda.PiRemote", category: "App")

@main
struct PiRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var connection = ServerConnection()
    @State private var navigation = AppNavigation()
    @State private var themeStore = ThemeStore()
    @State private var mainThreadLagWatchdog = MainThreadLagWatchdog()
#if DEBUG
    @State private var autoClientLogUploadInFlight = false
    @State private var lastAutoClientLogUploadMs: Int64 = 0
#endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(connection.sessionStore)
                .environment(connection.permissionStore)
                .environment(connection.reducer)
                .environment(connection.reducer.toolOutputStore)
                .environment(connection.reducer.toolArgsStore)
                .environment(connection.audioPlayer)
                .environment(navigation)
                .environment(themeStore)
                .environment(\.theme, themeStore.appTheme)
                .preferredColorScheme(themeStore.preferredColorScheme)
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    handleMemoryWarning()
                }
                .task {
                    configureWatchdogHooks()
                    mainThreadLagWatchdog.start()
                    await setupNotifications()
                    await reconnectOnLaunch()
                }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            mainThreadLagWatchdog.start()
            Task { await connection.reconnectIfNeeded() }
        case .background:
            mainThreadLagWatchdog.stop()
            connection.flushAndSuspend()
            RestorationState.save(from: connection, navigation: navigation)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handleMemoryWarning() {
        let cacheStats = MarkdownSegmentCache.shared.snapshot()
        MarkdownSegmentCache.shared.clearAll()

        let reducerStats = connection.reducer.handleMemoryWarning()

        let cacheEntries = cacheStats.entries
        let cacheBytes = cacheStats.totalSourceBytes
        let toolOutputBytes = reducerStats.toolOutputBytesCleared
        let collapsedExpandedItems = reducerStats.expandedItemsCollapsed

        appLog.error(
            "MEM warning: cacheEntries=\(cacheEntries, privacy: .public) cacheBytes=\(cacheBytes, privacy: .public) toolOutputBytes=\(toolOutputBytes, privacy: .public) collapsedExpandedItems=\(collapsedExpandedItems, privacy: .public)"
        )
    }

    private func configureWatchdogHooks() {
#if DEBUG
        mainThreadLagWatchdog.onStall = { context in
            Task { @MainActor in
                await self.handleWatchdogStall(context)
            }
        }
#endif
    }

#if DEBUG
    @MainActor
    private func handleWatchdogStall(_ context: MainThreadStallContext) async {
        guard scenePhase == .active else { return }
        guard !navigation.showOnboarding else { return }
        guard !autoClientLogUploadInFlight else { return }

        let nowMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let cooldownMs: Int64 = 90_000
        guard nowMs - lastAutoClientLogUploadMs >= cooldownMs else { return }

        guard let sessionId = connection.sessionStore.activeSessionId else { return }
        guard let api = connection.apiClient else { return }

        autoClientLogUploadInFlight = true
        lastAutoClientLogUploadMs = nowMs

        ClientLog.error(
            "Diagnostics",
            "Auto-upload triggered by main-thread stall",
            metadata: [
                "sessionId": sessionId,
                "thresholdMs": String(context.thresholdMs),
                "footprintMB": context.footprintMB.map(String.init) ?? "n/a",
                "crumb": context.crumb,
                "rows": String(context.rows),
            ]
        )

        let entries = await ClientLogBuffer.shared.snapshot(limit: 500)
        guard !entries.isEmpty else {
            autoClientLogUploadInFlight = false
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"

        let request = ClientLogUploadRequest(
            generatedAt: nowMs,
            trigger: "stall-watchdog-auto",
            appVersion: version,
            buildNumber: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: UIDevice.current.model,
            entries: entries
        )

        do {
            try await api.uploadClientLogs(sessionId: sessionId, request: request)
            ClientLog.info(
                "Diagnostics",
                "Auto-upload succeeded",
                metadata: [
                    "sessionId": sessionId,
                    "entries": String(entries.count),
                ]
            )
            if connection.sessionStore.activeSessionId == sessionId {
                connection.reducer.appendSystemEvent("Auto-uploaded \(entries.count) client log entries after stall")
            }
        } catch {
            ClientLog.error(
                "Diagnostics",
                "Auto-upload failed",
                metadata: [
                    "sessionId": sessionId,
                    "error": error.localizedDescription,
                ]
            )
        }

        autoClientLogUploadInFlight = false
    }
#endif

    private func setupNotifications() async {
        let notificationService = PermissionNotificationService.shared
        await notificationService.setup()

        // Wire notification actions back to the connection
        notificationService.onPermissionResponse = { [weak connection] permissionId, action in
            guard let connection else {
                return
            }
            Task {
                try? await connection.respondToPermission(id: permissionId, action: action)
            }
        }

        // Configure push registration with the connection
        PushRegistration.shared.configure(connection: connection)

        // Navigate to session when user taps a push notification body
        notificationService.onNavigateToPermission = { [weak connection] _, sessionId in
            guard let connection, !sessionId.isEmpty else {
                return
            }
            connection.sessionStore.activeSessionId = sessionId
            navigation.selectedTab = .sessions
        }
    }

    private func reconnectOnLaunch() async {
        // 1. Load credentials from Keychain
        guard let creds = KeychainService.loadCredentials() else {
            navigation.showOnboarding = true
            return
        }

        guard connection.configure(credentials: creds) else {
            // Corrupted credentials — wipe and show onboarding
            KeychainService.deleteCredentials()
            navigation.showOnboarding = true
            return
        }
        navigation.showOnboarding = false

        // 2. Restore UI state (tab, active session, draft)
        if let restored = RestorationState.load() {
            navigation.selectedTab = AppTab(rawString: restored.selectedTab)
            connection.sessionStore.activeSessionId = restored.activeSessionId
            connection.composerDraft = restored.composerDraft
        }

        // 3. Show cached data immediately (before any network calls)
        let cache = TimelineCache.shared
        if let cachedSessions = await cache.loadSessionList() {
            connection.sessionStore.sessions = cachedSessions
        }

        // 4. Refresh session list from server
        guard let api = connection.apiClient else {
            return
        }
        do {
            let sessions = try await api.listSessions()
            connection.sessionStore.sessions = sessions
            Task.detached { await TimelineCache.shared.saveSessionList(sessions) }

            // 5. Evict trace caches for deleted sessions
            let activeIds = Set(sessions.map(\.id))
            Task.detached { await TimelineCache.shared.evictStaleTraces(keepIds: activeIds) }

            // 6. Load workspaces + skills (cache-backed internally)
            await connection.workspaceStore.load(api: api)

            // 7. Register for push notifications (after successful server connection)
            await PushRegistration.shared.requestAndRegister()
        } catch {
            // Offline — cached data already shown above
        }
    }
}

// MARK: - Main Thread Breadcrumb

/// Thread-safe breadcrumb for the main thread watchdog.
/// Set from the main thread at entry/exit points of critical code paths.
/// Read from the watchdog background thread to identify where the main
/// thread is stuck during a stall.
enum MainThreadBreadcrumb {
    // Atomic string stored in a lock-free box.
    // Written on main thread, read on watchdog thread.
    private static let _value = OSAllocatedUnfairLock(initialState: "idle")

    /// Layout-cycle counter. Incremented on @MainActor in ChatItemRow.body
    /// to detect LazyVStack over-rendering. Reset on renderVersion change.
    /// Written on main thread, read on watchdog thread.
    private static let _rowCount = OSAllocatedUnfairLock(initialState: 0)

    static var current: String {
        _value.withLock { $0 }
    }

    static func set(_ crumb: String) {
        _value.withLock { $0 = crumb }
    }

    static func incrementRowCount() -> Int {
        _rowCount.withLock { val in
            val += 1
            return val
        }
    }

    static func resetRowCount() {
        _rowCount.withLock { $0 = 0 }
    }

    static var rowCount: Int {
        _rowCount.withLock { $0 }
    }
}

private struct MainThreadStallContext: Sendable {
    let thresholdMs: Int
    let footprintMB: Int?
    let crumb: String
    let rows: Int
}

private final class MainThreadLagWatchdog {
    var onStall: ((MainThreadStallContext) -> Void)?
    private let queue = DispatchQueue(label: "dev.chenda.PiRemote.main-thread-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let intervalMs = 1_000
    private let warnThresholdMs = 700
    private let stallLogCooldownMs = 2_000

    private var lastStallLogUptimeNs: UInt64 = 0

    func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .milliseconds(intervalMs),
            repeating: .milliseconds(intervalMs),
            leeway: .milliseconds(100)
        )

        timer.setEventHandler { [weak self] in
            self?.probeMainThread()
        }

        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func probeMainThread() {
        let scheduledNs = DispatchTime.now().uptimeNanoseconds
        let thresholdMs = warnThresholdMs

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + .milliseconds(thresholdMs)) == .timedOut {
            let nowNs = DispatchTime.now().uptimeNanoseconds
            let cooldownNs = UInt64(stallLogCooldownMs) * 1_000_000
            guard nowNs &- lastStallLogUptimeNs >= cooldownNs else { return }
            lastStallLogUptimeNs = nowNs

            let crumb = MainThreadBreadcrumb.current
            let rows = MainThreadBreadcrumb.rowCount
            let footprintMB = Self.currentFootprintMB()

            if let footprintMB {
                appLog.error(
                    "PERF main-thread stall: >\(thresholdMs, privacy: .public)ms footprint=\(footprintMB, privacy: .public)MB crumb=\(crumb, privacy: .public) rows=\(rows, privacy: .public)"
                )
                ClientLog.error(
                    "App",
                    "PERF main-thread stall",
                    metadata: [
                        "thresholdMs": String(thresholdMs),
                        "footprintMB": String(footprintMB),
                        "crumb": crumb,
                        "rows": String(rows),
                    ]
                )
            } else {
                appLog.error("PERF main-thread stall: >\(thresholdMs, privacy: .public)ms footprint=n/a crumb=\(crumb, privacy: .public) rows=\(rows, privacy: .public)")
                ClientLog.error(
                    "App",
                    "PERF main-thread stall",
                    metadata: [
                        "thresholdMs": String(thresholdMs),
                        "footprintMB": "n/a",
                        "crumb": crumb,
                        "rows": String(rows),
                    ]
                )
            }

            onStall?(
                MainThreadStallContext(
                    thresholdMs: thresholdMs,
                    footprintMB: footprintMB,
                    crumb: crumb,
                    rows: rows
                )
            )
            return
        }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let lagMs = Int((nowNs - scheduledNs) / 1_000_000)
        guard lagMs >= thresholdMs else { return }

        let crumb = MainThreadBreadcrumb.current
        if let footprintMB = Self.currentFootprintMB() {
            appLog.error(
                "PERF main-thread lag: \(lagMs, privacy: .public)ms footprint=\(footprintMB, privacy: .public)MB crumb=\(crumb, privacy: .public)"
            )
            ClientLog.error(
                "App",
                "PERF main-thread lag",
                metadata: [
                    "lagMs": String(lagMs),
                    "footprintMB": String(footprintMB),
                    "crumb": crumb,
                ]
            )
        } else {
            appLog.error("PERF main-thread lag: \(lagMs, privacy: .public)ms footprint=n/a crumb=\(crumb, privacy: .public)")
            ClientLog.error(
                "App",
                "PERF main-thread lag",
                metadata: [
                    "lagMs": String(lagMs),
                    "footprintMB": "n/a",
                    "crumb": crumb,
                ]
            )
        }
    }

    private static func currentFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }
}
