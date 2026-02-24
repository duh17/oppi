import Foundation
import os

#if canImport(Sentry)
import Sentry
#endif

/// Chat timeline performance instrumentation.
///
/// Tracks:
/// - collection apply duration
/// - layout pass duration
/// - cell configure duration (by row type)
/// - scroll command rate
///
/// Uses OSSignposter for Instruments timelines and ClientLog for slow-path alerts.
@MainActor
enum ChatTimelinePerf {
    struct Snapshot: Sendable {
        let applyLastMs: Int
        let applyMaxMs: Int
        let layoutLastMs: Int
        let layoutMaxMs: Int
        let cellConfigureLastMs: Int
        let cellConfigureMaxMs: Int
        let slowCellCount: Int
        let hardGuardrailBreachCount: Int
        let failsafeConfigureCount: Int
        let scrollCommandsPerSecond: Int
    }

    struct IntervalToken {
        let name: StaticString
        let state: OSSignpostIntervalState
        let startNs: UInt64
        let itemCount: Int
        let changedCount: Int
    }

    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "ChatTimelinePerf"
    )

    private static let slowApplyThresholdMs = 24
    private static let slowLayoutThresholdMs = 24
    private static let slowCellThresholdMs = 8
    private static let slowScrollRateThresholdPerSecond = 30

    /// Coarse, low-noise regression guardrails. Keep these high so we only
    /// catch severe stalls, not normal simulator/debug variance.
    private static let guardrailApplyThresholdMs = 250
    private static let guardrailLayoutThresholdMs = 250
    private static let guardrailCellThresholdMs = 80

    private static let slowLogCooldownMs: UInt64 = 2_000

    private static var applyLastMs = 0
    private static var applyMaxMs = 0
    private static var layoutLastMs = 0
    private static var layoutMaxMs = 0
    private static var cellConfigureLastMs = 0
    private static var cellConfigureMaxMs = 0
    private static var slowCellCount = 0
    private static var hardGuardrailBreachCount = 0
    private static var failsafeConfigureCount = 0

    private static var lastSlowMetricLogNs: UInt64 = 0

    private static var scrollWindowStartNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private static var scrollWindowCount = 0
    private static var scrollCommandsPerSecond = 0

#if canImport(Sentry)
    private static var activeTimelineApplySpan: (any Span)?
    private static var activeTimelineApplyStartNs: UInt64 = 0
    private static var activeTimelineApplyItems = 0
    private static var activeTimelineApplyChanged = 0
    private static var activeSnapshotBuildSpan: (any Span)?
    private static var collectionApplySpansByStartNs: [UInt64: any Span] = [:]
    private static var layoutPassSpansByStartNs: [UInt64: any Span] = [:]
#endif

    static func reset() {
        applyLastMs = 0
        applyMaxMs = 0
        layoutLastMs = 0
        layoutMaxMs = 0
        cellConfigureLastMs = 0
        cellConfigureMaxMs = 0
        slowCellCount = 0
        hardGuardrailBreachCount = 0
        failsafeConfigureCount = 0

        lastSlowMetricLogNs = 0

        scrollWindowStartNs = DispatchTime.now().uptimeNanoseconds
        scrollWindowCount = 0
        scrollCommandsPerSecond = 0

#if canImport(Sentry)
        activeTimelineApplySpan = nil
        activeTimelineApplyStartNs = 0
        activeTimelineApplyItems = 0
        activeTimelineApplyChanged = 0
        activeSnapshotBuildSpan = nil
        collectionApplySpansByStartNs.removeAll(keepingCapacity: false)
        layoutPassSpansByStartNs.removeAll(keepingCapacity: false)
#endif
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            applyLastMs: applyLastMs,
            applyMaxMs: applyMaxMs,
            layoutLastMs: layoutLastMs,
            layoutMaxMs: layoutMaxMs,
            cellConfigureLastMs: cellConfigureLastMs,
            cellConfigureMaxMs: cellConfigureMaxMs,
            slowCellCount: slowCellCount,
            hardGuardrailBreachCount: hardGuardrailBreachCount,
            failsafeConfigureCount: failsafeConfigureCount,
            scrollCommandsPerSecond: scrollCommandsPerSecond
        )
    }

    static func timestampNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMs(since startNs: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000)
    }

    static func beginTimelineApplyCycle(itemCount: Int, changedCount: Int) {
#if canImport(Sentry)
        guard SentrySDK.isEnabled else { return }

        let root = SentrySDK.startTransaction(
            name: "chat.timeline.apply",
            operation: "ui.render"
        )
        root.setData(value: itemCount, key: "items")
        root.setData(value: changedCount, key: "changed")

        activeTimelineApplySpan = root
        activeTimelineApplyStartNs = timestampNs()
        activeTimelineApplyItems = itemCount
        activeTimelineApplyChanged = changedCount
#endif
    }

    static func updateTimelineApplyCycle(itemCount: Int, changedCount: Int) {
#if canImport(Sentry)
        activeTimelineApplyItems = itemCount
        activeTimelineApplyChanged = changedCount
        activeTimelineApplySpan?.setData(value: itemCount, key: "items")
        activeTimelineApplySpan?.setData(value: changedCount, key: "changed")
#endif
    }

    static func endTimelineApplyCycle(didScroll: Bool) {
#if canImport(Sentry)
        guard let root = activeTimelineApplySpan else { return }

        let durationMs = elapsedMs(since: activeTimelineApplyStartNs)
        root.setData(value: durationMs, key: "durationMs")
        root.setData(value: activeTimelineApplyItems, key: "items")
        root.setData(value: activeTimelineApplyChanged, key: "changed")
        root.setData(value: didScroll, key: "didScroll")
        root.finish(status: .ok)

        activeTimelineApplySpan = nil
        activeTimelineApplyStartNs = 0
        activeTimelineApplyItems = 0
        activeTimelineApplyChanged = 0
        activeSnapshotBuildSpan = nil
#endif
    }

    static func beginSnapshotBuildPhase() {
#if canImport(Sentry)
        guard let root = activeTimelineApplySpan else { return }
        activeSnapshotBuildSpan = root.startChild(
            operation: "snapshot.build",
            description: "Build diffable snapshot"
        )
#endif
    }

    static func endSnapshotBuildPhase() {
#if canImport(Sentry)
        activeSnapshotBuildSpan?.finish(status: .ok)
        activeSnapshotBuildSpan = nil
#endif
    }

    static func beginCollectionApply(itemCount: Int, changedCount: Int) -> IntervalToken {
        let startNs = timestampNs()
        let state = signposter.beginInterval("collection.apply")

#if canImport(Sentry)
        if let root = activeTimelineApplySpan {
            let span = root.startChild(
                operation: "datasource.apply",
                description: "UICollectionViewDiffableDataSource.apply"
            )
            span.setData(value: itemCount, key: "items")
            span.setData(value: changedCount, key: "changed")
            collectionApplySpansByStartNs[startNs] = span
        }
#endif

        return IntervalToken(
            name: "collection.apply",
            state: state,
            startNs: startNs,
            itemCount: itemCount,
            changedCount: changedCount
        )
    }

    static func endCollectionApply(_ token: IntervalToken) {
        signposter.endInterval(token.name, token.state)

        let durationMs = elapsedMs(since: token.startNs)
        applyLastMs = durationMs
        applyMaxMs = max(applyMaxMs, durationMs)

#if canImport(Sentry)
        if let span = collectionApplySpansByStartNs.removeValue(forKey: token.startNs) {
            span.setData(value: durationMs, key: "durationMs")
            span.finish(status: .ok)
        }
#endif

        if durationMs >= guardrailApplyThresholdMs {
            hardGuardrailBreachCount &+= 1
        }

        guard durationMs >= slowApplyThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.error(
            "ChatPerf",
            "Slow collection apply",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(token.itemCount),
                "changed": String(token.changedCount),
            ]
        )
    }

    static func beginLayoutPass(itemCount: Int) -> IntervalToken {
        let startNs = timestampNs()
        let state = signposter.beginInterval("collection.layout")

#if canImport(Sentry)
        if let root = activeTimelineApplySpan {
            let span = root.startChild(
                operation: "layout.pass",
                description: "UICollectionView.layoutIfNeeded"
            )
            span.setData(value: itemCount, key: "items")
            layoutPassSpansByStartNs[startNs] = span
        }
#endif

        return IntervalToken(
            name: "collection.layout",
            state: state,
            startNs: startNs,
            itemCount: itemCount,
            changedCount: 0
        )
    }

    static func endLayoutPass(_ token: IntervalToken) {
        signposter.endInterval(token.name, token.state)

        let durationMs = elapsedMs(since: token.startNs)
        layoutLastMs = durationMs
        layoutMaxMs = max(layoutMaxMs, durationMs)

#if canImport(Sentry)
        if let span = layoutPassSpansByStartNs.removeValue(forKey: token.startNs) {
            span.setData(value: durationMs, key: "durationMs")
            span.finish(status: .ok)
        }
#endif

        if durationMs >= guardrailLayoutThresholdMs {
            hardGuardrailBreachCount &+= 1
        }

        guard durationMs >= slowLayoutThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.error(
            "ChatPerf",
            "Slow collection layout",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(token.itemCount),
            ]
        )
    }

    static func recordCellConfigure(rowType: String, durationMs: Int) {
        cellConfigureLastMs = durationMs
        cellConfigureMaxMs = max(cellConfigureMaxMs, durationMs)

        if rowType.hasSuffix("_failsafe") {
            failsafeConfigureCount &+= 1
        }

        if durationMs >= guardrailCellThresholdMs {
            hardGuardrailBreachCount &+= 1
        }

        guard durationMs >= slowCellThresholdMs else { return }
        slowCellCount &+= 1

#if canImport(Sentry)
        if let root = activeTimelineApplySpan {
            let span = root.startChild(
                operation: "chat.cell.configure",
                description: rowType
            )
            span.setData(value: rowType, key: "rowType")
            span.setData(value: durationMs, key: "durationMs")
            span.finish(status: .ok)
        }
#endif

        guard shouldEmitSlowLog() else { return }

        ClientLog.error(
            "ChatPerf",
            "Slow cell configure",
            metadata: [
                "rowType": rowType,
                "durationMs": String(durationMs),
            ]
        )
    }

    static func recordScrollCommand(anchor: ChatTimelineScrollCommand.Anchor, animated: Bool) {
        signposter.emitEvent("scroll.command")

#if canImport(Sentry)
        if let root = activeTimelineApplySpan {
            let span = root.startChild(
                operation: "scroll.command",
                description: String(describing: anchor)
            )
            span.setData(value: String(describing: anchor), key: "anchor")
            span.setData(value: animated, key: "animated")
            span.finish(status: .ok)
        }
#endif

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let oneSecondNs: UInt64 = 1_000_000_000

        if nowNs &- scrollWindowStartNs >= oneSecondNs {
            scrollCommandsPerSecond = scrollWindowCount
            scrollWindowStartNs = nowNs
            scrollWindowCount = 0

            if scrollCommandsPerSecond >= slowScrollRateThresholdPerSecond,
               shouldEmitSlowLog(nowNs: nowNs) {
                ClientLog.error(
                    "ChatPerf",
                    "High scroll command rate",
                    metadata: [
                        "commandsPerSecond": String(scrollCommandsPerSecond),
                        "anchor": String(describing: anchor),
                        "animated": animated ? "true" : "false",
                    ]
                )
            }
        }

        scrollWindowCount &+= 1
    }

    private static func shouldEmitSlowLog(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        let cooldownNs = slowLogCooldownMs * 1_000_000
        guard nowNs &- lastSlowMetricLogNs >= cooldownNs else { return false }
        lastSlowMetricLogNs = nowNs
        return true
    }
}
