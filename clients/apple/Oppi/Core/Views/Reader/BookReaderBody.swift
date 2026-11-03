import UIKit

/// A book open in the reader: the parsed archive, plus where its reading
/// position lives. `FullScreenCodeContent.book` carries one.
struct EPUBReaderDocument {
    let book: EPUBBook
    /// `EPUBReadingPositionStore.key(serverId:origin:path:)` for this file.
    let positionKey: String
    let filePath: String?
    /// The bar's name for the book (its title, else the file name).
    let title: String
}

/// The reading body for a book: one chapter at a time in the Markdown body,
/// with the chapter's name, a table of contents, and Previous/Next.
///
/// The body owns chapter navigation because the reader's content is a value:
/// a chapter is not a new screen, and its position is restored through
/// `ReaderBody.restoreViewport` from the book's saved block.
///
/// Chrome inside the body: `FullScreenCodeViewController` keeps no per-kind bar
/// answers, so the chapter name and TOC live in a header the body draws. The
/// reader's own bar still shows the file, Viewing Options, and Copy.
@MainActor
final class BookReaderBody: UIView {
    private let document: EPUBReaderDocument
    private let themeID: ThemeID
    private let palette: ThemePalette
    private let selectionRouter: ReviewCommentSelectionRouter?
    private let sourceContext: ReviewCommentSourceContext?
    private let positionStore: EPUBReadingPositionStore

    private let header = UIView()
    private let titleLabel = UILabel()
    private let tocButton = UIButton(type: .system)
    private let footer = UIView()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let placeholder = UILabel()
    private let contentHost = UIView()

    private(set) var chapterIndex: Int
    private var chapterSource: EPUBChapterSource
    private var chapterBody: NativeFullScreenMarkdownBody?
    private var readerPreferences: FullScreenReaderPreferences
    /// Set while the stored position is being applied to a freshly built
    /// chapter, so a scroll callback cannot save offset 0 over it.
    private var isRestoringPosition = false
    /// The position to apply once this body has a size. A reader creates the
    /// body before it is laid out, and a restore on a zero-height scroll view
    /// would clamp to the top and be read as settled.
    private var pendingRestore: EPUBReadingPosition?

    init(
        document: EPUBReaderDocument,
        themeID: ThemeID,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        positionStore: EPUBReadingPositionStore = EPUBReadingPositionStore()
    ) {
        self.document = document
        self.themeID = themeID
        self.palette = palette
        self.readerPreferences = readerPreferences
        self.selectionRouter = reviewCommentSelectionRouter
        self.sourceContext = reviewCommentSourceContext
        self.positionStore = positionStore

        let saved = positionStore.position(for: document.positionKey)
        let chapter = saved.flatMap { document.book.chapterIndex(forHref: $0.chapterHref) }
            ?? document.book.firstChapterIndex
        self.chapterIndex = chapter
        self.chapterSource = (try? document.book.source(forChapter: chapter)) ?? .unavailable

        super.init(frame: .zero)
        setUpChrome()
        installChapterBody()
        restoreStoredPosition(saved)
        observeBackgrounding()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A force-quit mid-chapter would rewind to the last chapter change; the
    /// system says it is going away first, which is the last chance to write.
    private func observeBackgrounding() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(persistOnBackgrounding),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func persistOnBackgrounding() {
        persistPosition()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        applyPendingRestore()
    }

    // MARK: - Chrome

    private func setUpChrome() {
        backgroundColor = palette.ui.bgDark
        header.backgroundColor = palette.ui.bgDark
        footer.backgroundColor = palette.ui.bgDark

        titleLabel.font = .scaled(.headline)
        titleLabel.textColor = palette.ui.fg
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "fullScreen.book.title"

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "list.bullet")
        tocButton.configuration = configuration
        tocButton.tintColor = palette.ui.blue
        tocButton.accessibilityIdentifier = "fullScreen.book.toc"
        tocButton.showsMenuAsPrimaryAction = true
        tocButton.accessibilityLabel = String(localized: "Table of Contents")
        tocButton.menu = makeTableOfContentsMenu()

        for (button, title, identifier, symbol) in [
            (previousButton, String(localized: "Previous"), "fullScreen.book.previous", "chevron.backward"),
            (nextButton, String(localized: "Next"), "fullScreen.book.next", "chevron.forward"),
        ] {
            var buttonConfiguration = UIButton.Configuration.plain()
            buttonConfiguration.title = title
            buttonConfiguration.image = UIImage(systemName: symbol)
            buttonConfiguration.imagePlacement = symbol == "chevron.backward" ? .leading : .trailing
            buttonConfiguration.imagePadding = 4
            button.configuration = buttonConfiguration
            button.tintColor = palette.ui.blue
            button.accessibilityIdentifier = identifier
        }
        previousButton.addTarget(self, action: #selector(previousChapter), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextChapter), for: .touchUpInside)

        placeholder.font = .scaled(.body)
        placeholder.textColor = palette.ui.fgDim
        placeholder.textAlignment = .center
        placeholder.numberOfLines = 0
        placeholder.text = String(localized: "This chapter can't be shown yet")
        placeholder.accessibilityIdentifier = "fullScreen.book.unavailable"
        placeholder.isHidden = true

        for view in [header, footer, contentHost, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [titleLabel, tocButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [previousButton, nextButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(equalTo: tocButton.leadingAnchor, constant: -8),

            tocButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            tocButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            tocButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            tocButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            header.heightAnchor.constraint(greaterThanOrEqualTo: tocButton.heightAnchor),

            contentHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: footer.topAnchor),

            placeholder.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.topAnchor.constraint(equalTo: previousButton.topAnchor, constant: -6),
            footer.bottomAnchor.constraint(equalTo: previousButton.bottomAnchor, constant: 6),

            previousButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            previousButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            nextButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        updateChrome()
    }

    /// The TOC menu is built when it opens, so a long table does not cost a
    /// menu until the person asks for it.
    private func makeTableOfContentsMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else {
                    completion([])
                    return
                }
                completion(self.tableOfContentsActions())
            },
        ])
    }

    private func tableOfContentsActions() -> [UIMenuElement] {
        // A row that names no chapter in the spine (a cover, a note outside the
        // reading order) would be a row that does nothing when tapped.
        let rows = document.book.toc.compactMap { entry -> (EPUBTOCEntry, Int)? in
            guard let chapter = document.book.chapterIndex(forHref: entry.href) else { return nil }
            return (entry, chapter)
        }
        return rows.map { (entry, chapter) in
            UIAction(
                title: entry.title,
                image: entry.level > 0 ? UIImage(systemName: "arrow.turn.down.right") : nil,
                state: chapter == chapterIndex ? .on : .off
            ) { [weak self] _ in
                self?.showChapter(at: chapter, restoring: nil)
            }
        }
    }

    private func updateChrome() {
        let chapter = document.book.chapters.indices.contains(chapterIndex)
            ? document.book.chapters[chapterIndex]
            : nil
        titleLabel.text = chapter?.title ?? document.title
        previousButton.isEnabled = chapterIndex > 0
        nextButton.isEnabled = chapterIndex + 1 < document.book.chapters.count
        tocButton.menu = makeTableOfContentsMenu()
        updateChapterAccessibility()
    }

    private func updateChapterAccessibility() {
        let chapter = document.book.chapters.indices.contains(chapterIndex)
            ? document.book.chapters[chapterIndex]
            : nil
        let position = "\(min(chapterIndex + 1, document.book.chapters.count)) of \(document.book.chapters.count)"
        titleLabel.accessibilityValue = position
        nextButton.accessibilityValue = chapter?.title
        previousButton.accessibilityValue = chapter?.title
    }

    // MARK: - Chapters

    private func installChapterBody() {
        chapterBody?.removeFromSuperview()
        chapterBody = nil
        // The chapter's direction belongs to the whole body, so an unavailable
        // chapter's placeholder and the footer follow it too.
        if document.book.readsRightToLeft || chapterSource.isRightToLeft == true {
            semanticContentAttribute = .forceRightToLeft
        } else {
            semanticContentAttribute = .forceLeftToRight
        }

        let available = chapterSource.isAvailable
        placeholder.isHidden = available
        guard available else { return }

        let body = NativeFullScreenMarkdownBody(
            content: chapterSource.markdown,
            themeID: themeID,
            palette: palette,
            reviewCommentSelectionRouter: selectionRouter,
            reviewCommentSourceContext: sourceContext,
            sourceFilePath: document.filePath,
            readerPreferences: readerPreferences,
            perfSurface: .fullScreenMarkdown,
            mergeAdjacentTextSegments: false
        )
        body.translatesAutoresizingMaskIntoConstraints = false
        body.accessibilityIdentifier = "fullScreen.book.body"
        contentHost.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: contentHost.topAnchor),
            body.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
        ])
        chapterBody = body
    }

    /// Opens `chapter`, saving where the person was in the chapter they leave.
    private func showChapter(at chapter: Int, restoring position: EPUBReadingPosition?) {
        guard document.book.chapters.indices.contains(chapter), chapter != chapterIndex else { return }
        persistPosition()
        chapterIndex = chapter
        chapterSource = (try? document.book.source(forChapter: chapter)) ?? .unavailable
        pendingRestore = nil
        installChapterBody()
        updateChrome()
        if let position, document.book.chapterIndex(forHref: position.chapterHref) == chapter {
            restoreStoredPosition(position)
        } else if let body = chapterBody {
            body.restoreViewport(.top)
        }
    }

    @objc private func previousChapter() {
        showChapter(at: chapterIndex - 1, restoring: nil)
    }

    @objc private func nextChapter() {
        showChapter(at: chapterIndex + 1, restoring: nil)
    }

    // MARK: - Position

    /// The body's own position, in the chart the store keeps: which block of
    /// this chapter is at the top, and how far into it the viewport sits.
    private func currentPosition() -> EPUBReadingPosition? {
        guard document.book.chapters.indices.contains(chapterIndex),
              let body = chapterBody,
              !isRestoringPosition else { return nil }
        let blockCount = chapterSource.blocks.count
        guard blockCount > 0 else { return nil }
        let intent = body.viewportIntent
        let anchor: FullScreenMarkdownViewportAnchor?
        switch intent {
        case .detached(let detached):
            anchor = detached
        case .top, .tail, nil:
            anchor = nil
        }
        let ordinal: Int
        let offset: Double
        if let anchor, let segment = anchor.segmentID {
            ordinal = chapterSource.blocks.lastIndex {
                $0.markdownStartLine <= segment.sourceStartLine
            } ?? 0
            offset = Double(anchor.offsetInItem)
        } else if case .tail = intent {
            ordinal = blockCount - 1
            offset = 0
        } else {
            ordinal = 0
            offset = 0
        }
        return EPUBReadingPosition(
            chapterHref: document.book.chapters[chapterIndex].href,
            blockOrdinal: min(max(ordinal, 0), blockCount - 1),
            offsetPoints: offset
        )
    }

    private func persistPosition() {
        guard let position = currentPosition() else { return }
        positionStore.save(position, for: document.positionKey)
    }

    private func restoreStoredPosition(_ position: EPUBReadingPosition?) {
        guard let position,
              document.book.chapterIndex(forHref: position.chapterHref) == chapterIndex,
              chapterSource.blocks.indices.contains(position.blockOrdinal) else { return }
        pendingRestore = position
        applyPendingRestore()
    }

    /// Hands the stored block to the chapter body once it can place it.
    private func applyPendingRestore() {
        guard let position = pendingRestore,
              bounds.width > 0,
              document.book.chapterIndex(forHref: position.chapterHref) == chapterIndex,
              chapterSource.blocks.indices.contains(position.blockOrdinal),
              let body = chapterBody else { return }
        pendingRestore = nil
        let block = chapterSource.blocks[position.blockOrdinal]
        isRestoringPosition = true
        let anchor = FullScreenMarkdownViewportAnchor(
            segmentID: MarkdownReaderSegmentID(
                kind: Self.segmentKind(for: block.kind),
                sourceStartLine: block.markdownStartLine,
                occurrenceOrdinal: 0
            ),
            offsetInItem: CGFloat(position.offsetPoints),
            absoluteOffset: 0
        )
        body.restoreViewport(.detached(anchor))
        // The restore write lands on a later layout pass; `viewportIntent` reads
        // nil until it does, so the position cannot be saved as offset 0.
        DispatchQueue.main.async { [weak self] in
            self?.isRestoringPosition = false
        }
    }

    private static func segmentKind(for kind: EPUBChapterBlock.Kind) -> MarkdownReaderSegmentID.Kind {
        switch kind {
        case .text: .text
        case .code: .code
        case .table: .table
        case .thematicBreak: .thematicBreak
        }
    }

    /// Copy and Share read the chapter that is on screen, not the one the
    /// content was built with.
    var chapterText: String {
        chapterSource.isAvailable ? chapterSource.markdown : ""
    }
}

// MARK: - ReaderBody

extension BookReaderBody: ReaderBody {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        readerPreferences = preferences
        chapterBody?.applyReaderPreferences(preferences)
    }

    var viewportIntent: FullScreenMarkdownViewportIntent? {
        // The reader asks for the position when it leaves or rebuilds; a book
        // remembers it across launches, which the reader's intent cannot carry.
        persistPosition()
        return chapterBody?.viewportIntent
    }

    @discardableResult
    func restoreViewport(_ intent: FullScreenMarkdownViewportIntent) -> Bool {
        chapterBody?.restoreViewport(intent) ?? false
    }

    var liveCopyText: String? {
        let text = chapterText
        return text.isEmpty ? nil : text
    }
}
