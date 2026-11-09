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

    /// The tap action of a link to a heading of this document
    /// (`ReaderHeadingAnchor.linkDestination`), or nil for any other link.
    func headingAction(for url: URL) -> UIAction? {
        guard offersHeadingNavigation, let anchor = ReaderHeadingAnchor(linkURL: url) else { return nil }
        return UIAction { [weak self] _ in self?.scrollToHeading(anchor) }
    }

    /// Runs from every point a render can finish. A heading under a folded
    /// section waits for the section to open and the document to draw again.
    func scrollToPendingHeadingIfReady() {
        revealPendingFindMatchIfReady()
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

// MARK: - Outline

extension ReaderHeadingPlacement {
    /// Whether the document has a heading the reader can scroll to.
    var hasHeadings: Bool {
        if let orgOrdinals { return orgOrdinals.contains { $0 != nil } }
        return segments.contains { $0 != nil }
    }
}

extension NativeFullScreenMarkdownBody {
    var hasOutline: Bool { headingPlacement.hasHeadings }

    /// One row per heading, indented from the shallowest level present.
    func outlineRows() -> [BookTableOfContentsViewController.Row] {
        let outline = readerOutline
        let top = outline.headings.map(\.level).min() ?? 1
        return outline.headings.map { heading in
            BookTableOfContentsViewController.Row(
                title: heading.title.isEmpty ? String(localized: "Untitled") : heading.title,
                level: heading.level - top,
                chapter: heading.ordinal,
                keyword: heading.keyword,
                isDone: heading.isDone,
                identifier: "fileViewer.outline.row.\(heading.ordinal)"
            )
        }
    }

    func presentOutline(from host: UIViewController, sourceItem: UIBarButtonItem) {
        let rows = outlineRows()
        guard !rows.isEmpty else { return }
        let list = BookTableOfContentsViewController(
            bookTitle: String(localized: "Outline"),
            rows: rows,
            currentChapter: -1,
            palette: themeID.palette,
            identifierPrefix: "fileViewer.outline"
        ) { [weak self] ordinal in
            self?.scrollToHeading(.ordinal(ordinal))
        }
        // A popover from the bar button where the window is wide (iPad); at a
        // narrow width UIKit adapts it to a sheet, which opens at medium height
        // so the page stays in view.
        list.modalPresentationStyle = .popover
        list.preferredContentSize = CGSize(width: 380, height: 560)
        if let popover = list.popoverPresentationController {
            popover.sourceItem = sourceItem
            popover.permittedArrowDirections = .up
            popover.adaptiveSheetPresentationController.detents = [.medium(), .large()]
            popover.adaptiveSheetPresentationController.prefersGrabberVisible = true
        }
        (host.presentedViewController ?? host).present(list, animated: true)
    }
}
