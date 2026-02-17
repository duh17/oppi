import Foundation
import os

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

    static func beginCollectionApply(itemCount: Int, changedCount: Int) -> IntervalToken {
        let state = signposter.beginInterval("collection.apply")
        return IntervalToken(
            name: "collection.apply",
            state: state,
            startNs: timestampNs(),
            itemCount: itemCount,
            changedCount: changedCount
        )
    }

    static func endCollectionApply(_ token: IntervalToken) {
        signposter.endInterval(token.name, token.state)

        let durationMs = elapsedMs(since: token.startNs)
        applyLastMs = durationMs
        applyMaxMs = max(applyMaxMs, durationMs)

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
        let state = signposter.beginInterval("collection.layout")
        return IntervalToken(
            name: "collection.layout",
            state: state,
            startNs: timestampNs(),
            itemCount: itemCount,
            changedCount: 0
        )
    }

    static func endLayoutPass(_ token: IntervalToken) {
        signposter.endInterval(token.name, token.state)

        let durationMs = elapsedMs(since: token.startNs)
        layoutLastMs = durationMs
        layoutMaxMs = max(layoutMaxMs, durationMs)

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
