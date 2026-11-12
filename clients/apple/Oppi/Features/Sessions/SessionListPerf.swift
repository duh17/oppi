import Foundation
import os

/// Session list rendering performance instrumentation.
///
/// Tracks:
/// - viewData computation latency (the O(n^2) tree-walk hotpath)
/// - recompute rate in fixed 5 s windows (store churn indicator)
/// - aggregate per-row computation latency
///
/// Lightweight: all telemetry is fire-and-forget via `Telemetry.record`.
/// Cooldown prevents flooding during rapid store updates.
@MainActor
enum SessionListPerf {

    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "SessionListPerf"
    )

    // MARK: - Recompute rate tracking

    /// A window opens at a recompute and a timer closes it this much later, so
    /// every reported count covers the same length of time.
    private static let recomputeWindow: Duration = .seconds(5)

    private static var recomputeWindowCount = 0
    private static var recomputeWindowTask: Task<Void, Never>?

    /// Minimum emission cooldown for compute metrics to avoid flooding.
    private static let emitCooldownNs: UInt64 = 2_000_000_000 // 2 seconds
    private static var lastComputeEmitNs: UInt64 = 0
    private static var lastRowEmitNs: UInt64 = 0

    /// Noise floor: skip emitting viewData compute times below this.
    private static let computeNoiseFloorMs = 1

    // MARK: - viewData computation

    static func timestampNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Record a viewData computation and emit telemetry if above noise floor.
    static func recordViewDataCompute(
        startNs: UInt64,
        activeCount: Int,
        stoppedCount: Int,
        workspaceId: String?
    ) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let durationMs = Int((nowNs &- startNs) / 1_000_000)

        signposter.emitEvent("viewData.compute")

        recordRecompute(workspaceId: workspaceId)

        guard durationMs >= computeNoiseFloorMs else { return }
        guard nowNs &- lastComputeEmitNs >= emitCooldownNs else { return }
        lastComputeEmitNs = nowNs

        Telemetry.record(
            AppSessionListCompute(
                durationMs: Double(durationMs),
                activeSessions: activeCount,
                stoppedSessions: stoppedCount
            ),
            workspaceId: workspaceId
        )
    }

    // MARK: - Per-row computation

    /// Record aggregate row computation time for a batch of visible rows.
    static func recordRowCompute(
        durationMs: Int,
        rowCount: Int,
        workspaceId: String?
    ) {
        guard durationMs >= 1 else { return }

        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs &- lastRowEmitNs >= emitCooldownNs else { return }
        lastRowEmitNs = nowNs

        signposter.emitEvent("row.compute")

        Telemetry.record(
            AppSessionListRowCompute(durationMs: Double(durationMs), rows: rowCount),
            workspaceId: workspaceId
        )
    }

    // MARK: - Recompute rate

    private static func recordRecompute(workspaceId: String?) {
        recomputeWindowCount += 1
        guard recomputeWindowTask == nil else { return }
        recomputeWindowTask = Task { @MainActor in
            try? await Task.sleep(for: recomputeWindow)
            guard !Task.isCancelled else { return }
            let count = recomputeWindowCount
            recomputeWindowCount = 0
            recomputeWindowTask = nil
            Telemetry.record(AppSessionListBodyRate(evaluations: count), workspaceId: workspaceId)
        }
    }

    // MARK: - Reset

    static func reset() {
        recomputeWindowTask?.cancel()
        recomputeWindowTask = nil
        recomputeWindowCount = 0
        lastComputeEmitNs = 0
        lastRowEmitNs = 0
    }
}
