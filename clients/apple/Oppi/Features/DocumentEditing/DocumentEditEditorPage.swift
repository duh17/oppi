import UIKit

/// Holds the editor's and the bar's Done so they can call this page before `self`
/// exists: their closures are made before `super.init`, which may not capture it.
private final class DocumentEditDoneForwarder {
    var handler: (() -> Void)?
}

/// The open editor under its header: the checkout the file writes to, the
/// conflict banner, a notice line, and `WorkspaceFileEditorViewController`.
///
/// The page owns the editor, its bar items, and the sheets the banner opens
/// (the conflict review and the Use Disk confirmation), because they are all
/// about the editor on screen: it is a view controller and presents them
/// itself. Whoever shows the page only hosts it.
@MainActor
final class DocumentEditEditorPage: UIViewController {
    let editor: WorkspaceFileEditorViewController
    let barItems: WorkspaceFileEditBarItems
    private let session: WorkspaceFileEditSession
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    /// Applies Use Disk Version to the owner's state, whichever sheet asked.
    private let onUseDisk: @MainActor () -> Void
    private let checkoutLabel = UILabel()
    /// The banner's two controls are the page's own sheets.
    private lazy var banner = WorkspaceFileEditBannerView(
        session: session,
        onReview: { [weak self] in self?.presentConflictReview() },
        onUseDisk: { [weak self] in self?.confirmUseDiskVersion() }
    )
    private let noticeLabel = UILabel()
    /// The sentence Done's confirmation adds for one of Pi's own files (Pi reads
    /// it for every new session); nil keeps the confirmation to the name.
    private let saveConfirmationMessage: String?
    /// Auto-Save, read when Done is pressed: on, the editor closes and the
    /// session's own save runs; off, Done asks first.
    private let preferences: CodeEditorPreferences
    private weak var saveConfirmation: UIAlertController?
    /// The owner's Done, once this page has asked whatever it must.
    private let onDone: @MainActor () -> Void
    private var appliedReplacementID: UUID?
    private weak var conflictReview: WorkspaceFileConflictReviewViewController?
    private(set) var isShowingPreview = false

    init(
        session: WorkspaceFileEditSession,
        checkoutSubtitle: String?,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        onDone: @escaping @MainActor () -> Void,
        onTogglePreview: @escaping @MainActor () -> Void,
        makePreview: @escaping (String) -> UIViewController,
        saveConfirmationMessage: String? = nil,
        preferences: CodeEditorPreferences = .shared,
        onUseDisk: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        self.onUseDisk = onUseDisk
        self.saveConfirmationMessage = saveConfirmationMessage
        self.preferences = preferences
        self.onDone = onDone
        // Done asks this page before it closes (Auto-Save off), and the closure
        // that reaches it cannot hold `self` yet.
        let done = DocumentEditDoneForwarder()
        editor = WorkspaceFileEditorViewController(
            session: session,
            preferences: preferences,
            onDone: { done.handler?() },
            makePreview: makePreview
        )
        let grammar: CodeEditorHighlightEngine.Grammar = CodeEditorHighlightEngine.grammar(forPath: session.identity.path)
        barItems = WorkspaceFileEditBarItems(
            wrapKind: { CodeEditorWrapKind(grammar: grammar) },
            onTogglePreview: onTogglePreview,
            onDone: { done.handler?() }
        )
        super.init(nibName: nil, bundle: nil)
        done.handler = { [weak self] in self?.donePressed() }
        checkoutLabel.text = checkoutSubtitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Done, or Vim's `:q`: with Auto-Save off and edits no save covers, ask
    /// first; otherwise just close (the session's own save runs on the way out).
    /// A session that has stopped saving (a conflict, a deleted file, a server
    /// refusal) never asks: its banner and Review are the way out, and a Save
    /// button there would do nothing.
    private func donePressed() {
        guard !preferences.autoSaves, session.hasUnconfirmedChanges, !session.status.stopsAutosave else {
            onDone()
            return
        }
        presentSaveConfirmation()
    }

    /// Save, Discard Changes, or Keep Editing. Save writes exactly the buffer on
    /// screen; the sheet points at the bar Done lives in on iPad.
    private func presentSaveConfirmation() {
        guard saveConfirmation == nil else { return }
        let name = title ?? (session.identity.path as NSString).lastPathComponent
        let confirmation = Confirmation(
            title: session.createsOnFirstSave
                ? String(localized: "Create \(name)?")
                : String(localized: "Save \(name)?"),
            message: saveConfirmationMessage,
            actionTitle: String(localized: "Save"),
            style: .actionSheet,
            isDestructive: false,
            cancelTitle: String(localized: "Keep Editing"),
            prefersAction: true,
            actionIdentifier: "workspaceFileEditor.save",
            additionalActions: [
                .init(
                    title: String(localized: "Discard Changes"),
                    identifier: "workspaceFileEditor.discard",
                    style: .destructive,
                    handler: { [weak self] in
                        self?.session.discardChanges()
                        self?.onDone()
                    }
                )
            ]
        )
        saveConfirmation = confirmation.present(
            from: self,
            anchor: navigationController?.navigationBar,
            onConfirm: { [weak self] in
                self?.session.saveNow()
                self?.onDone()
            },
            onCancel: { [weak self] in self?.saveConfirmation = nil }
        )
    }

    /// `rightBarButtonItems` order: Done is the trailing-most.
    var barButtons: [UIBarButtonItem] {
        barItems.update(
            status: session.status,
            isShowingPreview: isShowingPreview,
            createsFile: session.createsOnFirstSave
        )
        return barItems.items
    }

    /// A reader with no editor of its own presents this page in a navigation
    /// stack of its own; then the page puts its bar on its own navigation item.
    /// (Embedded in a viewer, the viewer's bar is the one that shows them.)
    /// Not from `updateProperties`: writing bar items during an observation pass
    /// can feed back into layout, so this runs on appearance and on a toggle.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installOwnBarItemsIfPresented()
    }

    private func installOwnBarItemsIfPresented() {
        guard navigationController?.topViewController === self else { return }
        // The status is a symbol here: a custom-view item makes a navigation bar
        // lay out forever (the file viewer's own bar keeps the live status view).
        _ = barButtons
        let items = barItems.navigationItems
        if navigationItem.rightBarButtonItems?.elementsEqual(items, by: ===) != true {
            navigationItem.rightBarButtonItems = items
        }
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

    /// Repaints the header for the theme, refreshes the checkout line, and
    /// applies a draft the owner replaced (Use Disk Version) once.
    func apply(
        palette: ThemePalette,
        checkoutSubtitle: String?,
        replacement: WorkspaceFileEditorReplacement?,
        notice: String?
    ) {
        banner.update(palette: palette)
        checkoutLabel.text = checkoutSubtitle
        checkoutLabel.textColor = palette.ui.comment
        checkoutLabel.superview?.isHidden = (checkoutSubtitle ?? "").isEmpty
        noticeLabel.textColor = palette.ui.comment
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
        // The Preview item's own title flips with it.
        installOwnBarItemsIfPresented()
    }

    /// Hands the editor's live buffer to the session and closes the sheet it
    /// opened, before the page goes away.
    func finishEditing() {
        closeConflictReview()
        editor.finishEditing()
    }

    // MARK: The banner's sheets

    func presentConflictReview() {
        guard conflictReview == nil else { return }
        let review = WorkspaceFileConflictReviewViewController(
            session: session,
            filePath: session.identity.path,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            onUseDisk: { [weak self] in
                self?.closeConflictReview()
                self?.onUseDisk()
            },
            onReplace: { [weak self] in
                self?.session.replaceDiskVersion()
                self?.closeConflictReview()
            },
            onClose: { [weak self] in self?.closeConflictReview() }
        )
        conflictReview = review
        Router.present(
            review,
            presentation: .sheet.inNavigation(),
            from: self,
            onDismiss: { [weak self] in self?.conflictReview = nil }
        )
    }

    func confirmUseDiskVersion() {
        Confirmation(
            title: String(localized: "Use Disk Version?"),
            message: String(localized: "Your unsaved edits to this file will be discarded."),
            actionTitle: String(localized: "Discard My Edits"),
            style: .alert,
            actionIdentifier: "workspace-file-editor.use-disk.confirm"
        ).present(from: self, anchor: nil) { [weak self] in self?.onUseDisk() }
    }

    private func closeConflictReview() {
        guard let conflictReview else { return }
        self.conflictReview = nil
        if conflictReview.presentingViewController != nil {
            Router.finish(conflictReview)
        }
    }

    private static func padded(_ content: UIView, horizontal: CGFloat, vertical: CGFloat) -> UIView {
        let container = UIView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
        ])
        return container
    }
}
