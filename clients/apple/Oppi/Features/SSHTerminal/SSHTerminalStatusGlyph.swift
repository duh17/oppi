import GhosttyVt
import UIKit

/// One program-status symbol for the terminal toolbar, the blocked card,
/// Herdr rows, and the status list.
///
/// The toolbar copy is a button that opens the record list. Settle timing for a
/// just-finished root lives here, so the timer does not invalidate the terminal
/// screen or resize the grid.
final class SSHTerminalStatusMarkView: UIView {
    enum Style {
        /// Navigation bar: entry effects, and variable colour while working.
        case toolbar
        /// Herdr agent rows: variable colour while working, nothing else.
        case row
        /// Blocked card: a periodic wiggle for attention.
        case banner
        /// Status list rows: still.
        case detail
    }

    let style: Style
    private let imageView = UIImageView()
    private var hold: SSHTerminalStatusHold?
    private var holdTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var headline: SessionStatusKind = .idle
    private var shown: SessionStatusKind = .idle
    private var checkDrawn = false
    private var reduceMotion = false
    private var lastRoot: SSHTerminalStatusHold.Root?
    private var themeID: ThemeID?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: style == .toolbar ? 44 : 20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: style == .toolbar ? 44 : 20),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        status: SessionStatusKind,
        themeID: ThemeID,
        reduceMotion: Bool,
        root: SSHTerminalStatusHold.Root? = nil
    ) {
        self.reduceMotion = reduceMotion
        self.themeID = themeID
        headline = status
        let nextHold = SSHTerminalStatusHold.next(
            hold, from: lastRoot, to: root, headline: status
        )
        lastRoot = root
        if nextHold != hold {
            hold = nextHold
            holdTask?.cancel()
            if let hold {
                holdTask = Task { [weak self] in
                    try? await Task.sleep(for: hold.duration)
                    guard !Task.isCancelled else { return }
                    self?.hold = nil
                    self?.render()
                }
            }
        }
        render()
    }

    private func render() {
        guard let themeID else { return }
        let next = hold?.kind ?? headline
        let previous = shown
        shown = next
        if previous != next { noteEntry(of: next) }

        let drawsCheck = style == .toolbar && shown == .done && !reduceMotion
        imageView.tintColor = UIColor(shown.tint(themeID.appTheme))
        let scale: UIImage.SymbolScale = shown == .idle && style == .toolbar ? .small : .medium
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body, scale: scale)
        imageView.removeAllSymbolEffects()

        if drawsCheck {
            imageView.image = UIImage(systemName: SessionStatusKind.done.terminalSymbol)
            imageView.addSymbolEffect(.drawOn, options: .nonRepeating, animated: !checkDrawn)
            checkTask?.cancel()
            if !checkDrawn {
                checkTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(60))
                    guard !Task.isCancelled else { return }
                    self?.checkDrawn = true
                    self?.imageView.addSymbolEffect(.drawOn, options: .nonRepeating, animated: false)
                }
            }
        } else {
            checkDrawn = false
            checkTask?.cancel()
            imageView.image = UIImage(systemName: shown.terminalSymbol)
            if shown == .working && !reduceMotion && (style == .toolbar || style == .row) {
                imageView.addSymbolEffect(.variableColor.iterative, options: .repeating, animated: true)
            }
            if style == .banner && !reduceMotion {
                imageView.addSymbolEffect(.wiggle, options: .repeat(.periodic(delay: 3)), animated: true)
            }
        }
    }

    private func noteEntry(of kind: SessionStatusKind) {
        guard style == .toolbar, !reduceMotion else { return }
        if kind.isBlocked {
            imageView.addSymbolEffect(.bounce, options: .nonRepeating, animated: true)
        }
        if kind == .error {
            imageView.addSymbolEffect(.wiggle, options: .nonRepeating, animated: true)
        }
    }
}

/// Toolbar control: 44 pt hit target, system bar-item press, opens the list.
final class SSHTerminalStatusGlyphButton: UIButton {
    let mark = SSHTerminalStatusMarkView(style: .toolbar)
    var onOpen: () -> Void = {}
    let glyphFrame = SSHTerminalGlyphFrame()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(mark)
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.isUserInteractionEnabled = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            mark.centerXAnchor.constraint(equalTo: centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addAction(UIAction { [weak self] _ in self?.onOpen() }, for: .touchUpInside)
        accessibilityIdentifier = "sshTerminal.programStatus"
        accessibilityLabel = "Program status"
        accessibilityHint = "Shows each program's status"
        showsMenuAsPrimaryAction = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyphFrame.rect = convert(bounds, to: nil)
    }

    func apply(
        status: SessionStatusKind,
        summary: String,
        themeID: ThemeID,
        reduceMotion: Bool,
        root: SSHTerminalStatusHold.Root?
    ) {
        mark.apply(status: status, themeID: themeID, reduceMotion: reduceMotion, root: root)
        accessibilityValue = summary.isEmpty ? status.label : "\(status.label), \(summary)"
    }
}

/// A just-finished root, held in its outcome colour for a moment.
///
/// On screen, done and error are seen at once, so the resolved headline is
/// already Idle. The hold is presentation only: it never touches the seen
/// ledger. It lives while the root is still that same done or error report
/// and the headline is still Idle; anything else ends it at once.
struct SSHTerminalStatusHold: Equatable {
    struct Root: Equatable {
        var state: GhosttyProgramStatusState
        var revision: UInt64
    }

    struct Input: Equatable {
        var root: Root?
        var headline: SessionStatusKind
    }

    /// `.done` or `.error`.
    let kind: SessionStatusKind
    /// The root revision that started the hold. A repeat report keeps it.
    let revision: UInt64

    var duration: Duration { kind == .error ? .seconds(3) : .milliseconds(1500) }

    static func next(_ hold: Self?, from old: Root?, to new: Root?, headline: SessionStatusKind) -> Self? {
        guard headline == .idle, let new else { return nil }
        let outcome: SessionStatusKind? = switch new.state {
        case GHOSTTY_PROGRAM_STATUS_STATE_DONE: .done
        case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: .error
        default: nil
        }
        guard let outcome else { return nil }
        if let hold, hold.kind == outcome { return hold }
        let wasRunning = old?.state == GHOSTTY_PROGRAM_STATUS_STATE_WORKING
            || old?.state == GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED
        return wasRunning ? Self(kind: outcome, revision: new.revision) : nil
    }
}

/// The toolbar glyph's frame, for the blocked card to collapse into. A plain
/// class written from layout, so a frame change never refreshes a view.
@MainActor
final class SSHTerminalGlyphFrame {
    var rect: CGRect = .zero
}

/// The text the toolbar glyph keeps off the bar.
final class SSHTerminalStatusDetailController: UIViewController, RouterModalContainer,
    UICollectionViewDelegate {
    var onDismissed: (() -> Void)?

    private let hostLabel: String
    private var rows: [SSHTerminalStatusRow]
    private let themeID: ThemeID
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?

    init(hostLabel: String, rows: [SSHTerminalStatusRow], themeID: ThemeID) {
        self.hostLabel = hostLabel
        self.rows = rows
        self.themeID = themeID
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.headerMode = .supplementary
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(themeID.palette.bg)
        collectionView.backgroundColor = UIColor(themeID.palette.bg)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = UIColor(themeID.palette.bg)
        collectionView.accessibilityIdentifier = "sshTerminal.programStatusDetail"
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = "Program status"
            content.secondaryText = SSHTerminalProgramStatusPresentation.hostCaption(self.hostLabel)
            content.textProperties.color = UIColor(self.themeID.palette.fg)
            content.secondaryTextProperties.color = UIColor(self.themeID.palette.comment)
            content.image = UIImage(systemName: "network")
            content.imageProperties.tintColor = UIColor(self.themeID.palette.comment)
            cell.contentConfiguration = content
        }
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SSHTerminalStatusRow> {
            [weak self] cell, _, row in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.title
            content.secondaryText = [row.message, row.status.label].filter { !$0.isEmpty }.joined(separator: "\n")
            content.textProperties.color = UIColor(self.themeID.palette.fg)
            content.secondaryTextProperties.color = UIColor(row.status.tint(self.themeID.appTheme))
            content.image = UIImage(systemName: row.status.terminalSymbol)
            content.imageProperties.tintColor = UIColor(row.status.tint(self.themeID.appTheme))
            content.directionalLayoutMargins.leading = 16 + CGFloat(row.depth) * 16
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.numberOfLines = 3
            cell.contentConfiguration = content
            cell.accessories = []
            cell.isUserInteractionEnabled = false
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            let row = self.rows.first { $0.id == id }
            guard let row else { return nil }
            return collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource?.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id), toSection: 0)
        dataSource?.apply(snapshot, animatingDifferences: false)
        preferredContentSize = CGSize(width: 320, height: min(360, 72 + CGFloat(rows.count) * 56))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }
}

struct SSHTerminalStatusRow: Identifiable, Equatable, Sendable {
    var id: String
    var status: SessionStatusKind
    var title: String
    var message: String
    var depth: Int
}

extension SSHTerminalProgramStatusPresentation {
    /// Root first, then children. Titles and messages are title-grade.
    @MainActor
    static func detailRows(
        store: SSHTerminalProgramStatusStore,
        isStopped: Bool,
        seenAt: Date?
    ) -> [SSHTerminalStatusRow] {
        var records = store.subtree()
        if let root = store.root { records.insert(root, at: 0) }
        return records.compactMap { record in
            guard let status = status(of: record, isStopped: isStopped, seenAt: seenAt) else { return nil }
            let title = remoteText(message: "", title: record.title)
            let app = SSHTerminalDisplayText.sanitized(record.app, limit: SSHTerminalDisplayText.titleLimit)
            let name = title.isEmpty ? (app.isEmpty ? "Program" : app) : title
            return SSHTerminalStatusRow(
                id: record.id.isEmpty ? "root" : record.id,
                status: status,
                title: name,
                message: SSHTerminalDisplayText.sanitized(record.message, limit: SSHTerminalDisplayText.titleLimit),
                depth: record.id.isEmpty ? 0 : record.id.split(separator: "/").count
            )
        }
    }
}
