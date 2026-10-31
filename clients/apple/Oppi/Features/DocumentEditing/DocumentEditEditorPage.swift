import UIKit

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
    /// The Agent prompt's append/replace mode, when this document has one.
    private let instructionMode: AgentInstructionMode?
    private let onInstructionModeChange: @MainActor (AgentInstructionMode) -> Void
    private let checkoutLabel = UILabel()
    /// Made in `viewDidLoad`, where the change can reach the owner.
    private(set) var modeControl: UISegmentedControl?
    private let modeLabel = UILabel()
    /// The banner's two controls are the page's own sheets.
    private lazy var banner = WorkspaceFileEditBannerView(
        session: session,
        onReview: { [weak self] in self?.presentConflictReview() },
        onUseDisk: { [weak self] in self?.confirmUseDiskVersion() }
    )
    private let noticeLabel = UILabel()
    private var appliedReplacementID: UUID?
    private weak var conflictReview: WorkspaceFileConflictReviewViewController?
    private(set) var isShowingPreview = false

    init(
        session: WorkspaceFileEditSession,
        checkoutSubtitle: String?,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        instructionMode: AgentInstructionMode? = nil,
        onInstructionModeChange: @escaping @MainActor (AgentInstructionMode) -> Void = { _ in },
        onDone: @escaping @MainActor () -> Void,
        onTogglePreview: @escaping @MainActor () -> Void,
        makePreview: @escaping (String) -> UIViewController,
        onUseDisk: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        self.onUseDisk = onUseDisk
        self.instructionMode = instructionMode
        self.onInstructionModeChange = onInstructionModeChange
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

    /// A reader with no editor of its own presents this page in a navigation
    /// stack of its own; then the page puts its bar on its own navigation item.
    /// (Embedded in a viewer, the viewer's bar is the one that shows them.)
    override func updateProperties() {
        super.updateProperties()
        guard navigationController?.topViewController === self else { return }
        let items = barButtons
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

        if let instructionMode {
            let control = Self.makeModeControl(instructionMode) { [weak self] mode in
                self?.onInstructionModeChange(mode)
            }
            modeControl = control
            modeLabel.text = String(localized: "Pi's system prompt")
            modeLabel.font = .preferredFont(forTextStyle: .caption1)
            modeLabel.adjustsFontForContentSizeCategory = true
            modeLabel.numberOfLines = 0
            let row = UIStackView(arrangedSubviews: [modeLabel, control])
            row.axis = .vertical
            row.spacing = 4
            header.addArrangedSubview(Self.padded(row, horizontal: 12, vertical: 4))
        }

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
        checkoutLabel.textColor = UIColor(palette.comment)
        checkoutLabel.superview?.isHidden = (checkoutSubtitle ?? "").isEmpty
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

    /// Append or replace: which half of Pi's system prompt this text is. Short
    /// titles for the control; the segments speak the full choice.
    private static func makeModeControl(
        _ mode: AgentInstructionMode,
        onChange: @escaping @MainActor (AgentInstructionMode) -> Void
    ) -> UISegmentedControl {
        let control = UISegmentedControl(items: [
            String(localized: "Append"),
            String(localized: "Replace"),
        ])
        control.selectedSegmentIndex = mode == .append ? 0 : 1
        control.accessibilityIdentifier = "agentPromptEditor.mode"
        control.accessibilityLabel = String(localized: "Prompt Mode")
        control.accessibilityValue = modeTitle(mode)
        control.addAction(
            UIAction { [weak control] _ in
                guard let control else { return }
                let chosen: AgentInstructionMode = control.selectedSegmentIndex == 1 ? .replace : .append
                control.accessibilityValue = modeTitle(chosen)
                onChange(chosen)
            },
            for: .valueChanged
        )
        return control
    }

    private static func modeTitle(_ mode: AgentInstructionMode) -> String {
        switch mode {
        case .append: String(localized: "Append to Pi's prompt")
        case .replace: String(localized: "Replace Pi's prompt")
        }
    }
}
