import UIKit

/// The open editor under its header: the checkout the file writes to, the
/// conflict banner, a notice line, and `WorkspaceFileEditorViewController`.
///
/// The page owns the editor and its bar items, because the editor outlives
/// every reader pass of the file it edits: Preview, Use Disk Version, and the
/// conflict banner are the page's own state, and whoever shows the page only
/// hosts it.
@MainActor
final class DocumentEditEditorPage: UIViewController {
    let editor: WorkspaceFileEditorViewController
    private let session: WorkspaceFileEditSession
    let barItems: WorkspaceFileEditBarItems
    private let checkoutLabel = UILabel()
    private let banner: WorkspaceFileEditBannerView
    private let noticeLabel = UILabel()
    private var appliedReplacementID: UUID?
    private(set) var isShowingPreview = false

    init(
        session: WorkspaceFileEditSession,
        checkoutSubtitle: String?,
        onDone: @escaping @MainActor () -> Void,
        onTogglePreview: @escaping @MainActor () -> Void,
        makePreview: @escaping (String) -> UIViewController,
        onReviewConflict: @escaping @MainActor () -> Void,
        onUseDisk: @escaping @MainActor () -> Void
    ) {
        self.session = session
        editor = WorkspaceFileEditorViewController(
            session: session,
            onDone: onDone,
            makePreview: makePreview
        )
        let grammar: CodeEditorHighlightEngine.Grammar = CodeEditorHighlightEngine.grammar(forPath: session.identity.path)
        barItems = WorkspaceFileEditBarItems(
            wrapKind: { CodeEditorWrapKind(grammar: grammar) },
            onTogglePreview: onTogglePreview,
            onDone: onDone
        )
        banner = WorkspaceFileEditBannerView(
            session: session,
            onReview: onReviewConflict,
            onUseDisk: onUseDisk
        )
        super.init(nibName: nil, bundle: nil)
        checkoutLabel.text = checkoutSubtitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// `rightBarButtonItems` order: Done is the trailing-most.
    var barButtons: [UIBarButtonItem] {
        barItems.update(status: session.status, isShowingPreview: isShowingPreview)
        return barItems.items
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let header = UIStackView()
        header.axis = .vertical
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        checkoutLabel.font = .preferredFont(forTextStyle: .caption1)
        checkoutLabel.lineBreakMode = .byTruncatingMiddle
        checkoutLabel.adjustsFontForContentSizeCategory = true
        checkoutLabel.accessibilityIdentifier = "workspace-file-editor.checkout"
        header.addArrangedSubview(Self.padded(checkoutLabel, horizontal: 12, vertical: 4))

        header.addArrangedSubview(banner)

        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.numberOfLines = 0
        header.addArrangedSubview(Self.padded(noticeLabel, horizontal: 8, vertical: 8))

        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editor.view)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            editor.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        editor.didMove(toParent: self)
    }

    /// Repaints the header for the theme and applies a draft the owner replaced
    /// (Use Disk Version) once.
    func apply(palette: ThemePalette, replacement: WorkspaceFileEditorReplacement?, notice: String?) {
        banner.update(palette: palette)
        checkoutLabel.textColor = UIColor(palette.comment)
        checkoutLabel.superview?.isHidden = (checkoutLabel.text ?? "").isEmpty
        noticeLabel.textColor = UIColor(palette.comment)
        noticeLabel.text = notice
        noticeLabel.superview?.isHidden = notice == nil
        if let replacement, appliedReplacementID != replacement.id {
            appliedReplacementID = replacement.id
            editor.replaceText(replacement.text)
        }
        editor.setShowingPreview(isShowingPreview)
    }

    /// Preview shows the current draft in the reader instead of the text view.
    func togglePreview() {
        isShowingPreview.toggle()
        editor.setShowingPreview(isShowingPreview)
    }

    /// Hands the editor's live buffer to the session before the page goes away.
    func finishEditing() {
        editor.finishEditing()
    }

    private static func padded(_ label: UILabel, horizontal: CGFloat, vertical: CGFloat) -> UIView {
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
        ])
        return container
    }
}
