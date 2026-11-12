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
        /// Chrome pushes from the screen that hosts the timeline
        /// (`ChatTimelineController.update`). Streaming must not increment this:
        /// the collection controller owns the timeline clock.
        let hostUpdateUIViewCount: Int
        /// Controller-owned projection applies (observer / chrome rebuild).
        let controllerOwnedApplyCount: Int
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
    private static var hostUpdateUIViewCount = 0
    private static var controllerOwnedApplyCount = 0

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
        hostUpdateUIViewCount = 0
        controllerOwnedApplyCount = 0

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
            scrollCommandsPerSecond: scrollCommandsPerSecond,
            hostUpdateUIViewCount: hostUpdateUIViewCount,
            controllerOwnedApplyCount: controllerOwnedApplyCount
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

    /// A chrome push from the hosting screen (`ChatTimelineController.update`).
    /// Chrome, insets, and session identity may increment this; token
    /// streaming must not, because the controller owns the projection clock.
    static func recordHostUpdateUIView() {
        hostUpdateUIViewCount &+= 1
    }

    /// Reducer-observation or chrome-driven projection apply inside the
    /// collection controller. Existing `collection.apply` / `collection.layout`
    /// signposts still fire on the snapshot path.
    static func recordControllerOwnedApply() {
        controllerOwnedApplyCount &+= 1
    }

    // MARK: - Live resize counters

    /// Times a timeline layout rebuilt its row frames (`prepare`). A timeline
    /// held for a live resize (`PaneLiveResizing`) rebuilds none for the
    /// divider while it moves. Read as deltas; never reset.
    private(set) static var layoutRebuildCount = 0
    /// The rebuilds among `layoutRebuildCount` that a data change asked for
    /// (a snapshot apply or a reload: the rows themselves changed). Every
    /// other rebuild followed geometry: a width, an inset, a row that resized.
    /// A held timeline still takes data changes, so a live resize's own cost
    /// is the rest.
    private(set) static var contentRebuildCount = 0
    /// Rows a timeline cell sized through Auto Layout and TextKit
    /// (`SafeSizingCell`); a cached height costs none. Read as deltas.
    private(set) static var rowMeasureCount = 0

    static func recordLayoutRebuild(forDataChange: Bool) {
        layoutRebuildCount &+= 1
        if forDataChange { contentRebuildCount &+= 1 }
    }

    static func recordRowMeasure() {
        rowMeasureCount &+= 1
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

        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- token.startNs
        let durationMs = Int(elapsedNs / 1_000_000)
        applyLastMs = durationMs
        applyMaxMs = max(applyMaxMs, durationMs)

        if durationMs >= guardrailApplyThresholdMs {
            hardGuardrailBreachCount &+= 1
        }

        // Discard suspension-inflated samples. Wall-clock timers include
        // iOS process suspension time, producing multi-second values that
        // are background artifacts, not real rendering cost.
        guard durationMs < suspensionCeilingMs else { return }

        // The catalog emit policy drops the noise floor and suspension artifacts.
        Telemetry.record(
            AppTimelineApply(
                durationMs: Double(durationMs),
                items: token.itemCount,
                changed: token.changedCount
            ),
            sessionId: resolvedSessionId(token.sessionId)
        )

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

        Telemetry.record(
            AppTimelineLayout(durationMs: Double(durationMs), items: token.itemCount),
            sessionId: resolvedSessionId(token.sessionId)
        )

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

        // Sub-millisecond configures are the common case; the catalog emit policy
        // drops them before any task is spawned.
        Telemetry.record(
            AppCellConfigure(
                durationMs: Double(durationMs),
                expanded: toolContext?.isExpanded,
                rowType: rowType,
                tool: toolContext?.tool,
                contentType: toolContext?.contentType,
                outputSize: toolContext.map { TelemetryTag.OutputSize(bytes: $0.outputBytes) }
            ),
            sessionId: resolvedSessionId(sessionId)
        )

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

        // Signposts fire for every render strategy; the catalog emit policy drops
        // zero-millisecond telemetry rows.
        Telemetry.record(
            AppRenderStrategy(
                durationMs: Double(durationMs),
                renderMode: mode,
                inputSize: TelemetryTag.InputSize(bytes: inputBytes),
                language: language
            ),
            sessionId: resolvedSessionId(sessionId)
        )

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

        Telemetry.record(
            AppToolRowMeasure(
                durationMs: Double(durationMs),
                measure: name,
                inputSize: TelemetryTag.InputSize(bytes: inputBytes)
            ),
            sessionId: resolvedSessionId(sessionId)
        )

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

    private static func shouldEmitSlowLog(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        let cooldownNs = slowLogCooldownMs * 1_000_000
        guard nowNs &- lastSlowMetricLogNs >= cooldownNs else { return false }
        lastSlowMetricLogNs = nowNs
        return true
    }
}
