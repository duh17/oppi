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
/// Uses OSSignposter for Instruments timelines and low-volume ClientLog entries.
@MainActor
enum ChatTimelinePerf {
    struct Snapshot: Sendable {
        let applyLastMs: Int
        let applyMaxMs: Int
        let layoutLastMs: Int
        let layoutMaxMs: Int
        let cellConfigureLastMs: Int
        let cellConfigureMaxMs: Int
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
        let sessionId: String?
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

    /// Discard apply/layout measurements above this threshold. Wall-clock
    /// timers include iOS process suspension time, so multi-second values
    /// are nearly always background artifacts, not real rendering cost.
    static let suspensionCeilingMs = 5_000

    private static let slowLogCooldownMs: UInt64 = 2_000

    private static var applyLastMs = 0
    private static var applyMaxMs = 0
    private static var layoutLastMs = 0
    private static var layoutMaxMs = 0
    private static var cellConfigureLastMs = 0
    private static var cellConfigureMaxMs = 0
    private static var hardGuardrailBreachCount = 0
    private static var failsafeConfigureCount = 0

    // MARK: - Jank tracking (chat.jank_pct)

    /// Number of collection apply cycles where elapsed > 16ms (frame budget).
    private static var hitchCount = 0
    /// Total collection apply cycles counted since last jank rate emission.
    private static var totalApplyCycles = 0

    /// Legacy fallback for metric attribution when a call site hasn't been
    /// updated to pass an explicit `sessionId`. New instrumentation should
    /// prefer explicit session IDs so offscreen work is attributed
    /// correctly.
    static var activeSessionId: String?

    private static var lastSlowMetricLogNs: UInt64 = 0

    private static var scrollWindowStartNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    private static var scrollWindowCount = 0
    private static var scrollCommandsPerSecond = 0

    static func reset() {
        activeSessionId = nil
        applyLastMs = 0
        applyMaxMs = 0
        layoutLastMs = 0
        layoutMaxMs = 0
        cellConfigureLastMs = 0
        cellConfigureMaxMs = 0
        hardGuardrailBreachCount = 0
        failsafeConfigureCount = 0
        hitchCount = 0
        totalApplyCycles = 0

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

    private static func resolvedSessionId(_ sessionId: String?) -> String? {
        sessionId ?? activeSessionId
    }

    static func beginTimelineApplyCycle(itemCount: Int, changedCount: Int) {
    }

    static func updateTimelineApplyCycle(itemCount: Int, changedCount: Int) {
    }

    static func endTimelineApplyCycle(didScroll: Bool) {
    }

    static func beginSnapshotBuildPhase() {
    }

    static func endSnapshotBuildPhase() {
    }

    static func beginCollectionApply(
        itemCount: Int,
        changedCount: Int,
        sessionId: String? = nil
    ) -> IntervalToken {
        let startNs = timestampNs()
        let state = signposter.beginInterval("collection.apply")

        return IntervalToken(
            name: "collection.apply",
            state: state,
            startNs: startNs,
            itemCount: itemCount,
            changedCount: changedCount,
            sessionId: sessionId
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

        // Discard suspension-inflated samples. Wall-clock timers include
        // iOS process suspension time, producing multi-second values that
        // are background artifacts, not real rendering cost.
        guard durationMs < suspensionCeilingMs else { return }

        // Jank tracking: count every valid apply cycle and flag hitches (> 16ms).
        totalApplyCycles += 1
        if durationMs > 16 {
            hitchCount += 1
        }

        // Emit to telemetry only when above noise floor (skip the 99% that are 0-1ms).
        if durationMs >= 4 {
            let applySid = resolvedSessionId(token.sessionId)
            Task.detached(priority: .utility) {
                await ChatMetricsService.shared.record(
                    metric: .timelineApplyMs,
                    value: Double(durationMs),
                    unit: .ms,
                    sessionId: applySid,
                    tags: [
                        "items": String(token.itemCount),
                        "changed": String(token.changedCount),
                    ]
                )
            }
        }

        guard durationMs >= slowApplyThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.info(
            "ChatPerf",
            "Slow collection apply",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(token.itemCount),
                "changed": String(token.changedCount),
            ]
        )
    }

    static func beginLayoutPass(itemCount: Int, sessionId: String? = nil) -> IntervalToken {
        let startNs = timestampNs()
        let state = signposter.beginInterval("collection.layout")

        return IntervalToken(
            name: "collection.layout",
            state: state,
            startNs: startNs,
            itemCount: itemCount,
            changedCount: 0,
            sessionId: sessionId
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

        guard durationMs < suspensionCeilingMs else { return }

        // Emit to telemetry only when above noise floor.
        if durationMs >= 2 {
            let layoutSid = resolvedSessionId(token.sessionId)
            Task.detached(priority: .utility) {
                await ChatMetricsService.shared.record(
                    metric: .timelineLayoutMs,
                    value: Double(durationMs),
                    unit: .ms,
                    sessionId: layoutSid,
                    tags: ["items": String(token.itemCount)]
                )
            }
        }

        guard durationMs >= slowLayoutThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.info(
            "ChatPerf",
            "Slow collection layout",
            metadata: [
                "durationMs": String(durationMs),
                "items": String(token.itemCount),
            ]
        )
    }

    /// Tool cell rendering context for telemetry attribution.
    struct ToolCellContext {
        let tool: String
        let isExpanded: Bool
        let contentType: String
        let outputBytes: Int
    }

    static func recordCellConfigure(
        rowType: String,
        durationMs: Int,
        sessionId: String? = nil,
        toolContext: ToolCellContext? = nil
    ) {
        cellConfigureLastMs = durationMs
        cellConfigureMaxMs = max(cellConfigureMaxMs, durationMs)

        if rowType.hasSuffix("_failsafe") {
            failsafeConfigureCount &+= 1
        }

        if durationMs >= guardrailCellThresholdMs {
            hardGuardrailBreachCount &+= 1
        }

        // Discard suspension-inflated samples (same rationale as apply/layout).
        guard durationMs < suspensionCeilingMs else { return }

        // Only emit to telemetry for non-trivial configures (≥1ms).
        // Sub-millisecond configures are the common case and the Task.detached
        // allocation adds overhead that exceeds the measurement itself.
        guard durationMs >= 1 else { return }

        let sid = resolvedSessionId(sessionId)
        Task.detached(priority: .utility) {
            var tags: [String: String] = ["row_type": rowType]
            if let ctx = toolContext {
                tags["tool"] = ctx.tool
                tags["expanded"] = ctx.isExpanded ? "1" : "0"
                tags["content_type"] = ctx.contentType
                tags["output_bytes"] = outputBytesBucket(ctx.outputBytes)
            }
            await ChatMetricsService.shared.record(
                metric: .cellConfigureMs,
                value: Double(durationMs),
                unit: .ms,
                sessionId: sid,
                tags: tags
            )
        }

        guard durationMs >= slowCellThresholdMs else { return }

        guard shouldEmitSlowLog() else { return }

        ClientLog.info(
            "ChatPerf",
            "Slow cell configure",
            metadata: [
                "rowType": rowType,
                "durationMs": String(durationMs),
            ]
        )
    }

    // MARK: - Render Strategy Timing

    private static let slowRenderThresholdMs = 8
    private static let slowMeasurementThresholdMs = 4

    /// Record internal rendering time for a tool row's expanded content.
    ///
    /// Measures the highlighting / ANSI parse / diff build cost,
    /// independent of UIKit layout. Emitted to the telemetry pipeline
    /// and logged when slow.
    static func recordRenderStrategy(
        mode: String,
        durationMs: Int,
        inputBytes: Int,
        language: String? = nil,
        sessionId: String? = nil
    ) {
        signposter.emitEvent("render.strategy")

        // Discard suspension-inflated samples.
        guard durationMs < suspensionCeilingMs else { return }

        // Keep signposts for every render strategy, but skip zero-millisecond
        // telemetry rows. They are common, add upload/task overhead, and do not
        // help diagnose user-visible render cost.
        guard durationMs >= 1 else { return }

        let sid = resolvedSessionId(sessionId)
        Task.detached(priority: .utility) {
            var tags = [
                "mode": mode,
                "input_bytes": outputBytesBucket(inputBytes),
            ]
            if let language { tags["language"] = language }

            await ChatMetricsService.shared.record(
                metric: .renderStrategyMs,
                value: Double(durationMs),
                unit: .ms,
                sessionId: sid,
                tags: tags
            )
        }

        guard durationMs >= slowRenderThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        var metadata: [String: String] = [
            "mode": mode,
            "durationMs": String(durationMs),
            "inputBytes": String(inputBytes),
        ]
        if let language { metadata["language"] = language }

        ClientLog.info(
            "ChatPerf",
            "Slow render strategy",
            metadata: metadata
        )
    }

    static func recordToolRowMeasurement(
        name: String,
        durationMs: Int,
        inputBytes: Int,
        sessionId: String? = nil
    ) {
        signposter.emitEvent("toolrow.measure")

        guard durationMs > 0 else { return }

        let sid = resolvedSessionId(sessionId)
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .renderStrategyMs,
                value: Double(durationMs),
                unit: .ms,
                sessionId: sid,
                tags: [
                    "mode": "measurement.\(name)",
                    "input_bytes": outputBytesBucket(inputBytes),
                ]
            )
        }

        guard durationMs >= slowMeasurementThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.info(
            "ChatPerf",
            "Slow tool row measurement",
            metadata: [
                "name": name,
                "durationMs": String(durationMs),
                "inputBytes": String(inputBytes),
            ]
        )
    }

    nonisolated private static func outputBytesBucket(_ bytes: Int) -> String {
        switch bytes {
        case ..<1_000: return "<1KB"
        case ..<10_000: return "1-10KB"
        case ..<50_000: return "10-50KB"
        case ..<200_000: return "50-200KB"
        default: return "200KB+"
        }
    }

    static func recordScrollCommand(
        anchor: ChatTimelineScrollCommand.Anchor,
        animated: Bool,
        sessionId: String? = nil
    ) {
        signposter.emitEvent("scroll.command")

        let nowNs = DispatchTime.now().uptimeNanoseconds
        let oneSecondNs: UInt64 = 1_000_000_000

        if nowNs &- scrollWindowStartNs >= oneSecondNs {
            scrollCommandsPerSecond = scrollWindowCount
            scrollWindowStartNs = nowNs
            scrollWindowCount = 0

            if scrollCommandsPerSecond >= slowScrollRateThresholdPerSecond,
               shouldEmitSlowLog(nowNs: nowNs) {
                var metadata: [String: String] = [
                    "commandsPerSecond": String(scrollCommandsPerSecond),
                    "anchor": String(describing: anchor),
                    "animated": animated ? "true" : "false",
                ]
                if let sid = resolvedSessionId(sessionId) {
                    metadata["sessionId"] = sid
                }
                ClientLog.info(
                    "ChatPerf",
                    "High scroll command rate",
                    metadata: metadata
                )
            }
        }

        scrollWindowCount &+= 1
    }

    // MARK: - Jank Snapshot (bench / test access)

    /// Current jank counters without resetting or emitting telemetry.
    struct JankSnapshot {
        let hitchCount: Int
        let totalApplyCycles: Int
        var pct: Double {
            guard totalApplyCycles > 0 else { return 0 }
            return Double(hitchCount) / Double(totalApplyCycles) * 100.0
        }
    }

    /// Read current jank counters without resetting.
    static func jankSnapshot() -> JankSnapshot {
        JankSnapshot(hitchCount: hitchCount, totalApplyCycles: totalApplyCycles)
    }

    /// Reset jank counters without emitting. Use before a bench measurement window.
    static func resetJankCounters() {
        hitchCount = 0
        totalApplyCycles = 0
    }

    // MARK: - Jank Rate Emission

    /// Compute and emit `chat.jank_pct` — percentage of collection-apply cycles
    /// that exceeded the 16ms frame budget. Resets counters after emission.
    ///
    /// Call periodically during streaming (e.g. every 30s) and on session end.
    /// The `phase` tag distinguishes streaming vs idle vs session-end context.
    static func emitJankRate(sessionId: String?, phase: String) {
        guard totalApplyCycles > 0 else { return }
        let pct = Double(hitchCount) / Double(totalApplyCycles) * 100.0
        let cycles = totalApplyCycles
        let hitches = hitchCount
        hitchCount = 0
        totalApplyCycles = 0

        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .jankPct,
                value: pct,
                unit: .ratio,
                sessionId: sessionId,
                tags: [
                    "phase": phase,
                    "cycles": String(cycles),
                    "hitches": String(hitches),
                ]
            )
        }
    }

    private static func shouldEmitSlowLog(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        let cooldownNs = slowLogCooldownMs * 1_000_000
        guard nowNs &- lastSlowMetricLogNs >= cooldownNs else { return false }
        lastSlowMetricLogNs = nowNs
        return true
    }
}
