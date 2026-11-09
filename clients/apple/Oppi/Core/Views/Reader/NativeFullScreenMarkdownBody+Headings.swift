import UIKit

/// Where the reader's headings are and which is waiting to be scrolled to.
///
/// The reader builds its segments so that each heading opens one
/// (`FlatSegment.BuildResult.headingSegments`), which makes a heading's place
/// the top of a collection item: no text layout is needed to find it.
struct ReaderHeadingPlacement {
    /// The segment each of the document's heading blocks opens, in order.
    var segments: [Int?] = []
    /// An Org reader's heading blocks by Org heading ordinal (`OrgFolding`),
    /// in the same order. A Markdown reader's k-th heading block is ordinal k.
    var orgOrdinals: [Int?]?
    /// A heading to scroll to once the document has drawn.
    var pending: ReaderHeadingAnchor?
    /// A Markdown document's headings, read from its text on first use.
    var markdownOutline: ReaderOutline?

    func segment(forOrdinal ordinal: Int) -> Int? {
        let block: Int?
        if let orgOrdinals { block = orgOrdinals.firstIndex(of: ordinal) } else { block = ordinal - 1 }
        guard let block, segments.indices.contains(block) else { return nil }
        return segments[block]
    }
}

extension NativeFullScreenMarkdownBody {
    /// A reader of a file keeps each heading at the head of its own segment, so
    /// the outline and heading links have a place to scroll to. A reader of
    /// loose text (a tool result, a chat message) keeps its text merged.
    var offersHeadingNavigation: Bool { orgControls != nil || sourceFilePath != nil }

    /// The document's headings.
    var readerOutline: ReaderOutline {
        if let orgControls { return orgControls.document.outline }
        if let outline = headingPlacement.markdownOutline { return outline }
        let outline = ReaderOutline.markdown(parseCommonMarkLocated(latestSnapshot.text))
        headingPlacement.markdownOutline = outline
        return outline
    }

    /// Scrolls to the heading `anchor` names, opening any folded section above
    /// it first. False when the document has no such heading.
    @discardableResult
    func scrollToHeading(_ anchor: ReaderHeadingAnchor) -> Bool {
        guard readerOutline.resolve(anchor) != nil else { return false }
        headingPlacement.pending = anchor
        scrollToPendingHeadingIfReady()
        return true
    }

    /// The tap action of an in-document link (`#title=…`, `#custom=…`,
    /// `#some-heading`), or nil for any other link.
    func headingAction(for url: URL) -> UIAction? {
        guard offersHeadingNavigation, url.scheme == nil, url.host == nil, url.path.isEmpty,
              let fragment = url.fragment, let anchor = ReaderHeadingAnchor(fragment: fragment) else { return nil }
        return UIAction { [weak self] _ in self?.scrollToHeading(anchor) }
    }

    /// Runs from every point a render can finish. A heading under a folded
    /// section waits for the section to open and the document to draw again.
    func scrollToPendingHeadingIfReady() {
        guard let anchor = headingPlacement.pending,
              sourcePreparationTask == nil, deferredInitialRenderTask == nil, asyncRenderTask == nil,
              !needsDocumentLayoutPreparation, !renderedSegments.isEmpty, collectionView.bounds.height > 0 else { return }
        let outline = readerOutline
        guard let heading = outline.resolve(anchor) else {
            headingPlacement.pending = nil
            return
        }
        if orgControls?.unfold(outline.ancestors(of: heading.ordinal)) == true {
            headingPlacement.pending = .ordinal(heading.ordinal)
            return
        }
        headingPlacement.pending = nil
        guard let item = headingPlacement.segment(forOrdinal: heading.ordinal) else { return }
        collectionView.layoutIfNeeded()
        guard let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: item, section: 0)
        ) else { return }
        viewportOwner.explicitFocus(at: attributes.frame.minY - collectionView.adjustedContentInset.top - 8)
        collectionView.layoutIfNeeded()
        if let cell = collectionView.cellForItem(at: IndexPath(item: item, section: 0)) {
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }
    }
}
