import Darwin.Mach
import Foundation
import OSLog

import MetricKit

private let metricKitLog = Logger(subsystem: AppIdentifiers.subsystem, category: "MetricKit")

final class MetricKitService: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitService()

    private let uploader = MetricKitUploadQueue()
    private let diagnosticFingerprintLock = NSLock()
    private var configured = false
    private var queuedDiagnosticFingerprints = Set<String>()

    override private init() {}

    func configure() {
        guard !configured else { return }
        configured = true

        // Always subscribe to MetricKit — payloads are gated at upload time.
        // This ensures we start receiving data immediately if the user opts in later.
        MXMetricManager.shared.add(self)
        collectPastDiagnosticPayloadsIfAllowed(reason: "configure")
        metricKitLog.info("MetricKit subscriber registered (upload=\(TelemetrySettings.allowsRemoteDiagnosticsUpload, privacy: .public))")
    }

    /// Called when the user toggles the diagnostics preference in Settings.
    /// Re-evaluates upload eligibility and flushes any queued data.
    func refreshAfterPreferenceChange() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload
        metricKitLog.info("Telemetry preference changed (upload=\(allowed, privacy: .public))")

        let client = allowed ? currentAPIClient : nil
        Task {
            await ChatMetricsService.shared.setUploadClient(client)
        }
        ClientLogUploadService.configureUploader(client)

        guard allowed else {
            Task { await uploader.clear() }
            return
        }
        collectPastDiagnosticPayloadsIfAllowed(reason: "preference_change")
        Task {
            await uploader.setClient(client)
            await uploader.setMetadata(Self.makeMetadata())
            await uploader.flushIfNeeded()
        }
    }

    /// Stored reference so refreshAfterPreferenceChange can re-wire.
    private var currentAPIClient: APIClient?

    func setUploadClient(_ client: APIClient?) {
        currentAPIClient = client

        Task {
            await ChatMetricsService.shared.setUploadClient(client)
        }
        ClientLogUploadService.configureUploader(client)

        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            Task { await uploader.clear() }
            return
        }

        collectPastDiagnosticPayloadsIfAllowed(reason: "set_upload_client")
        Task {
            await uploader.setClient(client)
            await uploader.setMetadata(Self.makeMetadata())
            await uploader.flushIfNeeded()
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        let items = payloads.map { payload in
            MetricKitPayloadSerializer.item(
                from: payload,
                kind: .metric,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs()
            )
        }
        upload(items)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let context = MetricKitCrashContextStore.postMortemSnapshotMetadata()
        let items = payloads.compactMap { payload in
            let item = MetricKitPayloadSerializer.item(
                from: payload,
                kind: .diagnostic,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs(),
                context: context
            )
            return markDiagnosticIfNew(item)
        }
        recordDiagnosticClientLogs(items, reason: "did_receive")
        upload(items)
    }

    private func upload(_ items: [MetricKitPayloadItem]) {
        guard !items.isEmpty else { return }
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        Task {
            await uploader.enqueue(payloads: items)
        }
    }

    private func collectPastDiagnosticPayloadsIfAllowed(reason: String) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        let payloads = MXMetricManager.shared.pastDiagnosticPayloads
        guard !payloads.isEmpty else { return }

        let context = MetricKitCrashContextStore.postMortemSnapshotMetadata()
        let items = payloads.compactMap { payload in
            let item = MetricKitPayloadSerializer.item(
                from: payload,
                kind: .diagnostic,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs(),
                context: context
            )
            return markDiagnosticIfNew(item)
        }
        recordDiagnosticClientLogs(items, reason: reason)
        upload(items)
    }

    private func markDiagnosticIfNew(_ item: MetricKitPayloadItem) -> MetricKitPayloadItem? {
        let fingerprint = [
            String(item.windowStartMs),
            String(item.windowEndMs),
            item.summary["crashDiagnosticCount"] ?? "0",
            item.summary["hangDiagnosticCount"] ?? "0",
            item.summary["cpuExceptionDiagnosticCount"] ?? "0",
            item.summary["diskWriteExceptionDiagnosticCount"] ?? "0",
        ].joined(separator: "|")
        diagnosticFingerprintLock.lock()
        defer { diagnosticFingerprintLock.unlock() }
        guard !queuedDiagnosticFingerprints.contains(fingerprint) else { return nil }
        queuedDiagnosticFingerprints.insert(fingerprint)
        return item
    }

    private func recordDiagnosticClientLogs(_ items: [MetricKitPayloadItem], reason: String) {
        for item in items {
            let crashCount = Int(item.summary["crashDiagnosticCount"] ?? "0") ?? 0
            let hangCount = Int(item.summary["hangDiagnosticCount"] ?? "0") ?? 0
            let cpuExceptionCount = Int(item.summary["cpuExceptionDiagnosticCount"] ?? "0") ?? 0
            guard crashCount > 0 || hangCount > 0 || cpuExceptionCount > 0 else { continue }

            var metadata: [String: String] = [
                "reason": reason,
                "crashDiagnosticCount": String(crashCount),
                "hangDiagnosticCount": String(hangCount),
                "cpuExceptionDiagnosticCount": String(cpuExceptionCount),
            ]
            if let sessionId = item.summary["lastSessionId"] {
                metadata["sessionId"] = sessionId
            }
            if let workspaceId = item.summary["lastWorkspaceId"] {
                metadata["workspaceId"] = workspaceId
            }
            for key in [
                "lastScreen",
                "lastScenePhase",
                "lastLifecycleEvent",
                "lastLifecycleStep",
                "lastLifecycleRecordedAtMs",
                "lastStallRecordedAtMs",
                "lastStallThresholdMs",
                "lastStallDurationMs",
                "lastStallSequence",
            ] {
                if let value = item.summary[key] {
                    metadata[key] = value
                }
            }
            ClientLog.error("MetricKit", "Crash diagnostic payload queued", metadata: metadata, flush: true)
        }
    }

    fileprivate static func makeMetadata() -> MetricKitUploadMetadata {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = Self.deviceModel()
        return MetricKitUploadMetadata(
            appVersion: version,
            buildNumber: build,
            osVersion: osVersion,
            deviceModel: model
        )
    }

    private static func deviceModel() -> String {
        "iPhone"
    }

}

extension MetricKitService: @unchecked Sendable {}

struct MainThreadStallContext: Sendable {
    let sequence: Int
    let thresholdMs: Int
    let detectedAtMs: Int64
    let footprintMB: Int?
}

struct MainThreadStallRecoveryContext: Sendable {
    let sequence: Int
    let durationMs: Int
    let recoveredAtMs: Int64
}

final class MainThreadLagWatchdog: @unchecked Sendable {
    var onStall: (@Sendable (MainThreadStallContext) -> Void)?
    var onRecovery: (@Sendable (MainThreadStallRecoveryContext) -> Void)?
    // periphery:ignore - deterministic signal for MainThreadLagWatchdogTests
    var onDelayedStopEvaluationForTesting: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "\(AppIdentifiers.subsystem).main-thread-watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let intervalMs = 1_000
    private let warnThresholdMs = 700
    private let stallLogCooldownMs = 2_000

    private var lastStallLogUptimeNs: UInt64 = 0
    private var nextProbeID = 0
    private var nextStallSequence = 0
    private var lifecycleGeneration: UInt64 = 0
    private var activeStall: ActiveStall?

    private struct ActiveStall {
        let sequence: Int
        let startedNs: UInt64
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            lifecycleGeneration &+= 1
            startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            lifecycleGeneration &+= 1
            stopOnQueue()
        }
    }

    func stopAfterGracePeriod(_ delayMs: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            lifecycleGeneration &+= 1
            let scheduledGeneration = lifecycleGeneration
            queue.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMs))) { [weak self] in
                guard let self else { return }
                if lifecycleGeneration == scheduledGeneration {
                    stopOnQueue()
                }
                onDelayedStopEvaluationForTesting?()
            }
        }
    }

    // periphery:ignore - deterministic state probe for MainThreadLagWatchdogTests
    func isRunningForTesting() -> Bool {
        queue.sync { timer != nil }
    }

    private func startOnQueue() {
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

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        activeStall = nil
    }

    private func probeMainThread() {
        let thresholdMs = warnThresholdMs
        let probeID = nextProbeID
        nextProbeID &+= 1
        let startedNs = DispatchTime.now().uptimeNanoseconds

        let semaphore = DispatchSemaphore(value: 0)
        let callbackQueue = queue
        DispatchQueue.main.async { [weak self, callbackQueue] in
            let completedNs = DispatchTime.now().uptimeNanoseconds
            semaphore.signal()
            callbackQueue.async { [weak self] in
                self?.probeDidComplete(startedNs: startedNs, completedNs: completedNs)
            }
        }

        if semaphore.wait(timeout: .now() + .milliseconds(thresholdMs)) == .timedOut {
            recordTimedOutProbe(probeID: probeID, startedNs: startedNs, thresholdMs: thresholdMs)
        }
    }

    private func recordTimedOutProbe(probeID: Int, startedNs: UInt64, thresholdMs: Int) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let cooldownNs = UInt64(stallLogCooldownMs) * 1_000_000
        let shouldEmit = activeStall == nil || nowNs &- lastStallLogUptimeNs >= cooldownNs
        guard shouldEmit else { return }

        if activeStall == nil {
            nextStallSequence &+= 1
            activeStall = ActiveStall(sequence: nextStallSequence, startedNs: startedNs)
        }
        lastStallLogUptimeNs = nowNs

        let footprintMB = Self.currentFootprintMB()
        onStall?(
            MainThreadStallContext(
                sequence: activeStall?.sequence ?? probeID,
                thresholdMs: thresholdMs,
                detectedAtMs: Date.nowMs(),
                footprintMB: footprintMB
            )
        )
    }

    private func probeDidComplete(startedNs: UInt64, completedNs: UInt64) {
        guard let stall = activeStall, completedNs >= stall.startedNs else { return }
        activeStall = nil

        let durationMs = Int((completedNs &- stall.startedNs) / 1_000_000)
        onRecovery?(
            MainThreadStallRecoveryContext(
                sequence: stall.sequence,
                durationMs: durationMs,
                recoveredAtMs: Date.nowMs()
            )
        )
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

private struct MetricKitUploadMetadata: Sendable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
}

private actor MetricKitUploadQueue {
    private var apiClient: APIClient?
    private var metadata: MetricKitUploadMetadata?
    private var backlog: [MetricKitPayloadItem] = []
    private var uploading = false

    private let maxPending = 240
    private let maxBatchSize = 30

    func setClient(_ client: APIClient?) {
        apiClient = client
    }

    func setMetadata(_ metadata: MetricKitUploadMetadata) {
        self.metadata = metadata
    }

    func enqueue(payloads: [MetricKitPayloadItem]) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        guard !payloads.isEmpty else { return }

        backlog.append(contentsOf: payloads)
        if backlog.count > maxPending {
            backlog.removeFirst(backlog.count - maxPending)
        }

        flushIfNeeded()
    }

    func flushIfNeeded() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        if uploading {
            return
        }

        Task {
            await self.flush()
        }
    }

    func clear() {
        apiClient = nil
        backlog.removeAll(keepingCapacity: true)
    }

    private func flush() async {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        if uploading { return }
        uploading = true
        defer { uploading = false }

        guard let metadata else {
            metricKitLog.debug("Skipping upload: missing metadata")
            return
        }

        guard let apiClient else {
            metricKitLog.debug("Skipping upload: no API client")
            return
        }

        while !backlog.isEmpty {
            guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
                clear()
                return
            }
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = MetricKitUploadRequest(
                generatedAt: Date.nowMs(),
                appVersion: metadata.appVersion,
                buildNumber: metadata.buildNumber,
                osVersion: metadata.osVersion,
                deviceModel: metadata.deviceModel,
                clientKind: .ios,
                appInstanceId: ClientLogUploadService.appInstanceId,
                bootId: ClientLogUploadService.bootId,
                payloads: batch
            )

            do {
                try await apiClient.uploadMetricKitPayload(request: request)
                metricKitLog.debug("Uploaded metrickit batch size=\(batch.count)")
            } catch {
                backlog = batch + backlog
                metricKitLog.error("MetricKit upload failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

}

// MARK: - Crash context

struct MetricKitCrashContext: Codable, Equatable, Sendable {
    let recordedAtMs: Int64
    let sessionId: String?
    let workspaceId: String?
    let streamState: String
    let lastTimelinePayloadRecordedAtMs: Int64?
    let lastTimelinePayloadBytes: Int?
    let lastTimelinePayloadEventCount: Int?
    let lastTimelinePayloadLargestEventBytes: Int?
    let activeServerId: String?
    let screen: String?
    let scenePhase: String?
    let lifecycleEvent: String?
    let lifecycleStep: String?
    let lifecycleRecordedAtMs: Int64?
    let lastStallRecordedAtMs: Int64?
    let lastStallRecoveredAtMs: Int64?
    let lastStallThresholdMs: Int?
    let lastStallDurationMs: Int?
    let lastStallFootprintMB: Int?
    let lastStallSequence: Int?
}

protocol MetricKitCrashContextPersisting: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeObject(forKey key: String)
}

private struct UserDefaultsCrashContextPersistence: MetricKitCrashContextPersisting, @unchecked Sendable {
    func data(forKey key: String) -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    func set(_ data: Data, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
    }

    func removeObject(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum MetricKitCrashContextStore {
    static let currentContextKey = "oppi.diagnostics.lastActiveContext.v1"
    private static let postMortemContextKey = "oppi.diagnostics.previousProcessContext.v1"
    private static let lock = NSLock()
    private static let persistenceQueue = DispatchQueue(
        label: "\(AppIdentifiers.subsystem).crash-context-persistence",
        qos: .userInitiated
    )
    nonisolated(unsafe) private static var persistenceOverride: MetricKitCrashContextPersisting?
    nonisolated(unsafe) private static var currentContext: MetricKitCrashContext?
    nonisolated(unsafe) private static var postMortemContext: MetricKitCrashContext?
    nonisolated(unsafe) private static var nextGeneration: UInt64 = 0
    nonisolated(unsafe) private static var lastPersistedGeneration: UInt64 = 0
    nonisolated(unsafe) private static var initializedCurrentProcessContext = false
    private static let launchCurrentContext = decode(
        UserDefaultsCrashContextPersistence().data(forKey: currentContextKey)
    )
    private static let launchPostMortemContext = decode(
        UserDefaultsCrashContextPersistence().data(forKey: postMortemContextKey)
    )
    private static let launchRotationScheduled: Void = {
        let previous = launchCurrentContext
        persistenceQueue.async {
            let persistence = UserDefaultsCrashContextPersistence()
            if let previous, let data = try? JSONEncoder().encode(previous) {
                persistence.set(data, forKey: postMortemContextKey)
            }
            persistence.removeObject(forKey: currentContextKey)
        }
    }()

    static func record(sessionId: String?, workspaceId: String?, streamState: String) {
        update { previous in
            MetricKitCrashContext(
                recordedAtMs: Date.nowMs(),
                sessionId: clean(sessionId),
                workspaceId: clean(workspaceId),
                streamState: clean(streamState) ?? "unknown",
                lastTimelinePayloadRecordedAtMs: previous?.lastTimelinePayloadRecordedAtMs,
                lastTimelinePayloadBytes: previous?.lastTimelinePayloadBytes,
                lastTimelinePayloadEventCount: previous?.lastTimelinePayloadEventCount,
                lastTimelinePayloadLargestEventBytes: previous?.lastTimelinePayloadLargestEventBytes,
                activeServerId: previous?.activeServerId,
                screen: previous?.screen,
                scenePhase: previous?.scenePhase,
                lifecycleEvent: previous?.lifecycleEvent,
                lifecycleStep: previous?.lifecycleStep,
                lifecycleRecordedAtMs: previous?.lifecycleRecordedAtMs,
                lastStallRecordedAtMs: previous?.lastStallRecordedAtMs,
                lastStallRecoveredAtMs: previous?.lastStallRecoveredAtMs,
                lastStallThresholdMs: previous?.lastStallThresholdMs,
                lastStallDurationMs: previous?.lastStallDurationMs,
                lastStallFootprintMB: previous?.lastStallFootprintMB,
                lastStallSequence: previous?.lastStallSequence
            )
        }
    }

    static func recordAppContext(
        sessionId: String?,
        workspaceId: String?,
        activeServerId: String?,
        screen: String,
        scenePhase: String,
        lifecycleEvent: String? = nil,
        lifecycleStep: String? = nil
    ) {
        let nowMs = Date.nowMs()
        update { previous in
            let hasLifecycleUpdate = lifecycleEvent != nil || lifecycleStep != nil
            return MetricKitCrashContext(
                recordedAtMs: nowMs,
                sessionId: clean(sessionId),
                workspaceId: clean(workspaceId),
                streamState: previous?.streamState ?? "unknown",
                lastTimelinePayloadRecordedAtMs: previous?.lastTimelinePayloadRecordedAtMs,
                lastTimelinePayloadBytes: previous?.lastTimelinePayloadBytes,
                lastTimelinePayloadEventCount: previous?.lastTimelinePayloadEventCount,
                lastTimelinePayloadLargestEventBytes: previous?.lastTimelinePayloadLargestEventBytes,
                activeServerId: clean(activeServerId),
                screen: clean(screen),
                scenePhase: clean(scenePhase),
                lifecycleEvent: clean(lifecycleEvent) ?? previous?.lifecycleEvent,
                lifecycleStep: clean(lifecycleStep) ?? previous?.lifecycleStep,
                lifecycleRecordedAtMs: hasLifecycleUpdate ? nowMs : previous?.lifecycleRecordedAtMs,
                lastStallRecordedAtMs: previous?.lastStallRecordedAtMs,
                lastStallRecoveredAtMs: previous?.lastStallRecoveredAtMs,
                lastStallThresholdMs: previous?.lastStallThresholdMs,
                lastStallDurationMs: previous?.lastStallDurationMs,
                lastStallFootprintMB: previous?.lastStallFootprintMB,
                lastStallSequence: previous?.lastStallSequence
            )
        }
    }

    @discardableResult
    static func recordMainThreadStall(thresholdMs: Int, footprintMB: Int?, sequence: Int) -> [String: String] {
        let nowMs = Date.nowMs()
        let context = update { previous in
            MetricKitCrashContext(
                recordedAtMs: nowMs,
                sessionId: previous?.sessionId,
                workspaceId: previous?.workspaceId,
                streamState: previous?.streamState ?? "unknown",
                lastTimelinePayloadRecordedAtMs: previous?.lastTimelinePayloadRecordedAtMs,
                lastTimelinePayloadBytes: previous?.lastTimelinePayloadBytes,
                lastTimelinePayloadEventCount: previous?.lastTimelinePayloadEventCount,
                lastTimelinePayloadLargestEventBytes: previous?.lastTimelinePayloadLargestEventBytes,
                activeServerId: previous?.activeServerId,
                screen: previous?.screen,
                scenePhase: previous?.scenePhase,
                lifecycleEvent: previous?.lifecycleEvent,
                lifecycleStep: previous?.lifecycleStep,
                lifecycleRecordedAtMs: previous?.lifecycleRecordedAtMs,
                lastStallRecordedAtMs: nowMs,
                lastStallRecoveredAtMs: nil,
                lastStallThresholdMs: thresholdMs,
                lastStallDurationMs: nil,
                lastStallFootprintMB: footprintMB,
                lastStallSequence: sequence
            )
        }
        return metadata(from: context)
    }

    @discardableResult
    static func recordMainThreadStallRecovery(sequence: Int, durationMs: Int) -> [String: String] {
        let nowMs = Date.nowMs()
        let context = update { previous in
            MetricKitCrashContext(
                recordedAtMs: nowMs,
                sessionId: previous?.sessionId,
                workspaceId: previous?.workspaceId,
                streamState: previous?.streamState ?? "unknown",
                lastTimelinePayloadRecordedAtMs: previous?.lastTimelinePayloadRecordedAtMs,
                lastTimelinePayloadBytes: previous?.lastTimelinePayloadBytes,
                lastTimelinePayloadEventCount: previous?.lastTimelinePayloadEventCount,
                lastTimelinePayloadLargestEventBytes: previous?.lastTimelinePayloadLargestEventBytes,
                activeServerId: previous?.activeServerId,
                screen: previous?.screen,
                scenePhase: previous?.scenePhase,
                lifecycleEvent: previous?.lifecycleEvent,
                lifecycleStep: previous?.lifecycleStep,
                lifecycleRecordedAtMs: previous?.lifecycleRecordedAtMs,
                lastStallRecordedAtMs: previous?.lastStallRecordedAtMs,
                lastStallRecoveredAtMs: nowMs,
                lastStallThresholdMs: previous?.lastStallThresholdMs,
                lastStallDurationMs: durationMs,
                lastStallFootprintMB: previous?.lastStallFootprintMB,
                lastStallSequence: sequence
            )
        }
        return metadata(from: context)
    }

    static func recordLargeTimelinePayload(
        sessionId: String?,
        eventCount: Int,
        bytes: Int,
        largestEventBytes: Int
    ) {
        update { previous in
            MetricKitCrashContext(
                recordedAtMs: previous?.recordedAtMs ?? Date.nowMs(),
                sessionId: clean(sessionId) ?? previous?.sessionId,
                workspaceId: previous?.workspaceId,
                streamState: previous?.streamState ?? "unknown",
                lastTimelinePayloadRecordedAtMs: Date.nowMs(),
                lastTimelinePayloadBytes: bytes,
                lastTimelinePayloadEventCount: eventCount,
                lastTimelinePayloadLargestEventBytes: largestEventBytes,
                activeServerId: previous?.activeServerId,
                screen: previous?.screen,
                scenePhase: previous?.scenePhase,
                lifecycleEvent: previous?.lifecycleEvent,
                lifecycleStep: previous?.lifecycleStep,
                lifecycleRecordedAtMs: previous?.lifecycleRecordedAtMs,
                lastStallRecordedAtMs: previous?.lastStallRecordedAtMs,
                lastStallRecoveredAtMs: previous?.lastStallRecoveredAtMs,
                lastStallThresholdMs: previous?.lastStallThresholdMs,
                lastStallDurationMs: previous?.lastStallDurationMs,
                lastStallFootprintMB: previous?.lastStallFootprintMB,
                lastStallSequence: previous?.lastStallSequence
            )
        }
    }

    static func snapshot() -> MetricKitCrashContext? {
        initializeCurrentProcessContextIfNeeded()
        return lock.withLock { currentContext }
    }

    static func snapshotMetadata() -> [String: String] {
        guard let context = snapshot() else { return [:] }
        return metadata(from: context)
    }

    static func postMortemSnapshotMetadata() -> [String: String] {
        initializeCurrentProcessContextIfNeeded()
        guard let context = lock.withLock({ postMortemContext ?? currentContext }) else {
            return [:]
        }
        return metadata(from: context)
    }

    // periphery:ignore - used by MetricKit serializer tests via @testable import
    static func clearForTesting() {
        persistenceQueue.sync {}
        lock.withLock {
            currentContext = nil
            postMortemContext = nil
            nextGeneration = 0
            initializedCurrentProcessContext = true
        }
        persistenceQueue.sync {
            persistence.removeObject(forKey: currentContextKey)
            persistence.removeObject(forKey: postMortemContextKey)
            lastPersistedGeneration = 0
        }
    }

    // periphery:ignore - simulates a process boundary without discarding persisted defaults
    static func simulateProcessRelaunchForTesting() {
        persistenceQueue.sync {}
        let previous = lock.withLock { () -> MetricKitCrashContext? in
            let previous = currentContext
            postMortemContext = previous ?? postMortemContext
            currentContext = nil
            nextGeneration = 0
            initializedCurrentProcessContext = true
            return previous
        }
        persistenceQueue.sync {
            if let previous, let data = try? JSONEncoder().encode(previous) {
                persistence.set(data, forKey: postMortemContextKey)
            }
            persistence.removeObject(forKey: currentContextKey)
            lastPersistedGeneration = 0
        }
    }

    // periphery:ignore - deterministic reentrant-persistence regression support
    static func setPersistenceForTesting(_ persistence: MetricKitCrashContextPersisting?) {
        persistenceQueue.sync {
            persistenceOverride = persistence
        }
    }

    // periphery:ignore - waits for writes enqueued by synchronous persistence re-entry too
    static func waitForPersistenceForTesting() async {
        while true {
            let persistedGeneration = await withCheckedContinuation { continuation in
                persistenceQueue.async {
                    continuation.resume(returning: lastPersistedGeneration)
                }
            }
            let latestGeneration = lock.withLock { nextGeneration }
            if persistedGeneration >= latestGeneration {
                return
            }
        }
    }

    @discardableResult
    private static func update(_ build: (MetricKitCrashContext?) -> MetricKitCrashContext) -> MetricKitCrashContext {
        initializeCurrentProcessContextIfNeeded()
        let versionedContext = lock.withLock { () -> (generation: UInt64, context: MetricKitCrashContext) in
            nextGeneration &+= 1
            let context = build(currentContext)
            currentContext = context
            return (nextGeneration, context)
        }
        schedulePersistence(versionedContext)
        return versionedContext.context
    }

    private static var persistence: MetricKitCrashContextPersisting {
        persistenceOverride ?? UserDefaultsCrashContextPersistence()
    }

    private static func initializeCurrentProcessContextIfNeeded() {
        // Accessing this thread-safe static first guarantees launch rotation was
        // enqueued before any current-process persistence write can be enqueued.
        _ = launchRotationScheduled
        lock.withLock {
            guard !initializedCurrentProcessContext else { return }
            initializedCurrentProcessContext = true
            postMortemContext = previousProcessContext(
                current: launchCurrentContext,
                existingPostMortem: launchPostMortemContext
            )
        }
    }

    private static func schedulePersistence(
        _ versionedContext: (generation: UInt64, context: MetricKitCrashContext)
    ) {
        guard let data = try? JSONEncoder().encode(versionedContext.context) else { return }
        persistenceQueue.async {
            guard versionedContext.generation > lastPersistedGeneration else { return }
            persistence.set(data, forKey: currentContextKey)
            lastPersistedGeneration = versionedContext.generation
        }
    }

    // The current key belongs to the immediately previous process. The
    // postmortem key is only a fallback retained from an older rotation.
    static func previousProcessContext(
        current: MetricKitCrashContext?,
        existingPostMortem: MetricKitCrashContext?
    ) -> MetricKitCrashContext? {
        current ?? existingPostMortem
    }

    private static func decode(_ data: Data?) -> MetricKitCrashContext? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(MetricKitCrashContext.self, from: data)
    }

    private static func metadata(from context: MetricKitCrashContext) -> [String: String] {
        var metadata: [String: String] = [
            "lastContextRecordedAtMs": String(context.recordedAtMs),
            "lastStreamState": context.streamState,
        ]
        add(context.sessionId, key: "lastSessionId", to: &metadata)
        add(context.workspaceId, key: "lastWorkspaceId", to: &metadata)
        add(context.lastTimelinePayloadRecordedAtMs, key: "lastTimelinePayloadRecordedAtMs", to: &metadata)
        add(context.lastTimelinePayloadBytes, key: "lastTimelinePayloadBytes", to: &metadata)
        add(context.lastTimelinePayloadEventCount, key: "lastTimelinePayloadEventCount", to: &metadata)
        add(context.lastTimelinePayloadLargestEventBytes, key: "lastTimelinePayloadLargestEventBytes", to: &metadata)
        add(context.activeServerId, key: "lastActiveServerId", to: &metadata)
        add(context.screen, key: "lastScreen", to: &metadata)
        add(context.scenePhase, key: "lastScenePhase", to: &metadata)
        add(context.lifecycleEvent, key: "lastLifecycleEvent", to: &metadata)
        add(context.lifecycleStep, key: "lastLifecycleStep", to: &metadata)
        add(context.lifecycleRecordedAtMs, key: "lastLifecycleRecordedAtMs", to: &metadata)
        add(context.lastStallRecordedAtMs, key: "lastStallRecordedAtMs", to: &metadata)
        add(context.lastStallRecoveredAtMs, key: "lastStallRecoveredAtMs", to: &metadata)
        add(context.lastStallThresholdMs, key: "lastStallThresholdMs", to: &metadata)
        add(context.lastStallDurationMs, key: "lastStallDurationMs", to: &metadata)
        add(context.lastStallFootprintMB, key: "lastStallFootprintMB", to: &metadata)
        add(context.lastStallSequence, key: "lastStallSequence", to: &metadata)
        return metadata
    }

    private static func add(_ value: String?, key: String, to metadata: inout [String: String]) {
        guard let value, !value.isEmpty else { return }
        metadata[key] = value
    }

    private static func add(_ value: Int64?, key: String, to metadata: inout [String: String]) {
        guard let value else { return }
        metadata[key] = String(value)
    }

    private static func add(_ value: Int?, key: String, to metadata: inout [String: String]) {
        guard let value else { return }
        metadata[key] = String(value)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(128))
    }
}

// MARK: - Payload item builder (internal for testing)

/// Converts a dictionary (from MX*.jsonRepresentation()) into a MetricKitPayloadItem.
/// Internal visibility so tests can exercise the summary/raw pipeline directly
/// without needing real MXMetricPayload instances (which only the system creates).
enum MetricKitPayloadItemBuilder {
    static let requiredDiagnosticContextKeys = [
        "lastContextRecordedAtMs",
        "lastSessionId",
        "lastWorkspaceId",
        "lastActiveServerId",
        "lastScreen",
        "lastScenePhase",
        "lastLifecycleEvent",
        "lastLifecycleStep",
        "lastLifecycleRecordedAtMs",
        "lastStallRecordedAtMs",
        "lastStallRecoveredAtMs",
        "lastStallThresholdMs",
        "lastStallDurationMs",
        "lastStallFootprintMB",
        "lastStallSequence",
        "lastStreamState",
    ]

    static func makeItem(
        from snapshot: [String: Any],
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64,
        context: [String: String] = [:]
    ) -> MetricKitPayloadItem {
        var enrichedSnapshot = snapshot
        if !context.isEmpty {
            enrichedSnapshot["oppiDiagnosticContext"] = context
        }

        let summary = summarize(enrichedSnapshot, context: context)
        return MetricKitPayloadItem(
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            summary: summary,
            raw: ["payload": jsonString(from: enrichedSnapshot)]
        )
    }

    private static func summarize(_ snapshot: [String: Any], context: [String: String]) -> [String: String] {
        var out: [String: String] = [
            "source": snapshot["type"] as? String ?? "MetricKit"
        ]

        addDiagnosticCounts(from: snapshot, to: &out)
        for key in requiredDiagnosticContextKeys {
            guard out.count < 24 else { break }
            if let value = context[key] {
                out[key] = String(value.prefix(140))
            }
        }
        for key in context.keys.sorted() where !requiredDiagnosticContextKeys.contains(key) {
            guard out.count < 24 else { break }
            guard !key.isEmpty, let value = context[key] else { continue }
            out[key] = String(value.prefix(140))
        }

        for (key, value) in snapshot {
            guard out.count < 24, !key.isEmpty else { continue }
            let safeKey = String(key.prefix(64))
            if out[safeKey] == nil {
                out[safeKey] = summarizeValue(value)
            }
        }

        return out
    }

    private static func addDiagnosticCounts(from snapshot: [String: Any], to out: inout [String: String]) {
        let fields = [
            ("crashDiagnostics", "crashDiagnosticCount"),
            ("hangDiagnostics", "hangDiagnosticCount"),
            ("cpuExceptionDiagnostics", "cpuExceptionDiagnosticCount"),
            ("diskWriteExceptionDiagnostics", "diskWriteExceptionDiagnosticCount"),
            ("appLaunchDiagnostics", "appLaunchDiagnosticCount"),
        ]

        for (payloadKey, summaryKey) in fields {
            if let diagnostics = snapshot[payloadKey] as? [Any] {
                out[summaryKey] = String(diagnostics.count)
            }
        }
    }

    private static func summarizeValue(_ value: Any) -> String {
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            return String(string.prefix(140))
        }
        if let date = value as? Date {
            return date.ISO8601Format()
        }
        if let dict = value as? [String: Any] {
            return String(
                String(jsonString(from: dict).prefix(140))
            )
        }
        return String(String(describing: value).prefix(140))
    }

    private static func jsonString(from value: Any) -> String {
        let jsonObject = convertForJSON(value)
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            return String(describing: value)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return String(describing: value)
        }
    }

    private static func convertForJSON(_ value: Any) -> Any {
        if let value = value as? NSNumber {
            return value
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Date {
            return value.timeIntervalSince1970
        }
        if let value = value as? [String: Any] {
            return value.reduce(into: [String: Any]()) { partial, entry in
                partial[String(entry.key)] = convertForJSON(entry.value)
            }
        }
        if let value = value as? [Any] {
            return value.map(convertForJSON)
        }
        return String(describing: value)
    }
}

// MARK: - MX* payload → dictionary (private, thin layer over Apple's API)

private enum MetricKitPayloadSerializer {
    static func item(
        from payload: MXMetricPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) -> MetricKitPayloadItem {
        MetricKitPayloadItemBuilder.makeItem(
            from: dictionaryFrom(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs
        )
    }

    static func item(
        from payload: MXDiagnosticPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64,
        context: [String: String] = [:]
    ) -> MetricKitPayloadItem {
        MetricKitPayloadItemBuilder.makeItem(
            from: dictionaryFrom(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            context: context
        )
    }

    private static func dictionaryFrom(_ payload: MXMetricPayload) -> [String: Any] {
        let data = payload.jsonRepresentation()
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return ["type": "MXMetricPayload", "error": "json_parse_failed"]
    }

    private static func dictionaryFrom(_ payload: MXDiagnosticPayload) -> [String: Any] {
        let data = payload.jsonRepresentation()
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return ["type": "MXDiagnosticPayload", "error": "json_parse_failed"]
    }
}

actor ChatMetricsService {
    static let shared = ChatMetricsService()

    private var apiClient: APIClient?
    private var metadata: MetricKitUploadMetadata?
    private var backlog: [ChatMetricSample] = []
    private var flushing = false
    private var flushTask: Task<Void, Never>?

    private let maxPending = 1_000
    private let maxBatchSize = 50
    private let flushInterval: Duration = .seconds(10)

    private init() {}

    func setUploadClient(_ client: APIClient?) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            apiClient = nil
            backlog.removeAll(keepingCapacity: true)
            flushTask?.cancel()
            flushTask = nil
            return
        }

        apiClient = client
        if metadata == nil {
            metadata = MetricKitService.makeMetadata()
        }

        guard client != nil else {
            return
        }

        flushIfNeeded()
    }

    func record(
        metric: ChatMetricName,
        value: Double,
        unit: ChatMetricUnit,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        tags: [String: String] = [:],
        timestampMs: Int64 = Date.nowMs()
    ) {
        guard value.isFinite else { return }
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        var trimmedTags: [String: String]? = nil
        if !tags.isEmpty {
            var out: [String: String] = [:]
            out.reserveCapacity(min(tags.count, 16))
            for (key, tagValue) in tags {
                if out.count >= 16 { break }
                let cleanKey = String(key.prefix(96))
                guard !cleanKey.isEmpty else { continue }
                out[cleanKey] = String(tagValue.prefix(256))
            }
            if !out.isEmpty {
                trimmedTags = out
            }
        }

        let sample = ChatMetricSample(
            ts: timestampMs,
            metric: metric,
            value: value,
            unit: unit,
            sessionId: sessionId.flatMap { $0.isEmpty ? nil : String($0.prefix(96)) },
            workspaceId: workspaceId.flatMap { $0.isEmpty ? nil : String($0.prefix(96)) },
            tags: trimmedTags
        )

        backlog.append(sample)
        if backlog.count > maxPending {
            backlog.removeFirst(backlog.count - maxPending)
        }

        if backlog.count >= maxBatchSize {
            flushIfNeeded()
        } else {
            scheduleFlushTimerIfNeeded()
        }
    }

    func flushIfNeeded() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        guard !flushing else { return }
        guard !backlog.isEmpty else { return }

        Task { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            backlog.removeAll(keepingCapacity: true)
            return
        }

        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        flushTask?.cancel()
        flushTask = nil

        guard let metadata else {
            return
        }

        guard let apiClient else {
            scheduleFlushTimerIfNeeded()
            return
        }

        while !backlog.isEmpty {
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = ChatMetricUploadRequest(
                generatedAt: Date.nowMs(),
                appVersion: metadata.appVersion,
                buildNumber: metadata.buildNumber,
                osVersion: metadata.osVersion,
                deviceModel: metadata.deviceModel,
                samples: batch
            )

            do {
                try await apiClient.uploadChatMetrics(request: request)
            } catch {
                backlog = batch + backlog
                scheduleFlushTimerIfNeeded()
                return
            }
        }
    }

    private func scheduleFlushTimerIfNeeded() {
        guard flushTask == nil else { return }

        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.flushInterval ?? .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.flushTaskFired()
        }
    }

    private func flushTaskFired() {
        flushTask = nil
        flushIfNeeded()
    }


}
