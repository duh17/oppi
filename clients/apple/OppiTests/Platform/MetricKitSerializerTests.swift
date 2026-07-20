import Foundation
import Testing
@testable import Oppi

/// Tests for MetricKit payload serialization.
///
/// We can't create real MXMetricPayload/MXDiagnosticPayload in tests — those come
/// from the system. But the core pipeline is: dictionary -> MetricKitPayloadItem.
/// That's what we test here, using dictionaries that match real jsonRepresentation() output.
@Suite("MetricKit serializer", .serialized)
struct MetricKitSerializerTests {

    // MARK: - Metric payloads

    @Test func metricPayloadPreservesAllTopLevelKeys() {
        let dict: [String: Any] = [
            "appVersion": "1.0.0",
            "cpuMetrics": ["cumulativeCPUTime": "6879 sec", "cumulativeCPUInstructions": "50204015744 kiloinstructions"],
            "applicationTimeMetrics": ["cumulativeForegroundTime": "38371 sec", "cumulativeBackgroundTime": "1552 sec"],
            "displayMetrics": ["averagePixelLuminance": ["averageValue": "120 apl"]],
            "gpuMetrics": ["cumulativeGPUTime": "450 sec"],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 1000,
            windowEndMs: 2000
        )

        #expect(item.kind == .metric)
        #expect(item.windowStartMs == 1000)
        #expect(item.windowEndMs == 2000)

        // Raw payload must contain the original keys as parseable JSON
        let rawPayload = item.raw["payload"] ?? ""
        #expect(!rawPayload.isEmpty, "raw payload must not be empty")

        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed != nil, "raw payload must be valid JSON")
        #expect(parsed?["cpuMetrics"] != nil, "cpuMetrics must survive serialization")
        #expect(parsed?["applicationTimeMetrics"] != nil, "applicationTimeMetrics must survive")
        #expect(parsed?["gpuMetrics"] != nil, "gpuMetrics must survive")
    }

    @Test func metricPayloadSummaryIncludesTopLevelKeys() {
        let dict: [String: Any] = [
            "cpuMetrics": ["cumulativeCPUTime": "6879 sec"],
            "diskIOMetrics": ["cumulativeLogicalWrites": "150 MB"],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // Summary should have entries for each top-level key
        #expect(item.summary["cpuMetrics"] != nil)
        #expect(item.summary["diskIOMetrics"] != nil)
        #expect(item.summary["source"] == "MetricKit", "missing type key falls back to MetricKit")
    }

    // MARK: - Diagnostic payloads

    @Test func diagnosticPayloadPreservesCPUExceptions() {
        let dict: [String: Any] = [
            "cpuExceptionDiagnostics": [
                [
                    "callStackTree": ["callStackPerThread": false],
                    "totalCPUTime": "120 sec",
                ]
            ],
            "timeStampBegin": "2026-03-27 00:00:00 +0000",
            "timeStampEnd": "2026-03-28 00:00:00 +0000",
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .diagnostic,
            windowStartMs: 5000,
            windowEndMs: 6000
        )

        #expect(item.kind == .diagnostic)
        #expect(item.summary["cpuExceptionDiagnosticCount"] == "1")

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed?["cpuExceptionDiagnostics"] != nil, "CPU exception diagnostics must survive")
    }

    @Test func diagnosticPayloadAddsCrashCountsAndLastContext() {
        let dict: [String: Any] = [
            "crashDiagnostics": [
                [
                    "signal": 11,
                    "callStackTree": ["callStackPerThread": true],
                ]
            ],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .diagnostic,
            windowStartMs: 5000,
            windowEndMs: 6000,
            context: [
                "lastSessionId": "session-1",
                "lastWorkspaceId": "workspace-1",
                "lastStreamState": "streaming",
            ]
        )

        #expect(item.summary["crashDiagnosticCount"] == "1")
        #expect(item.summary["lastSessionId"] == "session-1")
        #expect(item.summary["lastWorkspaceId"] == "workspace-1")
        #expect(item.summary["lastStreamState"] == "streaming")

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        let context = parsed?["oppiDiagnosticContext"] as? [String: String]
        #expect(context?["lastSessionId"] == "session-1")
    }

    @Test func crashContextIncludesLargeTimelinePayloadBreadcrumbs() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.record(
            sessionId: "session-large",
            workspaceId: "workspace-1",
            streamState: "streaming"
        )
        MetricKitCrashContextStore.recordLargeTimelinePayload(
            sessionId: "session-large",
            eventCount: 1,
            bytes: 14_500_000,
            largestEventBytes: 14_500_000
        )

        let metadata = MetricKitCrashContextStore.snapshotMetadata()

        #expect(metadata["lastSessionId"] == "session-large")
        #expect(metadata["lastWorkspaceId"] == "workspace-1")
        #expect(metadata["lastStreamState"] == "streaming")
        #expect(metadata["lastTimelinePayloadBytes"] == "14500000")
        #expect(metadata["lastTimelinePayloadEventCount"] == "1")
        #expect(metadata["lastTimelinePayloadLargestEventBytes"] == "14500000")
    }

    @Test func appCoalescerTelemetryRecordsFlushesAndCrashBreadcrumbs() async {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.record(
            sessionId: "session-coalescer",
            workspaceId: "workspace-telemetry",
            streamState: "streaming"
        )

        await DeltaCoalescerTelemetry.appMetrics.recordFlushWindow(
            DeltaCoalescerFlushWindow(
                sessionId: "session-coalescer",
                eventCount: 3,
                byteCount: 1_024,
                flushCount: 2
            )
        )
        DeltaCoalescerTelemetry.appMetrics.recordLargeTimelinePayload(
            DeltaCoalescerLargeTimelinePayload(
                sessionId: "session-coalescer",
                eventCount: 3,
                byteCount: 1_024,
                largestEventByteCount: 512
            )
        )

        let metadata = MetricKitCrashContextStore.snapshotMetadata()

        #expect(metadata["lastSessionId"] == "session-coalescer")
        #expect(metadata["lastWorkspaceId"] == "workspace-telemetry")
        #expect(metadata["lastTimelinePayloadBytes"] == "1024")
        #expect(metadata["lastTimelinePayloadEventCount"] == "3")
        #expect(metadata["lastTimelinePayloadLargestEventBytes"] == "512")
    }

    @Test func crashContextIncludesAppLifecycleAndStallBreadcrumbs() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.recordAppContext(
            sessionId: nil,
            workspaceId: "workspace-list",
            activeServerId: "server-1",
            screen: "workspace_inbox_filtered",
            scenePhase: "background",
            lifecycleEvent: "scene_phase",
            lifecycleStep: "prepare_for_background_begin"
        )
        MetricKitCrashContextStore.recordMainThreadStall(
            thresholdMs: 700,
            footprintMB: 73,
            sequence: 2
        )
        MetricKitCrashContextStore.recordMainThreadStallRecovery(
            sequence: 2,
            durationMs: 9_121
        )

        let metadata = MetricKitCrashContextStore.snapshotMetadata()

        #expect(metadata["lastSessionId"] == nil)
        #expect(metadata["lastWorkspaceId"] == "workspace-list")
        #expect(metadata["lastActiveServerId"] == "server-1")
        #expect(metadata["lastScreen"] == "workspace_inbox_filtered")
        #expect(metadata["lastScenePhase"] == "background")
        #expect(metadata["lastLifecycleEvent"] == "scene_phase")
        #expect(metadata["lastLifecycleStep"] == "prepare_for_background_begin")
        #expect(metadata["lastStallThresholdMs"] == "700")
        #expect(metadata["lastStallFootprintMB"] == "73")
        #expect(metadata["lastStallSequence"] == "2")
        #expect(metadata["lastStallDurationMs"] == "9121")
    }

    @Test func newStallClearsRecoveryMetadataFromPreviousStall() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.recordMainThreadStall(
            thresholdMs: 700,
            footprintMB: 73,
            sequence: 1
        )
        MetricKitCrashContextStore.recordMainThreadStallRecovery(sequence: 1, durationMs: 2_400)

        MetricKitCrashContextStore.recordMainThreadStall(
            thresholdMs: 700,
            footprintMB: 75,
            sequence: 2
        )

        let metadata = MetricKitCrashContextStore.snapshotMetadata()
        #expect(metadata["lastStallSequence"] == "2")
        #expect(metadata["lastStallRecoveredAtMs"] == nil)
        #expect(metadata["lastStallDurationMs"] == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func reentrantPersistenceCannotDeadlockCrashContextRecording() async {
        let persistence = ReentrantCrashContextPersistence()
        let didReenter = LockedFlag()
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.setPersistenceForTesting(persistence)
        defer {
            MetricKitCrashContextStore.setPersistenceForTesting(nil)
            MetricKitCrashContextStore.clearForTesting()
        }

        persistence.onSave = { key in
            guard key == MetricKitCrashContextStore.currentContextKey,
                  didReenter.claim() else { return }

            // Reproduce the production watchdog stack: persisting queue-sync state
            // synchronously re-enters lifecycle recording before the save returns.
            MetricKitCrashContextStore.recordAppContext(
                sessionId: "session-reentrant",
                workspaceId: "workspace-reentrant",
                activeServerId: "server-1",
                screen: "chat",
                scenePhase: "background",
                lifecycleEvent: "scene_phase",
                lifecycleStep: "begin"
            )
        }

        MetricKitCrashContextStore.record(
            sessionId: "session-reentrant",
            workspaceId: "workspace-reentrant",
            streamState: "queueSync.initial"
        )
        await MetricKitCrashContextStore.waitForPersistenceForTesting()

        let current = MetricKitCrashContextStore.snapshotMetadata()
        let persisted = persistence.decodedContext(forKey: MetricKitCrashContextStore.currentContextKey)
        #expect(didReenter.value)
        #expect(current["lastLifecycleStep"] == "begin")
        #expect(persisted?.lifecycleStep == "begin")
        #expect(persisted?.streamState == "queueSync.initial")
    }

    @Test func concurrentCrashContextUpdatesPersistTheNewestSnapshot() async {
        let persistence = ReentrantCrashContextPersistence()
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.setPersistenceForTesting(persistence)
        defer {
            MetricKitCrashContextStore.setPersistenceForTesting(nil)
            MetricKitCrashContextStore.clearForTesting()
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    MetricKitCrashContextStore.record(
                        sessionId: "session-\(index)",
                        workspaceId: "workspace-concurrent",
                        streamState: "state-\(index)"
                    )
                }
            }
        }
        await MetricKitCrashContextStore.waitForPersistenceForTesting()

        let current = MetricKitCrashContextStore.snapshot()
        let persisted = persistence.decodedContext(forKey: MetricKitCrashContextStore.currentContextKey)
        #expect(current != nil)
        #expect(persisted == current)
    }

    @Test func launchPrefersTheImmediatelyPreviousProcessOverOlderPostMortemContext() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.recordAppContext(
            sessionId: "process-n-minus-two",
            workspaceId: "workspace-old",
            activeServerId: "server-1",
            screen: "workspace_inbox_all",
            scenePhase: "background"
        )
        let olderPostMortem = MetricKitCrashContextStore.snapshot()

        MetricKitCrashContextStore.recordAppContext(
            sessionId: "process-n-minus-one",
            workspaceId: "workspace-new",
            activeServerId: "server-1",
            screen: "chat",
            scenePhase: "background"
        )
        let immediatelyPrevious = MetricKitCrashContextStore.snapshot()

        let selected = MetricKitCrashContextStore.previousProcessContext(
            current: immediatelyPrevious,
            existingPostMortem: olderPostMortem
        )
        #expect(selected?.sessionId == "process-n-minus-one")
        #expect(selected?.screen == "chat")
    }

    @Test func previousProcessContextSurvivesFirstContextWriteAfterRelaunch() {
        MetricKitCrashContextStore.clearForTesting()
        MetricKitCrashContextStore.recordAppContext(
            sessionId: "session-before-watchdog",
            workspaceId: "workspace-before-watchdog",
            activeServerId: "server-1",
            screen: "chat",
            scenePhase: "background",
            lifecycleEvent: "scene_phase",
            lifecycleStep: "end"
        )

        MetricKitCrashContextStore.simulateProcessRelaunchForTesting()
        MetricKitCrashContextStore.recordAppContext(
            sessionId: nil,
            workspaceId: nil,
            activeServerId: nil,
            screen: "launch_resolving",
            scenePhase: "active",
            lifecycleEvent: "root",
            lifecycleStep: "appear"
        )

        let current = MetricKitCrashContextStore.snapshotMetadata()
        let postMortem = MetricKitCrashContextStore.postMortemSnapshotMetadata()
        #expect(current["lastScreen"] == "launch_resolving")
        #expect(postMortem["lastSessionId"] == "session-before-watchdog")
        #expect(postMortem["lastWorkspaceId"] == "workspace-before-watchdog")
        #expect(postMortem["lastScreen"] == "chat")
        #expect(postMortem["lastLifecycleStep"] == "end")
    }

    @Test func diagnosticSummaryPrioritizesLifecycleAndStallContextWithinFieldLimit() {
        let requiredContext = Dictionary(
            uniqueKeysWithValues: MetricKitPayloadItemBuilder.requiredDiagnosticContextKeys.map { key in
                (key, "value-\(key)")
            }
        )
        var context = requiredContext
        context["lastTimelinePayloadRecordedAtMs"] = "1"
        context["lastTimelinePayloadBytes"] = "2"
        context["lastTimelinePayloadEventCount"] = "3"
        context["lastTimelinePayloadLargestEventBytes"] = "4"

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: [
                "crashDiagnostics": [[:]],
                "hangDiagnostics": [[:]],
                "cpuExceptionDiagnostics": [[:]],
                "diskWriteExceptionDiagnostics": [[:]],
                "appLaunchDiagnostics": [[:]],
            ],
            kind: .diagnostic,
            windowStartMs: 0,
            windowEndMs: 1,
            context: context
        )

        #expect(item.summary.count <= 24)
        for key in MetricKitPayloadItemBuilder.requiredDiagnosticContextKeys {
            #expect(item.summary[key] == "value-\(key)", "missing required context key \(key)")
        }
    }

    @Test func flushedClientLogsKeepSubmissionOrder() async {
        let uploader = RecordingClientLogUploader()
        let queue = ClientLogUploadQueue(
            clientKind: .ios,
            appInstanceId: "app-1",
            bootId: "boot-1",
            isUploadAllowed: { true },
            nowMs: { 1 },
            flushInterval: .seconds(60)
        )
        await queue.setMetadata(ClientLogUploadMetadata(
            appVersion: "1",
            buildNumber: "1",
            osVersion: "test",
            deviceModel: "test"
        ))
        await queue.setUploader(uploader)
        let dispatcher = ClientLogUploadDispatcher(queue: queue)

        dispatcher.record(level: .info, category: "Lifecycle", message: "begin", metadata: [:])
        dispatcher.record(level: .info, category: "Lifecycle", message: "save", metadata: [:])
        dispatcher.record(level: .info, category: "Lifecycle", message: "end", metadata: [:], flush: true)
        await dispatcher.waitUntilIdleForTesting()

        let entries = await uploader.entries()
        #expect(entries.map(\.message) == ["begin", "save", "end"])
        #expect(entries.map(\.seq) == [1, 2, 3])
    }

    // MARK: - Empty/broken payloads (the old bug)

    @Test func emptyDictionaryProducesMinimalItem() {
        let item = MetricKitPayloadItemBuilder.makeItem(
            from: [:],
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // Even empty dict should produce a valid item
        #expect(item.kind == .metric)
        #expect(item.summary["source"] == "MetricKit")

        // Raw should be parseable (even if empty object)
        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed != nil, "raw must be valid JSON even for empty dict")
    }

    @Test func typeOnlyDictionaryIsTheOldBrokenCase() {
        // This is exactly what the Mirror-based serializer produced:
        // just {"type": "MXMetricPayload"} with no actual metrics.
        let brokenDict: [String: Any] = ["type": "MXMetricPayload"]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: brokenDict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]

        // This documents the broken state — only the type key, no metrics.
        // A real payload from jsonRepresentation() should have 10+ keys.
        #expect(parsed?.count == 1, "type-only dict has just 1 key (the old bug)")
        #expect(item.summary["source"] == "MXMetricPayload")
    }

    // MARK: - Summary truncation

    @Test func summaryCapsAt24Fields() {
        var dict: [String: Any] = [:]
        for i in 0..<30 {
            dict["field_\(i)"] = "value_\(i)"
        }

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // 24 max from dict + 1 for "source" = at most 25, but source counts in the 24 budget
        #expect(item.summary.count <= 24)
    }

    @Test func summaryTruncatesLongValues() {
        let longValue = String(repeating: "x", count: 500)
        let dict: [String: Any] = ["bigField": longValue]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let summarized = item.summary["bigField"] ?? ""
        #expect(summarized.count <= 140, "summary values capped at 140 chars")
    }

    // MARK: - Raw payload JSON fidelity

    @Test func rawPayloadPreservesNestedStructure() {
        let dict: [String: Any] = [
            "cpuMetrics": [
                "cumulativeCPUTime": "6879 sec",
                "cumulativeCPUInstructions": "50204015744 kiloinstructions",
            ] as [String: Any],
            "applicationLaunchMetrics": [
                "histogrammedResumeTime": [
                    "histogramNumBuckets": 3,
                    "histogramValue": [
                        ["bucketStart": "0 ms", "bucketEnd": "500 ms", "bucketCount": 12],
                        ["bucketStart": "500 ms", "bucketEnd": "1000 ms", "bucketCount": 3],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]

        // Nested structure must survive
        let cpuMetrics = parsed?["cpuMetrics"] as? [String: Any]
        #expect(cpuMetrics?["cumulativeCPUTime"] as? String == "6879 sec")

        let launchMetrics = parsed?["applicationLaunchMetrics"] as? [String: Any]
        let resumeTime = launchMetrics?["histogrammedResumeTime"] as? [String: Any]
        #expect(resumeTime?["histogramNumBuckets"] as? Int == 3)
    }
}

@Suite("Main thread lag watchdog")
struct MainThreadLagWatchdogTests {
    @Test func foregroundRestartInvalidatesDelayedStop() async {
        let watchdog = MainThreadLagWatchdog()
        let evaluations = AsyncStream<Void> { continuation in
            watchdog.onDelayedStopEvaluationForTesting = {
                continuation.yield()
                continuation.finish()
            }
        }
        var iterator = evaluations.makeAsyncIterator()

        watchdog.start()
        watchdog.stopAfterGracePeriod(10)
        watchdog.start()

        let evaluation = await iterator.next()
        #expect(evaluation != nil)
        #expect(watchdog.isRunningForTesting())
        watchdog.stop()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }

    func claim() -> Bool {
        lock.withLock {
            guard !storage else { return false }
            storage = true
            return true
        }
    }
}

private final class ReentrantCrashContextPersistence: MetricKitCrashContextPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    var onSave: (@Sendable (String) -> Void)?

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func set(_ data: Data, forKey key: String) {
        lock.withLock { storage[key] = data }
        onSave?(key)
    }

    func removeObject(forKey key: String) {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    func decodedContext(forKey key: String) -> MetricKitCrashContext? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MetricKitCrashContext.self, from: data)
    }
}

private actor RecordingClientLogUploader: ClientLogUploading {
    private var uploadedEntries: [ClientLogUploadEntry] = []

    func uploadClientLogs(request: ClientLogUploadRequest) async throws {
        uploadedEntries.append(contentsOf: request.entries)
    }

    func entries() -> [ClientLogUploadEntry] {
        uploadedEntries
    }
}
