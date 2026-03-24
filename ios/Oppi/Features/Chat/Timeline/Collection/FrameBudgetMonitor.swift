import Foundation
import QuartzCore
import os

/// Monitors frame delivery during critical timeline operations.
///
/// Uses `CADisplayLink` to sample actual frame timestamps and detect hitches
/// (frames where the main thread missed the vsync deadline). Reports are
/// emitted as structured telemetry and OSSignpost events.
///
/// Usage:
/// ```
/// FrameBudgetMonitor.shared.beginSection("tool_row_insert")
/// // ... snapshot apply + layout + scroll ...
/// let report = FrameBudgetMonitor.shared.endSection()
/// ```
///
/// The monitor is lightweight (~0.1μs per frame callback) and only records
/// timestamps while a section is active. No-op when no section is open.
@MainActor
final class FrameBudgetMonitor {
    static let shared = FrameBudgetMonitor()

    struct FrameReport: Sendable {
        let section: String
        let frameCount: Int
        /// Frames where gap exceeded 1.5× the expected interval.
        let hitchCount: Int
        /// Worst single frame gap in milliseconds.
        let worstFrameMs: Double
        /// Percentage of frames delivered within expected interval.
        let onBudgetPercent: Double
        /// Total wall time of the section in milliseconds.
        let durationMs: Double
        /// Expected frame interval in milliseconds (e.g. 8.33 for 120Hz).
        let expectedIntervalMs: Double
    }

    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "FrameBudget"
    )

    /// Hitch threshold: frame gap must exceed expected interval by this factor.
    private static let hitchMultiplier: Double = 1.5

    private var displayLink: CADisplayLink?
    private var timestamps: [CFTimeInterval] = []
    private var sectionName: String?
    private var sectionSessionId: String?
    private var sectionStartTime: CFTimeInterval = 0
    private var expectedInterval: CFTimeInterval = 0
    private var signpostState: OSSignpostIntervalState?

    private init() {
        timestamps.reserveCapacity(64)
    }

    /// Start recording frame timestamps for a named section.
    /// If a section is already active, it is silently discarded.
    func beginSection(_ name: String, sessionId: String? = nil) {
        guard sectionName == nil else { return }

        sectionName = name
        sectionSessionId = sessionId
        timestamps.removeAll(keepingCapacity: true)
        expectedInterval = 0
        sectionStartTime = CACurrentMediaTime()

        let state = Self.signposter.beginInterval("frame_budget")
        signpostState = state

        let link = CADisplayLink(target: FrameBudgetDisplayLinkTarget {
            [weak self] timestamp, duration in
            self?.recordFrame(timestamp: timestamp, duration: duration)
        }, selector: #selector(FrameBudgetDisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stop recording and return the frame report.
    /// Returns nil if no section was active.
    @discardableResult
    func endSection() -> FrameReport? {
        guard let name = sectionName else { return nil }

        displayLink?.invalidate()
        displayLink = nil

        if let state = signpostState {
            Self.signposter.endInterval("frame_budget", state)
            signpostState = nil
        }

        let report = buildReport(section: name)
        let sessionId = sectionSessionId
        sectionName = nil
        sectionSessionId = nil
        timestamps.removeAll(keepingCapacity: true)

        // Emit telemetry for hitches
        if report.hitchCount > 0 || report.worstFrameMs > report.expectedIntervalMs * Self.hitchMultiplier {
            ClientLog.error(
                "FrameBudget",
                "Hitch detected in \(name)",
                metadata: [
                    "hitchCount": String(report.hitchCount),
                    "worstFrameMs": String(format: "%.1f", report.worstFrameMs),
                    "onBudgetPercent": String(format: "%.0f", report.onBudgetPercent),
                    "durationMs": String(format: "%.1f", report.durationMs),
                    "frameCount": String(report.frameCount),
                ]
            )

            Task.detached(priority: .utility) {
                await ChatMetricsService.shared.record(
                    metric: .timelineHitch,
                    value: report.worstFrameMs,
                    unit: .ms,
                    sessionId: sessionId,
                    tags: [
                        "section": name,
                        "hitch_count": String(report.hitchCount),
                    ]
                )
            }
        }

        return report
    }

    // MARK: - Private

    private func recordFrame(timestamp: CFTimeInterval, duration: CFTimeInterval) {
        guard sectionName != nil else { return }
        if expectedInterval == 0 {
            expectedInterval = duration
        }
        timestamps.append(timestamp)
    }

    private func buildReport(section: String) -> FrameReport {
        let endTime = CACurrentMediaTime()
        let durationMs = (endTime - sectionStartTime) * 1000.0

        guard timestamps.count >= 2 else {
            return FrameReport(
                section: section,
                frameCount: timestamps.count,
                hitchCount: 0,
                worstFrameMs: 0,
                onBudgetPercent: 100,
                durationMs: durationMs,
                expectedIntervalMs: expectedInterval * 1000.0
            )
        }

        let expectedMs = expectedInterval * 1000.0
        let hitchThresholdMs = expectedMs * Self.hitchMultiplier
        var hitchCount = 0
        var worstMs: Double = 0

        for i in 1..<timestamps.count {
            let gapMs = (timestamps[i] - timestamps[i - 1]) * 1000.0
            worstMs = max(worstMs, gapMs)
            if gapMs > hitchThresholdMs {
                hitchCount += 1
            }
        }

        let gaps = timestamps.count - 1
        let onBudget = gaps > 0 ? Double(gaps - hitchCount) / Double(gaps) * 100.0 : 100.0

        return FrameReport(
            section: section,
            frameCount: timestamps.count,
            hitchCount: hitchCount,
            worstFrameMs: worstMs,
            onBudgetPercent: onBudget,
            durationMs: durationMs,
            expectedIntervalMs: expectedMs
        )
    }
}

// MARK: - Display Link Target

/// NSObject target for CADisplayLink (avoids retain cycle with closure).
private final class FrameBudgetDisplayLinkTarget: NSObject {
    private let handler: (CFTimeInterval, CFTimeInterval) -> Void

    init(_ handler: @escaping (CFTimeInterval, CFTimeInterval) -> Void) {
        self.handler = handler
    }

    @objc func tick(_ link: CADisplayLink) {
        handler(link.timestamp, link.duration)
    }
}
