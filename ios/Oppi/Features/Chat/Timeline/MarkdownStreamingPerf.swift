import Foundation
import os

/// Lightweight perf instrumentation for the streaming markdown incremental parse path.
///
/// Records:
/// - CommonMark parse duration (tail-only vs full)
/// - FlatSegment build duration
/// - Whether the tail-only path was taken (cache hit on prefix)
///
/// Integrates with Instruments via `OSSignposter` and logs slow paths via
/// `ClientLog.error`.  Deliberately separate from `ChatTimelinePerf` to
/// avoid coupling the markdown rendering subsystem to the timeline collection.
@MainActor
enum MarkdownStreamingPerf {

    // MARK: - Signposter

    private static let signposter = OSSignposter(
        subsystem: AppIdentifiers.subsystem,
        category: "MarkdownStreamingPerf"
    )

    // MARK: - Thresholds

    /// Parse + build combined above this threshold triggers a slow-path log.
    private static let slowThresholdMs = 5

    /// Cooldown between slow-path log emissions to avoid log floods.
    private static let cooldownNs: UInt64 = 2_000_000_000

    // MARK: - State

    private static var lastSlowLogNs: UInt64 = 0

    // MARK: - Public API

    static func timestampNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Record a completed incremental parse cycle.
    ///
    /// - Parameters:
    ///   - parseDurationNs: Wall-clock nanoseconds spent in `parseCommonMark`.
    ///   - buildDurationNs: Wall-clock nanoseconds spent in `FlatSegment.build`.
    ///   - lineCount: Number of lines in the parsed region (tail or full doc).
    ///   - isTailOnly: `true` when only the tail (last block) was re-parsed.
    ///   - isStreaming: `true` when called from the streaming path.
    static func record(
        parseDurationNs: UInt64,
        buildDurationNs: UInt64,
        lineCount: Int,
        isTailOnly: Bool,
        isStreaming: Bool
    ) {
        signposter.emitEvent(
            "markdown.parse",
            "\(isTailOnly ? "tail" : "full") lines=\(lineCount)"
        )

        let parseMs = Int(parseDurationNs / 1_000_000)
        let buildMs = Int(buildDurationNs / 1_000_000)
        let totalMs = parseMs + buildMs

        guard totalMs >= slowThresholdMs else { return }
        guard shouldEmitSlowLog() else { return }

        ClientLog.error(
            "MarkdownPerf",
            "Slow markdown parse",
            metadata: [
                "parseMs": String(parseMs),
                "buildMs": String(buildMs),
                "lineCount": String(lineCount),
                "tailOnly": isTailOnly ? "1" : "0",
                "streaming": isStreaming ? "1" : "0",
            ]
        )
    }

    // MARK: - Helpers

    private static func shouldEmitSlowLog() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastSlowLogNs >= cooldownNs else { return false }
        lastSlowLogNs = now
        return true
    }
}
