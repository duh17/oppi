import UIKit

/// Which way a page turn leaves the chapter it is in.
enum BookPageTurn: Equatable {
    case forward
    case backward
}

/// What a tap on a page does, by the third of the page it landed in.
enum BookPageTapZone: Equatable {
    case previousPage
    case nextPage
    case chrome
}

/// A chapter's pages laid side by side, one screen each: swipes and edge taps
/// turn a page, and a turn past either end asks the reader for the next or the
/// previous chapter.
///
/// The view keeps no chapter knowledge of its own: it is handed a chapter's
/// pages and the character to show, and it answers a page change and a chapter
/// turn. The body owns which chapter that is.
@MainActor
final class BookPagedView: UIView {
    /// A drag past a page edge counts as a chapter turn. Paging lets the content
    /// bounce this far before it settles.
    private static let chapterTurnOverscroll: CGFloat = 20

    private let flowLayout = UICollectionViewFlowLayout()
    private let collectionView: UICollectionView
    private(set) var pages = BookChapterPages(
        text: NSAttributedString(),
        pageRanges: [NSRange(location: 0, length: 0)],
        blockStarts: [],
        pageSize: .zero
    )
    /// Where the page's own text sits inside the view. Pages are laid out at
    /// `textSize(in:insets:)`, so this must be the insets pagination used.
    var contentInsets: UIEdgeInsets = .zero {
        didSet {
            guard contentInsets != oldValue else { return }
            flowLayout.invalidateLayout()
            collectionView.reloadData()
        }
    }
    private(set) var pageIndex = 0
    /// True while a chapter turn is being carried out, so one drag across an
    /// edge cannot ask twice.
    private var isTurningChapter = false
    /// True between a drag's start and its deceleration. Only a settle that
    /// follows the person's own drag turns a page: the offsets a programmatic
    /// turn, a re-pagination, or a chapter change pass through are the view's,
    /// and reading them back would move the page out from under the person.
    private var isDragging = false

    /// The page on screen changed, by a turn or by a new chapter's first page.
    var onPageChange: ((Int) -> Void)?
    /// The person turned the page themselves: a tap, a swipe, or a VoiceOver
    /// scroll. A page the view moved to on its own is not the person's position.
    var onUserPageTurn: ((Int) -> Void)?
    /// The person turned past the chapter's first or last page.
    var onChapterTurn: ((BookPageTurn) -> Void)?
    /// The person asked the page — by VoiceOver activation, a switch, or a
    /// keyboard — for the chrome it shows and hides.
    func activateChromeToggle() {
        onChromeToggle?()
    }

    /// A tap in the middle third, which shows or hides the chrome.
    var onChromeToggle: (() -> Void)?

    override init(frame: CGRect) {
        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = .zero
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        super.init(frame: frame)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(BookPagedCell.self, forCellWithReuseIdentifier: BookPagedCell.reuseIdentifier)
        // Pages always advance the same way on screen. A right-to-left book's
        // text still runs right to left; its pages turning the other way round
        // is a later slice.
        semanticContentAttribute = .forceLeftToRight
        accessibilityIdentifier = "fullScreen.book.pages"
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        collectionView.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if flowLayout.itemSize != size {
            flowLayout.itemSize = size
            flowLayout.invalidateLayout()
            // The page on screen moved with the size; keep it on screen.
            collectionView.layoutIfNeeded()
            show(page: pageIndex, animated: false)
        }
    }

    /// The text area of one page: the view's size less the page's margins.
    func textSize(in size: CGSize, insets: UIEdgeInsets) -> CGSize {
        CGSize(
            width: max(size.width - insets.left - insets.right, 1),
            height: max(size.height - insets.top - insets.bottom, 1)
        )
    }

    // MARK: - Pages

    /// Shows `pages`, landing on the page that contains `character`.
    func show(pages: BookChapterPages, character: Int) {
        self.pages = pages
        isTurningChapter = false
        isDragging = false
        pageIndex = pages.pageIndex(containingCharacter: character)
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        show(page: pageIndex, animated: false)
    }

    func show(page: Int, animated: Bool) {
        guard !pages.pageRanges.isEmpty else { return }
        let clamped = min(max(page, 0), pages.pageCount - 1)
        pageIndex = clamped
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        collectionView.setContentOffset(CGPoint(x: CGFloat(clamped) * width, y: 0), animated: animated)
        onPageChange?(clamped)
    }

    /// The attributed text of one page, without the whitespace the previous page
    /// already ended on.
    func text(forPage index: Int) -> NSAttributedString {
        pages.pageText(at: index)
    }

    // MARK: - Turns

    /// The leading and trailing thirds of a page turn it; the middle third is
    /// the page itself, which shows or hides the chrome.
    static func tapZone(atX x: CGFloat, width: CGFloat, isRightToLeft: Bool) -> BookPageTapZone {
        guard width > 0 else { return .chrome }
        if x < width / 3 {
            return isRightToLeft ? .nextPage : .previousPage
        }
        if x > width - width / 3 {
            return isRightToLeft ? .previousPage : .nextPage
        }
        return .chrome
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let zone = Self.tapZone(
            atX: gesture.location(in: self).x,
            width: bounds.width,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        switch zone {
        case .previousPage: step(.backward)
        case .nextPage: step(.forward)
        case .chrome: onChromeToggle?()
        }
    }

    private func step(_ turn: BookPageTurn) {
        switch (turn, pageIndex) {
        case (.forward, _) where pageIndex + 1 < pages.pageCount:
            show(page: pageIndex + 1, animated: true)
            onUserPageTurn?(pageIndex)
        case (.backward, _) where pageIndex > 0:
            show(page: pageIndex - 1, animated: true)
            onUserPageTurn?(pageIndex)
        default:
            isTurningChapter = true
            onChapterTurn?(turn)
        }
    }

    private func requestChapterTurn(_ turn: BookPageTurn) {
        guard !isTurningChapter else { return }
        isTurningChapter = true
        onChapterTurn?(turn)
    }

    /// The turn a chapter change could not carry out: there is no chapter that
    /// way, so the page settles back where it was.
    func cancelChapterTurn() {
        isTurningChapter = false
        show(page: pageIndex, animated: true)
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let forward: Bool
        switch direction {
        case .left, .next: forward = !isRightToLeft
        case .right, .previous: forward = isRightToLeft
        case .up, .down: return false
        @unknown default: return false
        }
        let before = pageIndex
        step(forward ? .forward : .backward)
        if pageIndex != before {
            UIAccessibility.post(notification: .pageScrolled, argument: nil)
        }
        return true
    }
}

// MARK: - Collection view

extension BookPagedView: UICollectionViewDataSource, UICollectionViewDelegate, UIScrollViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pages.pageCount
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookPagedCell.reuseIdentifier,
            for: indexPath
        )
        if let page = cell as? BookPagedCell {
            page.pages = self
            page.show(
                text(forPage: indexPath.item),
                label: pages.pageLabel(at: indexPath.item),
                insets: contentInsets,
                contentHeight: pages.contentHeight(at: indexPath.item)
            )
        }
        return cell
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let byPerson = isDragging
        isDragging = false
        guard byPerson else { return }
        settlePage()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        // The view's own turn already set the page; only its offset moved.
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isDragging = true
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        isDragging = false
        settlePage()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only the person's own drag carries the content past a page edge; a
        // re-pagination can leave a stale offset for a moment, and that is not a
        // turn to the next chapter.
        guard isDragging, !isTurningChapter, scrollView.bounds.width > 1 else { return }
        let width = scrollView.bounds.width
        let lastPageOffset = CGFloat(max(pages.pageCount - 1, 0)) * width
        if scrollView.contentOffset.x < -Self.chapterTurnOverscroll {
            requestChapterTurn(scrollView.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forward : .backward)
        } else if scrollView.contentOffset.x > lastPageOffset + Self.chapterTurnOverscroll {
            requestChapterTurn(scrollView.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .backward : .forward)
        }
    }

    /// The page a drag came to rest on.
    private func settlePage() {
        let width = collectionView.bounds.width
        guard width > 0 else { return }
        let page = min(max(Int((collectionView.contentOffset.x / width).rounded()), 0), pages.pageCount - 1)
        guard page != pageIndex else { return }
        pageIndex = page
        onUserPageTurn?(page)
        onPageChange?(page)
    }
}

// MARK: - One page

/// One page: the slice of the chapter that fits this page's text area, drawn by
/// a text view that runs a few lines past the page and is clipped there, so the
/// page's last line is justified like the ones above it.
@MainActor
private final class BookPagedCell: UICollectionViewCell {
    static let reuseIdentifier = "BookPagedCell"
    /// How far the text runs past the page before the clip stops it: enough
    /// lines that the page's last line is a mid-paragraph line, which is the only
    /// kind TextKit justifies.
    private static let pageSlack: CGFloat = 120

    private let textView = UITextView(usingTextLayoutManager: false)
    /// The page's text area: the window the page's own lines are read through.
    /// The text continues below it, laid out but clipped, so the last line the
    /// person sees is set like the ones above it.
    private let pageClip = UIView()
    /// The clip's height: the page's own text, so the paragraph it continues
    /// draws nothing in the gap under its last line.
    private lazy var clipHeight = pageClip.heightAnchor.constraint(equalToConstant: 0)
    /// The page view that owns the pages, so a VoiceOver swipe on the page it is
    /// reading turns it there and not in the collection view's own scrolling.
    weak var pages: BookPagedView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "fullScreen.book.page"
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = false
        textView.isUserInteractionEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.adjustsFontForContentSizeCategory = true
        textView.accessibilityElementsHidden = true
        pageClip.translatesAutoresizingMaskIntoConstraints = false
        pageClip.clipsToBounds = true
        pageClip.isUserInteractionEnabled = false
        contentView.addSubview(pageClip)
        pageClip.addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        pages?.accessibilityScroll(direction) ?? false
    }

    /// The page the person is reading is one stop, and activating it does what a
    /// tap in the middle of the page does: the chrome comes back, or goes away.
    override func accessibilityActivate() -> Bool {
        guard let pages else { return false }
        pages.activateChromeToggle()
        return true
    }

    func show(
        _ text: NSAttributedString,
        label: String,
        insets: UIEdgeInsets,
        contentHeight: CGFloat?
    ) {
        textView.attributedText = text
        textView.textContainerInset = .zero
        textView.contentInset = .zero
        let constraints = contentView.constraints.filter {
            $0.firstItem === pageClip || $0.secondItem === pageClip
        }
        if constraints.isEmpty || appliedInsets != insets {
            NSLayoutConstraint.deactivate(constraints)
            NSLayoutConstraint.activate([
                pageClip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
                pageClip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
                pageClip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
                clipHeight,
                pageClip.bottomAnchor.constraint(
                    lessThanOrEqualTo: contentView.bottomAnchor,
                    constant: -insets.bottom
                ),
                textView.topAnchor.constraint(equalTo: pageClip.topAnchor),
                textView.leadingAnchor.constraint(equalTo: pageClip.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: pageClip.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: pageClip.bottomAnchor, constant: Self.pageSlack),
            ])
            appliedInsets = insets
        }
        let area = contentView.bounds.height - insets.top - insets.bottom
        clipHeight.constant = max(min(contentHeight ?? area, area), 1)
        // A page with nothing on it is not a stop: an element with no label says
        // nothing and only stands between the reader and the next control.
        accessibilityLabel = label.isEmpty ? nil : label
        isAccessibilityElement = !label.isEmpty
    }

    private var appliedInsets: UIEdgeInsets?
}
