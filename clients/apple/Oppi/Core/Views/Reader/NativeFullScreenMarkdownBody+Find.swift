import UIKit

/// What a reader's find keeps between searches.
struct ReaderFindState {
    var interaction: UIFindInteraction?
    var session: ReaderFindSession?
    /// The document with every heading open, searched in place of the views.
    var index: ReaderFindIndex?
    var indexTask: Task<Void, Never>?
    var waiting: [@MainActor (ReaderFindIndex) -> Void] = []
    /// A match waiting for its section to open and draw.
    var pending: ReaderFindMatch?
    /// The segment and range the current match is marked at, kept so a cell
    /// configured again (a reload, a new document layout) marks it again.
    var marked: (segment: MarkdownReaderSegmentID, range: NSRange)?
    var highlighted: (layout: NSTextLayoutManager, range: NSTextRange)?
}

extension NativeFullScreenMarkdownBody: UIFindInteractionDelegate {
    var supportsFind: Bool { offersHeadingNavigation }

    func installFindInteraction() {
        guard supportsFind, findState.interaction == nil else { return }
        let interaction = UIFindInteraction(sessionDelegate: self)
        addInteraction(interaction)
        findState.interaction = interaction
    }

    func presentFind() {
        // The find bar rides on the first responder.
        becomeFirstResponder()
        findState.interaction?.presentFindNavigator(showingReplace: false)
    }

    func updateFindResultCount() {
        findState.interaction?.updateResultCount()
    }

    // MARK: Session

    func findInteraction(_ interaction: UIFindInteraction, sessionFor view: UIView) -> UIFindSession? {
        let session = ReaderFindSession(body: self)
        findState.session = session
        return session
    }

    func findInteraction(_ interaction: UIFindInteraction, didEnd session: UIFindSession) {
        clearFindHighlight()
        findState.pending = nil
    }

    // MARK: ⌘F and its neighbours

    override var canBecomeFirstResponder: Bool { supportsFind || super.canBecomeFirstResponder }

    /// The find command goes to the first responder, and nothing in a reader
    /// is one until a text field is touched: take it, so ⌘F works on arrival.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, supportsFind, !isFirstResponder { becomeFirstResponder() }
    }

    override func find(_ sender: Any?) { presentFind() }

    override func findNext(_ sender: Any?) { findState.interaction?.findNext() }

    override func findPrevious(_ sender: Any?) { findState.interaction?.findPrevious() }

    // MARK: Index

    /// Calls `then` with the document's find index, building it first off the
    /// main thread when this is the first search.
    func findIndex(then: @escaping @MainActor (ReaderFindIndex) -> Void) {
        if let index = findState.index {
            then(index)
            return
        }
        findState.waiting.append(then)
        guard findState.indexTask == nil, let config = currentConfig else { return }
        let org = orgControls?.document
        let markdown = latestSnapshot.text
        let identity = config.resourceAccess.identity
        let themeID = config.themeID
        let sourceDirectory = config.sourceDirectory
        let merges = mergesAdjacentTextSegments && lineAnchor == nil
        findState.indexTask = Task { @MainActor [weak self] in
            let index: ReaderFindIndex? = await withCancellableDetachedTask(priority: .userInitiated) {
                var text = markdown
                var ordinals: [Int?]?
                if let org {
                    guard let converted = org.convert(folded: [], cancellationCheck: { Task<Never, Never>.isCancelled }) else { return nil }
                    text = converted.markdown
                    ordinals = converted.headingOrdinals
                }
                let build = FlatSegment.buildWithSourceLineRanges(
                    from: parseCommonMarkLocated(text),
                    themeID: themeID,
                    serverID: identity.serverID,
                    workspaceID: identity.workspaceID,
                    sessionID: identity.sessionID,
                    serverBaseURL: identity.serverBaseURL,
                    sourceDirectory: sourceDirectory,
                    worktreeId: identity.worktreeId,
                    mergeAdjacentTextSegments: merges,
                    splitsAtHeadings: true
                )
                return ReaderFindIndex(
                    texts: build.segments.map(Self.searchableText),
                    sections: ReaderFindIndex.sections(
                        segmentCount: build.segments.count,
                        headingSegments: build.headingSegments,
                        headingOrdinals: ordinals
                    )
                )
            }
            guard let self, let index, !Task.isCancelled else { return }
            self.findState.index = index
            self.findState.indexTask = nil
            let waiting = self.findState.waiting
            self.findState.waiting = []
            for then in waiting { then(index) }
        }
    }

    nonisolated private static func searchableText(of segment: FlatSegment) -> String? {
        switch segment {
        case .text(let text): String(text.characters)
        case .codeBlock(_, let code): code
        default: nil
        }
    }

    // MARK: Reveal

    /// Opens the folded sections above and around `match`, scrolls to it and
    /// marks it. A match in an open section is shown at once; otherwise it
    /// waits for the document to draw again.
    func revealFindMatch(_ match: ReaderFindMatch) {
        let toOpen = readerOutline.sectionsToOpen(forMatchIn: match.section, folded: orgControls?.folded ?? [])
        findState.pending = match
        if !toOpen.isEmpty {
            orgControls?.unfold(toOpen)
            return
        }
        revealPendingFindMatchIfReady()
    }

    func revealPendingFindMatchIfReady() {
        guard let match = findState.pending, let index = findState.index,
              sourcePreparationTask == nil, deferredInitialRenderTask == nil, asyncRenderTask == nil,
              !needsDocumentLayoutPreparation, !renderedSegments.isEmpty, collectionView.bounds.height > 0 else { return }
        let item: Int
        if let section = match.section {
            guard let opens = headingPlacement.segment(forOrdinal: section),
                  let first = index.firstSegment(ofSection: section) else {
                findState.pending = nil
                return
            }
            item = opens + (match.segment - first)
        } else {
            item = match.segment
        }
        findState.pending = nil
        guard renderedSegments.indices.contains(item) else { return }
        removeFindHighlightRendering()
        findState.marked = renderedSegmentIDs.indices.contains(item) ? (renderedSegmentIDs[item], match.range) : nil
        let path = IndexPath(item: item, section: 0)
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.collectionViewLayout.layoutAttributesForItem(at: path)?.frame else { return }
        viewportOwner.explicitFocus(at: frame.minY - collectionView.adjustedContentInset.top - 8)
        collectionView.layoutIfNeeded()
        guard let textView = Self.textView(in: collectionView.cellForItem(at: path)) else { return }
        // A long segment: bring the match itself to the upper third.
        if let rect = Self.rect(of: match.range, in: textView) {
            let y = collectionView.convert(rect, from: textView).minY - collectionView.bounds.height / 3
            viewportOwner.explicitFocus(at: max(y, frame.minY - collectionView.adjustedContentInset.top - 8))
            collectionView.layoutIfNeeded()
        }
        highlight(match.range, in: textView)
    }

    // MARK: Highlight

    func clearFindHighlight() {
        findState.marked = nil
        removeFindHighlightRendering()
    }

    /// A configured cell gets new text views when the document lays out again,
    /// and the old ones take the mark with them: mark the match again.
    func remarkFindMatch(in cell: FullScreenMarkdownSegmentCell) {
        guard let marked = findState.marked, cell.appliedSegmentID == marked.segment,
              let textView = Self.textView(in: cell) else { return }
        highlight(marked.range, in: textView)
    }

    private func removeFindHighlightRendering() {
        guard let (layout, range) = findState.highlighted else { return }
        layout.removeRenderingAttribute(.backgroundColor, for: range)
        findState.highlighted = nil
    }

    private func highlight(_ range: NSRange, in textView: UITextView) {
        removeFindHighlightRendering()
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        layout.addRenderingAttribute(.backgroundColor, value: themeID.palette.ui.yellow.withAlphaComponent(0.45), for: textRange)
        findState.highlighted = (layout, textRange)
    }

    private static func textView(in view: UIView?) -> UITextView? {
        guard let view else { return nil }
        if let text = view as? BaselineSafeTextView { return text }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private static func rect(of range: NSRange, in textView: UITextView) -> CGRect? {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return nil }
        let rect = textView.firstRect(for: textRange)
        return rect.isNull || rect.isInfinite ? nil : rect
    }
}
