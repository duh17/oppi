import UIKit

@MainActor
struct ToolTimelineRowWidthEstimateCache {
    private var estimatedContentWidth: CGFloat?

    mutating func invalidate() {
        estimatedContentWidth = nil
    }

    mutating func resolve(text: String, metricMode: String, sessionId: String? = nil) -> CGFloat {
        if let estimatedContentWidth {
            return estimatedContentWidth
        }

        let startNs = ChatTimelinePerf.timestampNs()
        let width = ToolTimelineRowRenderMetrics.estimatedMonospaceLineWidth(text)
        ChatTimelinePerf.recordToolRowMeasurement(
            name: "width.\(metricMode)",
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
            inputBytes: text.utf8.count,
            sessionId: sessionId
        )
        estimatedContentWidth = width
        return width
    }
}

@MainActor
struct ToolTimelineRowViewportHeightCache {
    private var isValid = false
    private var signature: Int?
    private var widthBucket = 0
    private var modeKey = 0
    private var cachedHeight: CGFloat = 0

    mutating func invalidate() {
        isValid = false
        signature = nil
        widthBucket = 0
        modeKey = 0
        cachedHeight = 0
    }

    mutating func resolve(
        signature: Int?,
        widthBucket: Int,
        modeKey: Int,
        metricMode: String,
        inputBytes: Int,
        sessionId: String? = nil,
        measure: () -> CGFloat
    ) -> CGFloat {
        if isValid,
           self.signature == signature,
           self.widthBucket == widthBucket,
           self.modeKey == modeKey {
            return cachedHeight
        }

        let startNs = ChatTimelinePerf.timestampNs()
        let measuredHeight = measure()
        ChatTimelinePerf.recordToolRowMeasurement(
            name: "viewport.\(metricMode)",
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
            inputBytes: inputBytes,
            sessionId: sessionId
        )

        isValid = true
        self.signature = signature
        self.widthBucket = widthBucket
        self.modeKey = modeKey
        cachedHeight = measuredHeight
        return measuredHeight
    }
}

enum ToolTimelineRowViewportKind {
    case bashOutput
    case code
    case diff
    case text
    case markdown
    case readMedia
}

struct ToolTimelineRowViewportProfile {
    let kind: ToolTimelineRowViewportKind
    let inputBytes: Int
    let lineCount: Int

    init(kind: ToolTimelineRowViewportKind, text: String?) {
        let text = text ?? ""
        self.kind = kind
        inputBytes = text.utf8.count
        if text.isEmpty {
            lineCount = 0
        } else {
            lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        }
    }

    // periphery:ignore - used by ToolTimelineRowViewportPolicyTests via @testable import
    init(kind: ToolTimelineRowViewportKind, inputBytes: Int, lineCount: Int) {
        self.kind = kind
        self.inputBytes = max(0, inputBytes)
        self.lineCount = max(0, lineCount)
    }

    fileprivate var effectiveLineCount: Int {
        switch kind {
        case .text, .markdown, .readMedia:
            let wrappedLineEstimate = Int(ceil(Double(max(inputBytes, 1)) / 72.0))
            return max(1, lineCount, wrappedLineEstimate)

        case .bashOutput, .code, .diff:
            return max(1, lineCount)
        }
    }
}

extension ToolTimelineRowContentView.ViewportMode {
    var cacheKey: Int {
        switch self {
        case .output: return 0
        case .expandedDiff: return 1
        case .expandedCode: return 2
        case .expandedText: return 3
        }
    }

    var perfName: String {
        switch self {
        case .output: return "output"
        case .expandedDiff: return "expanded.diff"
        case .expandedCode: return "expanded.code"
        case .expandedText: return "expanded.text"
        }
    }
}

@MainActor
enum ToolTimelineRowLayoutPerformance {
    static func monospaceWidthConstant(
        frameWidth: CGFloat,
        renderedText: String,
        cache: inout ToolTimelineRowWidthEstimateCache,
        metricMode: String,
        sessionId: String? = nil
    ) -> CGFloat {
        let minimumContentWidth = max(1, frameWidth - 12)
        let estimatedContentWidth = cache.resolve(
            text: renderedText,
            metricMode: metricMode,
            sessionId: sessionId
        )
        let contentWidth = max(minimumContentWidth, estimatedContentWidth)
        return contentWidth - frameWidth
    }

    static func resolveViewportHeight(
        cache: inout ToolTimelineRowViewportHeightCache,
        signature: Int?,
        widthBucket: Int,
        mode: ToolTimelineRowContentView.ViewportMode,
        inputBytes: Int,
        profile: ToolTimelineRowViewportProfile?,
        availableHeight: CGFloat,
        sessionId: String? = nil,
        measure: () -> CGFloat
    ) -> CGFloat {
        if let profile {
            return bucketedViewportHeight(
                profile: profile,
                mode: mode,
                availableHeight: availableHeight
            )
        }

        return cache.resolve(
            signature: signature,
            widthBucket: widthBucket,
            modeKey: mode.cacheKey,
            metricMode: mode.perfName,
            inputBytes: inputBytes,
            sessionId: sessionId,
            measure: measure
        )
    }

    private static func bucketedViewportHeight(
        profile: ToolTimelineRowViewportProfile,
        mode: ToolTimelineRowContentView.ViewportMode,
        availableHeight: CGFloat
    ) -> CGFloat {
        let maxAllowed = min(mode.maxHeight, max(mode.minHeight, availableHeight))
        let preferredHeight = preferredHeight(for: profile)
        return min(maxAllowed, max(mode.minHeight, preferredHeight))
    }

    private static func preferredHeight(for profile: ToolTimelineRowViewportProfile) -> CGFloat {
        let lines = profile.effectiveLineCount

        switch profile.kind {
        case .bashOutput, .text:
            return bucketHeight(
                effectiveLineCount: lines,
                thresholds: [(3, 92), (8, 132), (18, 180), (40, 240), (96, 320)],
                fallback: 420
            )

        case .code, .diff:
            return bucketHeight(
                effectiveLineCount: lines,
                thresholds: [(4, 116), (12, 164), (32, 240), (80, 320), (200, 420)],
                fallback: 520
            )

        case .markdown:
            return bucketHeight(
                effectiveLineCount: lines,
                thresholds: [(4, 120), (12, 180), (28, 260), (72, 360)],
                fallback: 480
            )

        case .readMedia:
            return bucketHeight(
                effectiveLineCount: lines,
                thresholds: [(3, 120), (10, 180), (24, 260), (64, 340)],
                fallback: 420
            )
        }
    }

    private static func bucketHeight(
        effectiveLineCount: Int,
        thresholds: [(Int, CGFloat)],
        fallback: CGFloat
    ) -> CGFloat {
        for (upperBound, height) in thresholds where effectiveLineCount <= upperBound {
            return height
        }
        return fallback
    }
}
