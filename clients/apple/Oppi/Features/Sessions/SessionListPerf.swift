import Foundation
import os

/// Session list rendering performance instrumentation.
///
/// Tracks:
/// - viewData computation latency (the O(n^2) tree-walk hotpath)
/// - body evaluation rate (store churn indicator)
/// - aggregate per-row computation latency
///
/// Lightweight: all telemetry is fire-and-forget via ChatMetricsService.
/// Cooldown prevents flooding during rapid store updates.
@MainActor
enum SessionListPerf {

    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "SessionListPerf"
    )

    // MARK: - Body rate tracking

    /// Window size for body evaluation rate measurement.
    private static let bodyRateWindowNs: UInt64 = 5_000_000_000 // 5 seconds

    private static var bodyWindowStartNs: UInt64 = 0
    private static var bodyWindowCount = 0

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

        // Always count the body evaluation
        recordBodyEvaluation(nowNs: nowNs, workspaceId: workspaceId)

        guard durationMs >= computeNoiseFloorMs else { return }
        guard nowNs &- lastComputeEmitNs >= emitCooldownNs else { return }
        lastComputeEmitNs = nowNs

        let wid = workspaceId
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .sessionListComputeMs,
                value: Double(durationMs),
                unit: .ms,
                workspaceId: wid,
                tags: [
                    "active_count": String(activeCount),
                    "stopped_count": String(stoppedCount),
                ]
            )
        }

        if durationMs >= 8 {
            ClientLog.error(
                "SessionListPerf",
                "Slow viewData compute",
                metadata: [
                    "durationMs": String(durationMs),
                    "activeCount": String(activeCount),
                    "stoppedCount": String(stoppedCount),
                ]
            )
        }
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

        let wid = workspaceId
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .sessionListRowComputeMs,
                value: Double(durationMs),
                unit: .ms,
                workspaceId: wid,
                tags: ["row_count": String(rowCount)]
            )
        }

        if durationMs >= 4 {
            ClientLog.error(
                "SessionListPerf",
                "Slow row compute",
                metadata: [
                    "durationMs": String(durationMs),
                    "rowCount": String(rowCount),
                ]
            )
        }
    }

    // MARK: - Body evaluation rate

    private static func recordBodyEvaluation(nowNs: UInt64, workspaceId: String?) {
        if bodyWindowStartNs == 0 {
            bodyWindowStartNs = nowNs
            bodyWindowCount = 0
        }

        bodyWindowCount += 1

        guard nowNs &- bodyWindowStartNs >= bodyRateWindowNs else { return }

        // Window complete — emit rate and reset
        let count = bodyWindowCount
        bodyWindowStartNs = nowNs
        bodyWindowCount = 0

        let wid = workspaceId
        Task.detached(priority: .utility) {
            await ChatMetricsService.shared.record(
                metric: .sessionListBodyRate,
                value: Double(count),
                unit: .count,
                workspaceId: wid
            )
        }

        // Flag excessive churn: > 20 evaluations per 5s window
        if count > 20 {
            ClientLog.error(
                "SessionListPerf",
                "High body evaluation rate",
                metadata: [
                    "count_per_5s": String(count),
                ]
            )
        }
    }

    // MARK: - Reset

    static func reset() {
        bodyWindowStartNs = 0
        bodyWindowCount = 0
        lastComputeEmitNs = 0
        lastRowEmitNs = 0
    }
}
