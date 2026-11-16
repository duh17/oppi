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
    /// The segment and range of the current match. The one source of its mark:
    /// every cell shown takes its mark from this (`findMark(forSegment:)`).
    var marked: (segment: MarkdownReaderSegmentID, range: NSRange)?
    /// The reader arrived and has not yet become the first responder.
    var wantsFocus = false
    /// Extra room under the page while the keyboard and find bar cover its end.
    var keyboardInset: CGFloat = 0
    /// Where the keyboard (with the find bar on it) stands, in the reader's
    /// own coordinates. Nil while the keyboard is hidden or floating; both
    /// keep the find bar's reach clear at each end of the page
    /// (`findUncoveredBand`). Read from the notification: the layout guide is
    /// still moving when the match is placed.
    var keyboardTop: CGFloat?
    /// The match last shown, shown again when the keyboard moves under it.
    var current: ReaderFindMatch?
}

extension NativeFullScreenMarkdownBody: UIFindInteractionDelegate {
    var supportsFind: Bool { offersHeadingNavigation }

    func installFindInteraction() {
        guard supportsFind, findState.interaction == nil else { return }
        let interaction = UIFindInteraction(sessionDelegate: self)
        addInteraction(interaction)
        findState.interaction = interaction
        // The did-notifications too: with a hardware keyboard on iPad the find
        // bar alone stands in for the keyboard, and only those are posted for it.
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidChangeFrameNotification, UIResponder.keyboardDidHideNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(findKeyboardChanged), name: name, object: nil)
        }
    }

    @objc private func findKeyboardChanged(_ note: Notification) {
        let top: CGFloat?
        if note.name == UIResponder.keyboardWillHideNotification || note.name == UIResponder.keyboardDidHideNotification {
            top = nil
        } else if let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            // A floating keyboard is assumed to cover no edge of the page: no frame to keep clear of.
            top = end.isEmpty ? nil : convert(end, from: nil).minY
        } else {
            return
        }
        // The did-notification repeats the will-notification's frame.
        guard top != findState.keyboardTop else { return }
        findState.keyboardTop = top
        updateFindKeyboardInset()
        if let current = findState.current, findState.interaction?.isFindNavigatorVisible == true {
            revealFindMatch(current)
        }
    }

    /// While Find is open the keyboard and the find bar cover the end of the
    /// page: give the page room under its last line, so a match near the end
    /// can scroll up clear of them.
    func updateFindKeyboardInset() {
        let open = findState.interaction?.isFindNavigatorVisible == true
        let overlap = open ? max(0, bounds.height - findUncoveredBand.bottom) : 0
        guard overlap != findState.keyboardInset else { return }
        collectionView.contentInset.bottom += overlap - findState.keyboardInset
        collectionView.verticalScrollIndicatorInsets.bottom += overlap - findState.keyboardInset
        findState.keyboardInset = overlap
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
        findState.current = nil
        updateFindKeyboardInset()
    }

    // MARK: ⌘F and its neighbours

    override var canBecomeFirstResponder: Bool { supportsFind || super.canBecomeFirstResponder }

    /// The find command goes to the first responder, and nothing in a reader
    /// is one until a text view is touched: take it, so ⌘F works on arrival.
    /// The reader is not yet in a visible window when it moves into one, so the
    /// claim is tried again as it lays out, until it holds. Never from a field
    /// someone is typing in (the composer beside the reader).
    override func didMoveToWindow() {
        super.didMoveToWindow()
        findState.wantsFocus = window != nil && supportsFind
        claimFindFocusIfWanted()
    }

    func claimFindFocusIfWanted() {
        guard findState.wantsFocus, window != nil, !bounds.isEmpty else { return }
        if isFirstResponder || isTypingElsewhere || becomeFirstResponder() { findState.wantsFocus = false }
    }

    private var isTypingElsewhere: Bool {
        guard let window, let current = Self.firstResponder(in: window) else { return false }
        return current is UITextInput && !current.isDescendant(of: self)
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
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
        findState.current = match
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
        setFindMark(renderedSegmentIDs.indices.contains(item) ? (renderedSegmentIDs[item], match.range) : nil)
        let path = IndexPath(item: item, section: 0)
        updateFindKeyboardInset()
        collectionView.layoutIfNeeded()
        guard let frame = collectionView.collectionViewLayout.layoutAttributesForItem(at: path)?.frame else { return }
        viewportOwner.explicitFocus(at: frame.minY - collectionView.adjustedContentInset.top - 8)
        collectionView.layoutIfNeeded()
        guard let textView = Self.textView(in: collectionView.cellForItem(at: path)) else { return }
        settleMatchInView(match.range, in: textView)
    }

    /// Leaves a match that already shows fully clear of the find bar and the
    /// keyboard where it is; otherwise brings it into the upper third of what
    /// they leave uncovered, again if the page moved under the scroll: the
    /// heights above it are estimates until their cells are drawn.
    private func settleMatchInView(_ range: NSRange, in textView: UITextView) {
        let band = findUncoveredBand
        // Where the page runs under the top bar, its inset is covered too.
        let bandTop = collectionView.adjustedContentInset.top + band.top
        for _ in 0..<4 {
            guard let rect = Self.rect(of: range, in: textView) else { return }
            let match = collectionView.convert(rect, from: textView)
            let offset = collectionView.contentOffset.y
            if match.minY >= offset + bandTop, match.maxY <= offset + band.bottom { return }
            viewportOwner.explicitFocus(at: match.minY - bandTop - (band.bottom - bandTop) / 3)
            collectionView.layoutIfNeeded()
        }
    }

    /// How far the find bar reaches into the page when no docked keyboard says
    /// where it stands, kept clear at both ends of the page. A floating keyboard
    /// is assumed to report no frame and to move the bar to the top; there the
    /// bar's field sits just under the top bar (≈87–124 pt down the window on
    /// iPad mini). Docked, the bar is 53 pt tall at the default text size and
    /// 79 pt at the largest.
    private static let findBarReach: CGFloat = 80

    /// Room kept between the match and the bar: the bar's field draws a little
    /// above the keyboard frame it rides on (2 pt on iPad mini).
    private static let findBarClearance: CGFloat = 12

    /// The part of the reader, in its own coordinates, that the find bar and
    /// the keyboard leave uncovered while Find is open. The top is measured
    /// below the reader's top inset (the top bar).
    private var findUncoveredBand: (top: CGFloat, bottom: CGFloat) {
        let height = bounds.height
        guard let keyboardTop = findState.keyboardTop, keyboardTop > 0 else {
            // A reader shorter than both reaches keeps an empty band, never a backwards one.
            return (Self.findBarReach, max(Self.findBarReach, height - Self.findBarReach))
        }
        // A keyboard below the reader (a pane short of the screen's bottom) covers none of it.
        guard keyboardTop < height else { return (0, height) }
        return (0, max(0, keyboardTop - Self.findBarClearance))
    }

    // MARK: Highlight

    func clearFindHighlight() {
        setFindMark(nil)
    }

    /// The mark a cell showing `segment` draws. Cells take it as they are
    /// displayed, and the cells on screen take it again when it changes; each
    /// lays it out on its own text whenever that text lays out, so a cell
    /// configured or laid out again after the match is found keeps it.
    func findMark(forSegment segment: MarkdownReaderSegmentID?) -> BaselineSafeTextView.FindMark? {
        guard let marked = findState.marked, segment == marked.segment else { return nil }
        return .init(range: marked.range, color: themeID.palette.ui.yellow.withAlphaComponent(0.45))
    }

    private func setFindMark(_ marked: (segment: MarkdownReaderSegmentID, range: NSRange)?) {
        findState.marked = marked
        for case let cell as FullScreenMarkdownSegmentCell in collectionView.visibleCells {
            cell.findMark = findMark(forSegment: cell.appliedSegmentID)
        }
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
