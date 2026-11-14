import UIKit

/// Stable identity for a rendered full-screen Markdown segment.
///
/// The ordinal is assigned after block splitting and adjacent-text merging. A
/// top-level block can emit several same-kind segments (for example two images
/// in one paragraph or two code blocks nested in one list), so source line and
/// kind alone are not unique.
struct MarkdownReaderSegmentID: Hashable, Sendable {
    let kind: Kind
    let sourceStartLine: Int
    let occurrenceOrdinal: Int

    enum Kind: String, Hashable, Sendable {
        case text
        case code
        case table
        case thematicBreak
        case image
        case video
        case audio
        case usdz
        case mermaid
        case geoJSON
        case latex
    }
}

extension FlatSegment {
    var markdownReaderKind: MarkdownReaderSegmentID.Kind {
        switch self {
        case .text: .text
        case .codeBlock: .code
        case .table: .table
        case .thematicBreak: .thematicBreak
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .usdz: .usdz
        case .mermaidDiagram: .mermaid
        case .geoJSONMap: .geoJSON
        case .latexBlock: .latex
        }
    }

    static func readerSegmentIDs(
        segments: [FlatSegment],
        sourceLineRanges: [ClosedRange<Int>?]
    ) -> [MarkdownReaderSegmentID] {
        struct BaseKey: Hashable {
            let kind: MarkdownReaderSegmentID.Kind
            let sourceStartLine: Int
        }

        var occurrences: [BaseKey: Int] = [:]
        return segments.enumerated().map { index, segment in
            // Located CommonMark normally provides every top-level start line.
            // Keep the fallback deterministic for malformed parser output.
            let sourceStart = sourceLineRanges.indices.contains(index)
                ? (sourceLineRanges[index]?.lowerBound ?? index + 1)
                : index + 1
            let key = BaseKey(kind: segment.markdownReaderKind, sourceStartLine: sourceStart)
            let ordinal = occurrences[key, default: 0]
            occurrences[key] = ordinal + 1
            return MarkdownReaderSegmentID(
                kind: key.kind,
                sourceStartLine: key.sourceStartLine,
                occurrenceOrdinal: ordinal
            )
        }
    }
}

/// ID-keyed geometry state for the full-screen Markdown reader.
///
/// Estimated geometry is replaceable. A final height is valid only for the
/// exact canonical width and immutable document generation that produced it.
/// Reconfiguration resets the generation and rejects prior asynchronous work.
struct MarkdownReaderHeightLedger {
    /// Immutable identity captured when asynchronous geometry work starts.
    /// A stable segment ID is not enough because a later document or width
    /// generation can invalidate work that is still running.
    struct WorkToken: Equatable, Sendable {
        let id: MarkdownReaderSegmentID
        let canonicalWidth: CGFloat
        let generation: Int
    }

    enum Geometry: Equatable {
        case estimated(CGFloat)
        case final(height: CGFloat, width: CGFloat)

        var height: CGFloat {
            switch self {
            case .estimated(let height), .final(let height, _): height
            }
        }

        func finalHeight(at width: CGFloat) -> CGFloat? {
            guard case .final(let height, let committedWidth) = self,
                  abs(committedWidth - width) <= 0.5 else { return nil }
            return height
        }
    }

    struct Commit: Equatable {
        let accepted: Bool
        let deltaBeforeAnchor: CGFloat
    }

    private(set) var generation = 0
    private(set) var orderedIDs: [MarkdownReaderSegmentID] = []
    private var geometryByID: [MarkdownReaderSegmentID: Geometry] = [:]

    mutating func applyDocument(
        ids: [MarkdownReaderSegmentID],
        estimates: [CGFloat],
        canonicalWidth: CGFloat
    ) {
        precondition(ids.count == estimates.count)
        generation &+= 1
        geometryByID.removeAll(keepingCapacity: true)
        for (id, estimate) in zip(ids, estimates) {
            geometryByID[id] = .estimated(ceil(max(1, estimate)))
        }
        orderedIDs = ids
    }

    mutating func invalidateWidth(_ canonicalWidth: CGFloat) {
        generation &+= 1
        for id in orderedIDs {
            guard let geometry = geometryByID[id] else { continue }
            if case .final(let height, let width) = geometry,
               abs(width - canonicalWidth) > 0.5 {
                geometryByID[id] = .estimated(height)
            }
        }
    }

    func workToken(
        for id: MarkdownReaderSegmentID,
        canonicalWidth: CGFloat
    ) -> WorkToken? {
        guard orderedIDs.contains(id) else { return nil }
        return WorkToken(
            id: id,
            canonicalWidth: canonicalWidth,
            generation: generation
        )
    }

    mutating func commitFinal(
        token: WorkToken,
        height: CGFloat,
        anchorID: MarkdownReaderSegmentID?
    ) -> Commit {
        guard token.generation == generation,
              let index = orderedIDs.firstIndex(of: token.id),
              height.isFinite,
              token.canonicalWidth.isFinite,
              token.canonicalWidth > 0 else {
            return Commit(accepted: false, deltaBeforeAnchor: 0)
        }
        let next = ceil(max(1, height))
        let previous = geometryByID[token.id]?.height ?? next
        geometryByID[token.id] = .final(height: next, width: token.canonicalWidth)

        let isBeforeAnchor: Bool
        if let anchorID, let anchorIndex = orderedIDs.firstIndex(of: anchorID) {
            isBeforeAnchor = index < anchorIndex
        } else {
            isBeforeAnchor = false
        }
        return Commit(
            accepted: true,
            deltaBeforeAnchor: isBeforeAnchor ? next - previous : 0
        )
    }

    mutating func setEstimatedHeight(_ height: CGFloat, for id: MarkdownReaderSegmentID) {
        guard orderedIDs.contains(id), height.isFinite else { return }
        geometryByID[id] = .estimated(ceil(max(1, height)))
    }

    func geometry(for id: MarkdownReaderSegmentID) -> Geometry? {
        geometryByID[id]
    }

    func finalHeight(for id: MarkdownReaderSegmentID, canonicalWidth: CGFloat) -> CGFloat? {
        geometryByID[id]?.finalHeight(at: canonicalWidth)
    }

    func heights() -> [CGFloat] {
        orderedIDs.map { geometryByID[$0]?.height ?? 44 }
    }
}

/// The first-paint height of a segment, which the ledger holds until the
/// segment is measured. Nothing is typeset: the estimate only positions items
/// until the reader scrolls to them.
@MainActor
enum MarkdownReaderHeightEstimate {
    static func height(for segment: FlatSegment, containerWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, containerWidth - 24)
        switch segment {
        case .text(let attributed):
            // Wrapped line count from character counts.
            return ceil(textHeight(String(attributed.characters), contentWidth: contentWidth, lineSpacing: 8))
        case .codeBlock(_, let code):
            // Monospace glyphs are wider than proportional text.
            return ceil(textHeight(code, contentWidth: contentWidth, charWidth: 9.6, lineHeight: 16, lineSpacing: 56))
        case .table(let headers, let rows, _):
            let metrics = NativeTableBlockView.measureNaturalColumns(headers: headers, rows: rows)
            if metrics.breaksLines || MarkdownTableColumnLayout.needsGridMode(naturalWidths: metrics.columnWidths) {
                return CGFloat(max(headers.isEmpty ? 1 : 1, rows.count + 1)) * 56 + 16
            }
            let lineCount = CGFloat(1 + rows.count)
            return lineCount * 22 + 16
        case .thematicBreak:
            return 8
        case .image:
            return 180
        case .video:
            return MarkdownInlineVideoLayout.reservedHeight(forWidth: contentWidth)
        case .audio:
            return MarkdownInlineAudioLayout.reservedHeight(forWidth: contentWidth)
        case .usdz:
            return MarkdownInlineUSDZLayout.reservedHeight(forWidth: contentWidth)
        case .mermaidDiagram(let code):
            // Mermaid parsing is too expensive for first paint. Estimate
            // from diagram source lines; the background prefetch renders
            // the real raster before the user reaches the item.
            let lineCount = CGFloat(newlineCount(code) + 1)
            return min(400, max(120, lineCount * 24 + 44))
        case .geoJSONMap:
            return 220
        case .latexBlock(let code):
            // TeX parsing plus CoreGraphics layout is too expensive for
            // first paint. Estimate from source lines; real rasters are
            // prefetched in the background before the user scrolls here.
            let lineCount = CGFloat(newlineCount(code) + 1)
            return min(400, max(44, lineCount * 28 + 24))
        }
    }

    nonisolated static func newlineCount(_ string: String) -> Int {
        var count = 0
        for byte in string.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
        }
        return count
    }

    /// Cheap wrapped-line estimate. A ~9 pt average glyph width overestimates
    /// slightly, so cells never collapse to clipped heights.
    private static func textHeight(
        _ text: String,
        contentWidth: CGFloat,
        charWidth: CGFloat = 9.0,
        lineHeight: CGFloat = 20,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty else { return max(22, lineHeight + lineSpacing) }
        let width = max(1, contentWidth)
        var lines: CGFloat = 0
        var paragraphScalars: CGFloat = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                lines += max(1, (paragraphScalars * charWidth / width).rounded(.up))
                paragraphScalars = 0
            } else {
                paragraphScalars += 1
            }
        }
        lines += max(1, (paragraphScalars * charWidth / width).rounded(.up))
        return max(22, lines * lineHeight + lineSpacing)
    }
}

/// The only reasons the Markdown reader may write its vertical content offset.
enum MarkdownReaderOffsetWriteReason: String, Equatable, Sendable {
    case preserveAnchor
    case followTail
    case explicitFocus
}

enum MarkdownReaderLayoutReplacementReason: String, Equatable, Sendable {
    case document
    case renderAhead
    case preparedGeometry
    case visibleReconciliation
    case interactionEnded
    case readerPreferences
    case testing
}

/// Pure viewport policy used by the UIKit owner and unit tests.
typealias MarkdownReaderViewportPolicy = LiveStreamingPresentation.ViewportPolicy

@MainActor
final class MarkdownReaderViewportOwner {
    private weak var scrollView: UIScrollView?
    private let performLayout: () -> Void
    private var policy: MarkdownReaderViewportPolicy
    private var pendingFollowGeneration = 0
    private var pendingFocusGeneration = 0

    var onOffsetWrite: ((MarkdownReaderOffsetWriteReason, CGFloat, CGFloat) -> Void)?

    init(scrollView: UIScrollView, followsTail: Bool, performLayout: @escaping () -> Void) {
        self.scrollView = scrollView
        self.performLayout = performLayout
        policy = MarkdownReaderViewportPolicy(followsTail: followsTail)
    }

    var followsTail: Bool { policy.followsTail }
    var isInteracting: Bool { policy.isInteracting }

    func streamStarted() {
        _ = policy.handle(.streamStarted)
    }

    func streamCompleted() {
        _ = policy.handle(.streamCompleted)
        cancelQueuedAutomaticWrites()
    }

    func interactionBegan() {
        _ = policy.handle(.interactionBegan)
        cancelQueuedAutomaticWrites()
    }

    func touchDown() {
        interactionBegan()
    }

    func interactionEnded(isStreaming: Bool) {
        let intent = policy.handle(.interactionEnded(
            isNearBottom: isNearBottom,
            isStreaming: isStreaming
        ))
        if intent == .followTail { scheduleFollowTail() }
    }

    func scheduleFollowTail() {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              policy.handle(.requestFollowTail) == .followTail else { return }
        pendingFollowGeneration &+= 1
        let generation = pendingFollowGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.pendingFollowGeneration,
                  self.rejectUIKitOwnedInteractionIfNeeded(),
                  self.policy.handle(.requestFollowTail) == .followTail else { return }
            self.performLayout()
            guard self.rejectUIKitOwnedInteractionIfNeeded() else { return }
            self.writeOffset(self.bottomOffsetY, reason: .followTail)
        }
    }

    func scheduleExplicitFocus(_ target: @escaping @MainActor () -> CGFloat?) {
        guard rejectUIKitOwnedInteractionIfNeeded() else { return }
        pendingFocusGeneration &+= 1
        let generation = pendingFocusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.pendingFocusGeneration,
                  self.rejectUIKitOwnedInteractionIfNeeded(),
                  self.policy.handle(.requestExplicitFocus) == .explicitFocus,
                  let y = target() else { return }
            self.writeOffset(y, reason: .explicitFocus)
        }
    }

    func preserveAnchor(at y: CGFloat) {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              policy.handle(.requestPreserveAnchor) == .preserveAnchor else { return }
        writeOffset(y, reason: .preserveAnchor)
    }

    func explicitFocus(at y: CGFloat) {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              policy.handle(.requestExplicitFocus) == .explicitFocus else { return }
        writeOffset(y, reason: .explicitFocus)
    }

    func cancelQueuedAutomaticWrites() {
        pendingFollowGeneration &+= 1
        pendingFocusGeneration &+= 1
    }

    /// Returns false after transferring ownership to UIKit. This check is made
    /// both when work is queued and immediately before a write so touch-down,
    /// dragging, or deceleration can win a main-queue race.
    @discardableResult
    private func rejectUIKitOwnedInteractionIfNeeded() -> Bool {
        guard let scrollView else { return false }
        let panState = scrollView.panGestureRecognizer.state
        let isUIKitOwned = scrollView.isTracking
            || scrollView.isDragging
            || scrollView.isDecelerating
            || panState == .began
            || panState == .changed
        guard isUIKitOwned else { return true }
        interactionBegan()
        return false
    }

    private func writeOffset(_ requestedY: CGFloat, reason: MarkdownReaderOffsetWriteReason) {
        guard rejectUIKitOwnedInteractionIfNeeded(),
              let scrollView, requestedY.isFinite else { return }
        let oldY = scrollView.contentOffset.y
        let y = min(max(requestedY, minimumOffsetY), maximumOffsetY)
        guard abs(oldY - y) > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: y),
            animated: false
        )
        CATransaction.commit()
        onOffsetWrite?(reason, oldY, y)
    }

    private var minimumOffsetY: CGFloat {
        guard let scrollView else { return 0 }
        return -scrollView.adjustedContentInset.top
    }

    private var maximumOffsetY: CGFloat {
        guard let scrollView else { return 0 }
        return max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
    }

    private var bottomOffsetY: CGFloat { maximumOffsetY }

    private var isNearBottom: Bool {
        guard let scrollView else { return false }
        let viewportHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        guard viewportHeight > 0 else { return false }
        let visibleBottom = scrollView.contentOffset.y
            + scrollView.adjustedContentInset.top
            + viewportHeight
        return scrollView.contentSize.height - visibleBottom <= 28
    }
}
