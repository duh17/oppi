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

/// The reading body for a book: one chapter at a time, as screen-sized pages by
/// default or as one scrolling column when the person asks for it.
///
/// The body owns chapter navigation because the reader's content is a value:
/// a chapter is not a new screen, and its position is restored through
/// `ReaderBody.restoreViewport` from the book's saved block.
///
/// Chrome inside the body: `FullScreenCodeViewController` keeps no per-kind bar
/// answers, so the chapter name, the table of contents, and the appearance
/// control live in a header the body draws. Paged reading floats that header over
/// the page and asks the reader to fade its own controls too, until a tap in the
/// middle of the page brings them back.
@MainActor
final class BookReaderBody: UIView {
    private let document: EPUBReaderDocument
    private let themeID: ThemeID
    private let palette: ThemePalette
    private let selectionRouter: ReviewCommentSelectionRouter?
    private let sourceContext: ReviewCommentSourceContext?
    private let positionStore: EPUBReadingPositionStore
    private let modeStore: BookReaderPageModeStore
    private let appearanceStore: BookReaderAppearanceStore
    private var appearance: BookReaderAppearance

    private let header = UIView()
    private let titleLabel = UILabel()
    private let tocButton = UIButton(type: .system)
    private let appearanceButton = UIButton(type: .system)
    private let footer = UIView()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progressBar = UIView()
    private let progressLeadingLabel = UILabel()
    private let progressTrailingLabel = UILabel()
    private let placeholder = UILabel()
    private let contentHost = UIView()
    private let pagedView = BookPagedView()
    private lazy var scrollContentConstraints = [
        contentHost.topAnchor.constraint(equalTo: header.bottomAnchor),
        contentHost.bottomAnchor.constraint(equalTo: footer.topAnchor),
        contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
        contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
    ]
    /// The header's top, which paged reading pushes below the reader's floating
    /// bar: the bar's items sit in a band the safe area does not reserve, so a
    /// floating header at the safe area's top would put its controls under
    /// them.
    private lazy var headerTop = header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
    /// The reader's bar items occupy this much height at the top of the content.
    private static let readerBarClearance: CGFloat = 54
    private lazy var pagedContentConstraints = [
        contentHost.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        contentHost.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
        contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
    ]
    /// Height of the "Page 3 of 12" line at the foot of a page.
    static let progressHeight: CGFloat = 26
    /// Where the reading-time estimate comes from: 250 words a minute.
    static let wordsPerMinute: Double = 250
    /// Breathing room between the chapter's last line and the reader's
    /// floating control, which is drawn over this body.
    private static let floatingControlGap: CGFloat = 8

    private(set) var chapterIndex: Int
    private var chapterSource: EPUBChapterSource
    private var chapterBody: NativeFullScreenMarkdownBody?
    private var readerPreferences: FullScreenReaderPreferences
    private(set) var mode: BookReaderPageMode
    private var style: BookPageStyle
    private var pages: BookChapterPages?
    /// The text area the pages were last laid out at; a change re-paginates.
    private var paginatedTextSize: CGSize = .zero
    /// Set while the stored position is being applied to a freshly built
    /// chapter, so a scroll callback cannot save offset 0 over it.
    private var isRestoringPosition = false
    /// The position to apply once this body has a size. A reader creates the
    /// body before it is laid out, and a page chosen on a zero-height view would
    /// be read as settled.
    private var pendingRestore: EPUBReadingPosition?
    private var scrollObservation: NSKeyValueObservation?
    /// The character the person's position is at: the one a restore put on
    /// screen, or the first character of the page they turned to. It changes
    /// only when the person moves it, so a layout that settles afterwards (a
    /// sheet's final size, a body rebuilt on the way out) cannot walk the saved
    /// position back into an earlier page.
    private var positionCharacter: Int?
    private var scrollProgressPercent = -1
    /// Paged reading starts with the chrome out of the way; the flag keeps the
    /// first layout from hiding it twice.
    private var hasSetUpChromeForMode = false
    private var hasRegisteredTraitChanges = false
    private var isPaginationScheduled = false
    private var isChromeVisible = true

    /// The reader fades its own controls while the book is the only thing on
    /// screen. See `ReaderBody.onImmersiveChromeChange`.
    var onImmersiveChromeChange: ((Bool) -> Void)?

    var isPaged: Bool { mode == .pages }

    init(
        document: EPUBReaderDocument,
        themeID: ThemeID,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        positionStore: EPUBReadingPositionStore = EPUBReadingPositionStore(),
        modeStore: BookReaderPageModeStore = BookReaderPageModeStore(),
        appearanceStore: BookReaderAppearanceStore = .shared
    ) {
        self.document = document
        self.themeID = themeID
        self.palette = palette
        self.readerPreferences = readerPreferences
        self.selectionRouter = reviewCommentSelectionRouter
        self.sourceContext = reviewCommentSourceContext
        self.positionStore = positionStore
        self.modeStore = modeStore
        self.mode = modeStore.mode
        self.style = .readerDefaults(
            palette: palette,
            textScale: readerPreferences.textScale,
            spacing: readerPreferences.spacing
        )
        self.appearanceStore = appearanceStore
        self.appearance = appearanceStore.appearance

        let saved = positionStore.position(for: document.positionKey)
        let chapter = saved.flatMap { document.book.chapterIndex(forHref: $0.chapterHref) }
            ?? document.book.firstChapterIndex
        self.chapterIndex = chapter
        self.chapterSource = (try? document.book.source(forChapter: chapter)) ?? .unavailable

        super.init(frame: .zero)
        setUpChrome()
        updateContentConstraints()
        installChapterContent()
        restoreStoredPosition(saved)
        observeBackgrounding()
        observeAppearanceChanges()
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasRegisteredTraitChanges else { return }
        hasRegisteredTraitChanges = true
        // A system text-size change re-flows the pages the way Viewing Options
        // does; the fonts come from the style, so the pages are built again.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.rebuildStyle()
            self.schedulePagination()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        updateChapterContentInset()
        setUpChromeForMode()
        // The reader installs its answer after this body exists, and a chunk can
        // rebuild its controls; the body's own state is the authority, so it says
        // again what the reader should do with its chrome.
        onImmersiveChromeChange?(!isChromeVisible)
        updatePagedGeometry()
        applyPendingRestore()
    }

    /// The chapter must stop above the reader's floating control, which is drawn
    /// over this body. The reader pins the body to the page's edges, so the
    /// control's top edge sits `safeAreaInsets.bottom` + the chrome's own
    /// padding + its size above the page's bottom, and the footer already
    /// covers the last `footer.bounds.height` of that distance.
    private func updateChapterContentInset() {
        let footerHeight = footer.bounds.height
        guard footerHeight > 0 else { return }
        let floatingTop = safeAreaInsets.bottom
            + FullScreenFloatingControlChrome.bottomPadding
            + FullScreenFloatingControlChrome.controlSize
        chapterBody?.setBottomContentInset(floatingTop + Self.floatingControlGap - footerHeight)
    }

    // MARK: - Chrome

    private func setUpChrome() {
        backgroundColor = palette.ui.bgDark
        header.backgroundColor = palette.ui.bgDark
        footer.backgroundColor = palette.ui.bgDark
        progressBar.backgroundColor = palette.ui.bgDark

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
        tocButton.accessibilityLabel = String(localized: "Table of Contents")
        tocButton.addTarget(self, action: #selector(showTableOfContents), for: .touchUpInside)

        var appearanceConfiguration = UIButton.Configuration.plain()
        appearanceConfiguration.image = UIImage(systemName: "textformat.size")
        appearanceButton.configuration = appearanceConfiguration
        appearanceButton.tintColor = palette.ui.blue
        appearanceButton.accessibilityIdentifier = "fullScreen.book.aa"
        appearanceButton.accessibilityLabel = String(localized: "Appearance")
        appearanceButton.addTarget(self, action: #selector(presentAppearanceMenu), for: .touchUpInside)

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

        progressLeadingLabel.font = .scaled(.footnote)
        progressLeadingLabel.textColor = palette.ui.fgDim
        progressLeadingLabel.adjustsFontForContentSizeCategory = true
        progressTrailingLabel.font = .scaled(.footnote)
        progressTrailingLabel.textColor = palette.ui.fgDim
        progressTrailingLabel.adjustsFontForContentSizeCategory = true
        progressTrailingLabel.textAlignment = .right
        // One stop, one sentence: the two ends of the line read as one fact.
        progressBar.isAccessibilityElement = true
        progressBar.accessibilityIdentifier = "fullScreen.book.progress"
        progressBar.accessibilityTraits = .staticText

        pagedView.onPageChange = { [weak self] _ in
            self?.updateProgress()
        }
        pagedView.onUserPageTurn = { [weak self] page in
            guard let self, let pages, pages.pageRanges.indices.contains(page) else { return }
            self.positionCharacter = pages.pageRanges[page].location
        }
        pagedView.onChapterTurn = { [weak self] turn in
            self?.turnChapter(turn)
        }
        pagedView.onChromeToggle = { [weak self] in
            self?.toggleChrome()
        }

        for view in [contentHost, header, footer, progressBar, placeholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [titleLabel, tocButton, appearanceButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [previousButton, nextButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        for view in [progressLeadingLabel, progressTrailingLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            progressBar.addSubview(view)
        }
        pagedView.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(pagedView)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerTop,

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor, constant: 8),
            titleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: tocButton.leadingAnchor, constant: -8),

            appearanceButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            appearanceButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            appearanceButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            appearanceButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            tocButton.trailingAnchor.constraint(equalTo: appearanceButton.leadingAnchor, constant: -4),
            tocButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            tocButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            tocButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            header.heightAnchor.constraint(greaterThanOrEqualTo: tocButton.heightAnchor),

            placeholder.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -24),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: Self.progressHeight),

            progressLeadingLabel.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor, constant: 24),
            progressLeadingLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            progressTrailingLabel.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: -24),
            progressTrailingLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor),
            progressLeadingLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: progressTrailingLabel.leadingAnchor,
                constant: -8
            ),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: progressBar.topAnchor),
            footer.topAnchor.constraint(equalTo: previousButton.topAnchor, constant: -6),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            previousButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            previousButton.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -6),
            previousButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // One row, one baseline: the trailing button takes its band from
            // the leading one instead of floating at the footer's top edge.
            nextButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            nextButton.topAnchor.constraint(equalTo: previousButton.topAnchor),
            nextButton.bottomAnchor.constraint(equalTo: previousButton.bottomAnchor),

            pagedView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            pagedView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            pagedView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            pagedView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        updateChrome()
    }

    /// Paged reading fills the body with the page and floats the header over it,
    /// so nothing on the page reserves space for chrome that is not there.
    /// Scrolling keeps the header and the Previous/Next footer in the flow.
    private func updateContentConstraints() {
        let paged = mode == .pages
        NSLayoutConstraint.deactivate(paged ? scrollContentConstraints : pagedContentConstraints)
        NSLayoutConstraint.activate(paged ? pagedContentConstraints : scrollContentConstraints)
        // A floating header shares the top band with the reader's own bar, so it
        // starts below that bar's items; the scrolling header is in the flow and
        // the safe area already accounts for them.
        headerTop.constant = paged ? Self.readerBarClearance : 0
        footer.isHidden = paged
        pagedView.isHidden = paged ? !chapterSource.isAvailable : true
        setNeedsLayout()
    }

    /// The page behind the chapter is book paper, not app chrome: the chapter
    /// header, footer and progress line keep the reading theme.
    private func paintPage() {
        contentHost.backgroundColor = appearance.backgroundColor(in: palette)
    }

    private func observeAppearanceChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceDidChange),
            name: BookReaderAppearanceStore.didChangeNotification,
            object: appearanceStore
        )
    }

    @objc private func appearanceDidChange() {
        let next = appearanceStore.appearance
        guard next != appearance else { return }
        appearance = next
        paintPage()
        // A paged chapter is typeset into page-sized containers, so a new
        // appearance means new pages; the pages land on the same words.
        rebuildStyle()
        if mode == .pages {
            schedulePagination()
        } else {
            chapterBody?.applyBookAppearance(appearance)
        }
    }

    /// The reader's sheet is presented by whichever controller owns this body.
    @objc private func presentAppearanceMenu() {
        guard let owner = hostingViewController else { return }
        let menu = BookReaderAppearanceMenuViewController(store: appearanceStore)
        let presenter = owner.presentedViewController ?? owner
        // A wide page gets a popover at the control that opened it; a phone
        // gets a sheet that hugs its content.
        if presenter.traitCollection.horizontalSizeClass == .regular {
            menu.modalPresentationStyle = .popover
            menu.popoverPresentationController?.sourceView = appearanceButton
            menu.popoverPresentationController?.sourceRect = appearanceButton.bounds
        }
        presenter.present(menu, animated: true)
    }

    private func updateChrome() {
        let chapter = document.book.chapters.indices.contains(chapterIndex)
            ? document.book.chapters[chapterIndex]
            : nil
        titleLabel.text = chapter?.title ?? document.title
        previousButton.isEnabled = chapterIndex > 0
        nextButton.isEnabled = chapterIndex + 1 < document.book.chapters.count
        tocButton.isEnabled = !tableOfContentsRows.isEmpty
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

    private func setUpChromeForMode() {
        guard !hasSetUpChromeForMode else { return }
        hasSetUpChromeForMode = true
        // A paged book is read, not browsed: the page starts alone on screen,
        // and a tap in the middle brings the controls back.
        setChromeVisible(mode == .scrolling, animated: false)
    }

    /// Fades the body's header and asks the reader to fade its own controls.
    /// VoiceOver always keeps them: a control that cannot be found is a reader
    /// that cannot be left.
    private func setChromeVisible(_ visible: Bool, animated: Bool) {
        let hideForReading = !visible && mode == .pages && !UIAccessibility.isVoiceOverRunning
        isChromeVisible = !hideForReading
        // A hidden header must not take the tap that would bring it back.
        header.isUserInteractionEnabled = !hideForReading
        header.accessibilityElementsHidden = hideForReading
        let apply = { [self] in
            header.alpha = hideForReading ? 0 : 1
        }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            header.isHidden = false
            UIView.animate(withDuration: 0.22, animations: apply) { [weak self] _ in
                // A second tap during the fade is the newer answer.
                guard let self else { return }
                self.header.isHidden = !self.isChromeVisible
            }
        } else {
            apply()
            header.isHidden = hideForReading
        }
        onImmersiveChromeChange?(hideForReading)
    }

    @objc private func toggleChrome() {
        guard mode == .pages, !UIAccessibility.isVoiceOverRunning else { return }
        setChromeVisible(!isChromeVisible, animated: true)
    }

    // MARK: - Table of contents

    private lazy var tableOfContentsRows: [BookTableOfContentsViewController.Row] = {
        guard !document.book.toc.isEmpty else {
            return document.book.chapters.map { .init(title: $0.title, level: 0, chapter: $0.index) }
        }
        // A row that names no chapter in the spine (a cover, a note outside the
        // reading order) would be a row that does nothing when tapped.
        return document.book.toc.compactMap { entry in
            guard let chapter = document.book.chapterIndex(forHref: entry.href) else { return nil }
            return .init(title: entry.title, level: entry.level, chapter: chapter)
        }
    }()

    @objc private func showTableOfContents() {
        guard !tableOfContentsRows.isEmpty, let host = hostingViewController else { return }
        let sheet = BookTableOfContentsViewController(
            bookTitle: document.book.title,
            rows: tableOfContentsRows,
            currentChapter: chapterIndex,
            palette: palette
        ) { [weak self] chapter in
            self?.showChapter(at: chapter, restoring: nil)
        }
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        host.present(sheet, animated: true)
    }

    /// The chapter's header and the reader's sheets live in the controller that
    /// installed this body.
    private var hostingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// Switches how the chapter is shown, staying at the same block. The Aa menu
    /// calls this; so does the placeholder action sheet above.
    func setMode(_ next: BookReaderPageMode) {
        guard next != mode else { return }
        let position = currentPosition()
        modeStore.mode = next
        mode = next
        rebuildStyle()
        pages = nil
        paginatedTextSize = .zero
        pendingRestore = position
        updateContentConstraints()
        installChapterContent()
        setChromeVisible(next == .scrolling, animated: false)
        updateProgress()
    }
}

// MARK: - Chapters

extension BookReaderBody {
    private func installChapterContent() {
        chapterBody?.removeFromSuperview()
        chapterBody = nil
        scrollObservation = nil
        pages = nil
        paginatedTextSize = .zero
        positionCharacter = nil
        // The chapter's direction belongs to the whole body, so an unavailable
        // chapter's placeholder and the footer follow it too.
        if document.book.readsRightToLeft || chapterSource.isRightToLeft == true {
            semanticContentAttribute = .forceRightToLeft
        } else {
            semanticContentAttribute = .forceLeftToRight
        }

        let available = chapterSource.isAvailable
        placeholder.isHidden = available
        pagedView.isHidden = !available || mode != .pages
        footer.isHidden = mode == .pages
        guard available else {
            updateProgress()
            return
        }

        if mode == .pages {
            schedulePagination()
        } else {
            installChapterBody()
            observeChapterScrollView()
            pagedView.isHidden = true
        }
        updateProgress()
    }

    private func installChapterBody() {
        chapterBody?.removeFromSuperview()
        chapterBody = nil
        let body = NativeFullScreenMarkdownBody(
            content: chapterSource.markdown,
            themeID: themeID,
            palette: palette,
            reviewCommentSelectionRouter: selectionRouter,
            reviewCommentSourceContext: sourceContext,
            sourceFilePath: document.filePath,
            readerPreferences: readerPreferences,
            bookAppearance: appearance,
            perfSurface: .fullScreenMarkdown,
            mergeAdjacentTextSegments: false
        )
        body.translatesAutoresizingMaskIntoConstraints = false
        body.accessibilityIdentifier = "fullScreen.book.body"
        paintPage()
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
    /// `landingAtEnd` opens the chapter at its last page, for a turn backwards.
    private func showChapter(
        at chapter: Int,
        restoring position: EPUBReadingPosition?,
        landingAtEnd: Bool = false
    ) {
        guard document.book.chapters.indices.contains(chapter), chapter != chapterIndex else { return }
        persistPosition()
        chapterIndex = chapter
        chapterSource = (try? document.book.source(forChapter: chapter)) ?? .unavailable
        pendingRestore = position
        installChapterContent()
        updateChrome()
        if let position, document.book.chapterIndex(forHref: position.chapterHref) == chapter {
            restoreStoredPosition(position)
        } else if mode == .scrolling, let body = chapterBody {
            body.restoreViewport(.top)
        }
        if landingAtEnd, mode == .pages, position == nil {
            pendingRestore = nil
            landOnLastPageOfChapter(scheduleIfNeeded: true)
        }
        updateProgress()
    }

    /// A page turn past the last page of a chapter, or before the first: the
    /// neighbouring chapter, at the edge the turn was heading for.
    private func turnChapter(_ turn: BookPageTurn) {
        switch turn {
        case .forward:
            let next = chapterIndex + 1
            guard next < document.book.chapters.count else {
                pagedView.cancelChapterTurn()
                return
            }
            showChapter(at: next, restoring: nil)
        case .backward:
            let previous = chapterIndex - 1
            guard previous >= 0 else {
                pagedView.cancelChapterTurn()
                return
            }
            showChapter(at: previous, restoring: nil, landingAtEnd: true)
        }
    }

    @objc private func previousChapter() {
        showChapter(at: chapterIndex - 1, restoring: nil)
    }

    @objc private func nextChapter() {
        showChapter(at: chapterIndex + 1, restoring: nil)
    }
}

// MARK: - Pages

extension BookReaderBody {
    /// Content margins inside one page: the reading style's own, plus the room
    /// the progress line needs at the foot of the page.
    private var pageInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: style.pageInsets.top,
            left: style.pageInsets.left,
            bottom: style.pageInsets.bottom + Self.progressHeight,
            right: style.pageInsets.right
        )
    }

    /// Re-paginates when the space the pages are laid out in changed: a rotation,
    /// a split-view resize, or a text-size change that moved the margins.
    private func updatePagedGeometry() {
        guard mode == .pages, chapterSource.isAvailable, contentHost.bounds.width > 0 else { return }
        let size = pagedView.textSize(in: contentHost.bounds.size, insets: pageInsets)
        guard size != paginatedTextSize else { return }
        schedulePagination()
    }

    private func schedulePagination() {
        guard mode == .pages, !isPaginationScheduled else { return }
        isPaginationScheduled = true
        // The page view is loading its own layout; rebuilding its pages inside
        // this pass would invalidate the layout it is running.
        DispatchQueue.main.async { [weak self] in
            self?.isPaginationScheduled = false
            self?.paginate()
        }
    }

    /// Lays the chapter out, landing on the position the body was asked for or,
    /// on a re-pagination, on the page the person was reading.
    private func paginate() {
        guard mode == .pages, chapterSource.isAvailable, contentHost.bounds.width > 0 else { return }
        let insets = pageInsets
        let size = pagedView.textSize(in: contentHost.bounds.size, insets: insets)
        guard size.width > 1, size.height > 1 else { return }
        // The page on screen before this layout, so a re-pagination lands on the
        // same words.
        let visibleStart = pages.map { _ in currentPageStartCharacter }
        let restore = pendingRestore
        paginatedTextSize = size
        pagedView.contentInsets = insets
        let built = BookChapterPaginator.layout(source: chapterSource, style: style, pageSize: size)
        pages = built
        let character = restore.map {
            built.characterOffset(forBlockOrdinal: $0.blockOrdinal, offsetPoints: $0.offsetPoints)
        }
            ?? positionCharacter
            ?? visibleStart
            ?? 0
        pendingRestore = nil
        pagedView.show(pages: built, character: character)
        // A restore sets the position; a re-pagination keeps whatever the person
        // was reading, so only the form of the page changed, not the position.
        if restore != nil {
            positionCharacter = character
        }
        updateProgress()
    }

    /// The character the page on screen starts with.
    private var currentPageStartCharacter: Int {
        guard let pages, pages.pageRanges.indices.contains(pagedView.pageIndex) else { return 0 }
        return pages.pageRanges[pagedView.pageIndex].location
    }

    /// A chapter that opens from the back: its last page, once the pages exist.
    private func landOnLastPageOfChapter(scheduleIfNeeded: Bool) {
        if let pages, pages.pageCount > 0 {
            pagedView.show(page: pages.pageCount - 1, animated: false)
            return
        }
        guard scheduleIfNeeded else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let pages = self.pages, pages.pageCount > 0 else { return }
            self.pagedView.show(page: pages.pageCount - 1, animated: false)
            self.updateProgress()
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard mode == .pages else { return false }
        return pagedView.accessibilityScroll(direction)
    }

    private func rebuildStyle() {
        style = .readerDefaults(
            palette: palette,
            textScale: readerPreferences.textScale,
            spacing: readerPreferences.spacing
        )
    }
}

// MARK: - Position

extension BookReaderBody {
    /// The body's own position, in the chart the store keeps: which block of
    /// this chapter the reading is in, and how far into it. Paged reading
    /// reports the block the page starts in and the characters into it;
    /// scrolling reports the block at the top of the viewport and the points.
    private func currentPosition() -> EPUBReadingPosition? {
        guard document.book.chapters.indices.contains(chapterIndex),
              !isRestoringPosition else { return nil }
        let href = document.book.chapters[chapterIndex].href
        if mode == .pages {
            guard let pages, !pages.isEmpty else { return nil }
            let character = positionCharacter ?? currentPageStartCharacter
            let (ordinal, offset) = pages.storedPosition(forCharacter: character)
            return EPUBReadingPosition(chapterHref: href, blockOrdinal: ordinal, offsetPoints: offset)
        }
        guard let body = chapterBody else { return nil }
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
            chapterHref: href,
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

    /// Hands the stored block to the chapter body once it can place it. In paged
    /// reading the pages themselves consume it, because a page cannot be chosen
    /// before the chapter has a layout.
    private func applyPendingRestore() {
        guard mode == .scrolling,
              let position = pendingRestore,
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

// MARK: - Progress

extension BookReaderBody {
    private func updateProgress() {
        guard mode == .pages else {
            updateScrollProgress()
            return
        }
        guard let pages, !pages.isEmpty, pages.pageRanges.indices.contains(pagedView.pageIndex) else {
            setProgress(leading: "", trailing: "", spoken: nil)
            return
        }
        let page = pagedView.pageIndex + 1
        let leading = String(localized: "Page \(page) of \(pages.pageCount)")
        let words = pages.words(fromCharacter: pages.pageRanges[pagedView.pageIndex].location)
        let minutes = Int((Double(words) / Self.wordsPerMinute).rounded())
        let trailing = minutes < 1
            ? String(localized: "<1 min left in chapter")
            : String(localized: "\(minutes) min left in chapter")
        setProgress(leading: leading, trailing: trailing, spoken: "\(leading), \(trailing)")
    }

    /// Scrolling keeps one chapter in the viewport, so the line answers how far
    /// through the chapter the person is.
    private func updateScrollProgress() {
        guard let scrollView = chapterScrollView(), chapterSource.isAvailable else {
            setProgress(leading: "", trailing: "", spoken: nil)
            return
        }
        let scrollable = scrollView.contentSize.height
            - scrollView.bounds.height
            + scrollView.adjustedContentInset.top
            + scrollView.adjustedContentInset.bottom
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let fraction = scrollable > 1 ? min(max(offset / scrollable, 0), 1) : 0
        let percent = Int((fraction * 100).rounded())
        guard percent != scrollProgressPercent else { return }
        scrollProgressPercent = percent
        let leading = String(localized: "\(percent)% of chapter")
        setProgress(leading: leading, trailing: "", spoken: leading)
    }

    private func setProgress(leading: String, trailing: String, spoken: String?) {
        progressLeadingLabel.text = leading
        progressTrailingLabel.text = trailing
        progressBar.accessibilityLabel = spoken
        progressBar.isHidden = spoken == nil
    }

    private func chapterScrollView() -> UIScrollView? {
        guard let body = chapterBody else { return nil }
        var queue: [UIView] = [body]
        while let view = queue.popLast() {
            if let scrollView = view as? UIScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func observeChapterScrollView() {
        scrollObservation = nil
        scrollProgressPercent = -1
        guard let scrollView = chapterScrollView() else { return }
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateScrollProgress()
            }
        }
    }
}

// MARK: - ReaderBody

extension BookReaderBody: ReaderBody {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        readerPreferences = preferences
        rebuildStyle()
        if mode == .scrolling {
            chapterBody?.applyReaderPreferences(preferences)
            setNeedsLayout()
        } else {
            schedulePagination()
        }
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
