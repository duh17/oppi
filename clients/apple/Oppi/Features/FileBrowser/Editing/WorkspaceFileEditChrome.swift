import UIKit

/// Spoken save-state words and toolbar glyphs for the editor.
enum WorkspaceFileEditStatusPresentation {
    /// Shape-only mapping. Warning is the triangle, not a tint.
    enum Indicator: Equatable, Sendable {
        case symbol(String)
        case progress
    }

    static func label(for status: WorkspaceFileEditSession.Status) -> String {
        switch status {
        case .saved: String(localized: "Saved")
        case .pending: String(localized: "Edited")
        case .saving: String(localized: "Saving…")
        case .offline: String(localized: "Offline")
        case .verifying: String(localized: "Checking…")
        case .conflict: String(localized: "Conflict")
        case .deleted: String(localized: "Deleted")
        case .tooLarge: String(localized: "Too Large")
        case .failed: String(localized: "Not Saved")
        }
    }

    static func indicator(for status: WorkspaceFileEditSession.Status) -> Indicator {
        switch status {
        case .saved: .symbol("checkmark.circle")
        case .pending: .symbol("pencil.circle")
        case .saving, .verifying: .progress
        case .offline: .symbol("wifi.slash")
        case .conflict, .deleted, .tooLarge, .failed: .symbol("exclamationmark.triangle")
        }
    }

    /// Banner lines. "Kept on this device" is claimed only while the last
    /// protected-draft write succeeded.
    static func bannerLines(
        status: WorkspaceFileEditSession.Status,
        maxBytes: Int,
        draftPersistenceError: String?,
        draftNotice: String?,
        recovered: Bool
    ) -> [String] {
        let kept = draftPersistenceError == nil
            ? " " + String(localized: "Your edits are kept on this device.")
            : ""
        var lines: [String] = []
        switch status {
        case .conflict:
            lines.append(String(localized: "This file changed on the server. Autosave is paused.") + kept)
        case .deleted:
            lines.append(String(localized: "This file is gone from the server and will not be recreated.") + kept)
        case .tooLarge:
            lines.append(String(localized: "Too large to save. The limit is \(SessionFormatting.byteCount(maxBytes)).") + kept)
        case .failed(let message):
            lines.append(String(localized: "Not saved: \(message)") + kept)
        case .offline:
            lines.append(String(localized: "Can't reach the server. Saving will retry.") + kept)
        case .pending where recovered && draftPersistenceError == nil:
            lines.append(String(localized: "Recovered unsaved edits."))
        case .saved, .pending, .saving, .verifying:
            break
        }
        if let draftPersistenceError {
            lines.append(String(
                localized: "Your edits could not be stored on this device (\(draftPersistenceError)). They exist only in this editor until the server saves them."
            ))
        }
        if let draftNotice { lines.append(draftNotice) }
        return lines
    }

    static func offersConflictActions(_ status: WorkspaceFileEditSession.Status) -> Bool {
        switch status {
        case .conflict, .deleted, .failed: true
        default: false
        }
    }
}

/// The editor's status banner: what went wrong with the save and, for a
/// conflict or a failure, Review Changes and Use Disk Version. Hidden while
/// there is nothing to say. The owner calls `update(palette:)` from its
/// `updateProperties()`, which reads the session's `@Observable` state.
@MainActor
final class WorkspaceFileEditBannerView: UIView {
    private let session: WorkspaceFileEditSession
    private let label = UILabel()
    private let reviewButton: UIButton
    private let useDiskButton: UIButton
    private let actions: UIStackView

    init(session: WorkspaceFileEditSession, onReview: @escaping () -> Void, onUseDisk: @escaping () -> Void) {
        self.session = session
        let font = UIFont.scaled(.footnote, .semibold)
        reviewButton = WorkspaceFileEditButtons.bordered(String(localized: "Review Changes"), font: font, action: onReview)
        reviewButton.accessibilityIdentifier = "workspace-file-editor.review"
        useDiskButton = WorkspaceFileEditButtons.bordered(String(localized: "Use Disk Version"), font: font, action: onUseDisk)
        useDiskButton.accessibilityIdentifier = "workspace-file-editor.use-disk"
        actions = UIStackView(arrangedSubviews: [reviewButton, useDiskButton])
        super.init(frame: .zero)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityIdentifier = "workspace-file-editor.banner"
        actions.axis = .horizontal
        actions.spacing = 12
        let column = UIStackView(arrangedSubviews: [label, actions])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        update(palette: ThemeRuntimeState.currentPalette())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(palette: ThemePalette) {
        let lines = WorkspaceFileEditStatusPresentation.bannerLines(
            status: session.status,
            maxBytes: session.maxBytes,
            draftPersistenceError: session.draftPersistenceError,
            draftNotice: session.draftNotice,
            recovered: session.recoveredDraft
        )
        isHidden = lines.isEmpty
        label.text = lines.joined(separator: "\n")
        label.textColor = UIColor(palette.fg)
        actions.isHidden = !WorkspaceFileEditStatusPresentation.offersConflictActions(session.status)
        backgroundColor = UIColor(palette.bgHighlight)
        // Hosted SwiftUI buttons took the root's `.themeBlue` tint.
        tintColor = UIColor(palette.blue)
    }
}

/// SwiftUI `.bordered` and `.borderedProminent` capsules in the tint color,
/// for the banner and the conflict review. (SwiftUI drew the Use Disk
/// Version buttons' destructive role in the tint as well.)
@MainActor
enum WorkspaceFileEditButtons {
    static func bordered(
        _ title: String,
        font: UIFont,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> UIButton {
        var configuration: UIButton.Configuration = prominent ? .borderedProminent() : .tinted()
        configuration.cornerStyle = .capsule
        configuration.title = title
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = font
            return outgoing
        }
        // One line, at its full width, as SwiftUI laid it out.
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

/// Disk version against the draft, in a sheet with a bar. Replace uses the
/// tag of exactly this read.
@MainActor
final class WorkspaceFileConflictReviewViewController: UIViewController {
    private enum Phase {
        case loading
        case diff(FullScreenCodeContent)
        case resolved
        case unavailable
    }

    private let session: WorkspaceFileEditSession
    private let filePath: String
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    private var phase: Phase = .loading {
        didSet { mountContent() }
    }
    private var loadTask: Task<Void, Never>?
    private let contentView = UIView()
    private let actionsBar = UIView()
    private var replaceButton: UIButton?
    private weak var reader: FullScreenCodeViewController?

    init(
        session: WorkspaceFileEditSession,
        filePath: String,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        onUseDisk: @escaping () -> Void,
        onReplace: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.filePath = filePath
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Review Changes")
        navigationItem.largeTitleDisplayMode = .never
        let close = UIBarButtonItem(
            title: String(localized: "Keep Editing"),
            image: UIImage(systemName: "pencil"),
            primaryAction: UIAction { _ in onClose() }
        )
        close.accessibilityIdentifier = "workspace-file-review.close"
        navigationItem.leftBarButtonItem = close
        let font = UIFont.scaled(.subheadline, .semibold)
        let useDisk = WorkspaceFileEditButtons.bordered(String(localized: "Use Disk Version"), font: font, action: onUseDisk)
        useDisk.accessibilityIdentifier = "workspace-file-review.use-disk"
        let replace = WorkspaceFileEditButtons.bordered(
            String(localized: "Replace Disk Version"),
            font: font,
            prominent: true,
            action: onReplace
        )
        replace.accessibilityIdentifier = "workspace-file-review.replace"
        replaceButton = replace
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [useDisk, spacer, replace])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        actionsBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: actionsBar.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: actionsBar.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: actionsBar.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: actionsBar.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        for subview in [contentView, actionsBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The actions stay visible above the diff; their fill runs to the
        // bottom edge.
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: actionsBar.topAnchor),
            actionsBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionsBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionsBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        mountContent()
        loadTask = Task { [weak self] in await self?.load() }
    }

    deinit {
        loadTask?.cancel()
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        // The hosted screen's page background, under the bar.
        view.backgroundColor = UIColor(themeID.palette.bg)
        actionsBar.backgroundColor = UIColor(themeID.palette.bgHighlight)
        // Hosted SwiftUI buttons and bar items took the root's `.themeBlue` tint.
        view.tintColor = UIColor(themeID.palette.blue)
        navigationItem.leftBarButtonItem?.tintColor = UIColor(themeID.palette.blue)
        reader?.applyThemeIfNeeded(themeID)
        replaceButton?.isHidden = !(session.status == .conflict && session.reviewedDisk?.etag != nil)
    }

    private func mountContent() {
        guard isViewLoaded else { return }
        for child in children {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        contentView.subviews.forEach { $0.removeFromSuperview() }
        let content: UIView
        switch phase {
        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
            return
        case .diff(let diff):
            let reader = FullScreenCodeViewController(
                content: diff,
                presentationMode: .contentOnly(),
                reviewCommentSelectionContext: reviewCommentSelectionScope?.makeContext()
            )
            addChild(reader)
            pin(reader.view)
            reader.didMove(toParent: self)
            self.reader = reader
            return
        case .resolved:
            content = ReviewPagePlaceholder.show(.empty(
                title: String(localized: "Already Saved"),
                systemImage: "checkmark.circle",
                message: String(localized: "The disk version matches your edits.")
            ))
        case .unavailable:
            content = ReviewPagePlaceholder.unavailable(
                title: String(localized: "Unable to Load"),
                message: String(localized: "The disk version could not be read. Your edits were not changed.")
            )
        }
        pin(content)
    }

    private func pin(_ content: UIView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    private func load() async {
        let outcome = await session.reviewDisk()
        guard !Task.isCancelled else { return }
        let draft = session.currentText
        switch outcome {
        case .snapshot(let snapshot):
            if session.status == .saved {
                phase = .resolved
                return
            }
            let disk = WorkspaceFileTextCodec.decode(snapshot.bytes) ?? ""
            phase = .diff(Self.diffContent(disk: disk, draft: draft, filePath: filePath))
        case .missing:
            phase = .diff(Self.diffContent(disk: "", draft: draft, filePath: filePath))
        case .failed:
            phase = .unavailable
        }
    }

    static func diffContent(disk: String, draft: String, filePath: String) -> FullScreenCodeContent {
        let lines = DiffEngine.compute(old: disk, new: draft)
        return .diff(ToolDiffDocument(
            lines: lines,
            filePath: filePath,
            copyText: DiffEngine.formatUnified(lines)
        ))
    }
}

// MARK: - Bar items (UIKit)

/// Bar items while a file is being edited: save status, Editor Options,
/// Source/Preview, Done. Every item carries a title and a symbol so the Duo
/// vertical rail can show it; the horizontal bar renders them icon-only.
@MainActor
final class WorkspaceFileEditBarItems {
    /// The save status as a symbol: a custom-view item makes a navigation bar lay
    /// out forever, so every bar that shows these items — the viewer's and the
    /// reader's — takes this one. VoiceOver speaks the status word.
    private lazy var statusItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: nil, style: .plain, target: nil, action: nil)
        // One id for the save status in every bar.
        item.accessibilityIdentifier = "workspace-file-editor.status"
        return item
    }()
    private let optionsItem: UIBarButtonItem
    private let previewItem: UIBarButtonItem
    private let doneItem: UIBarButtonItem

    /// The open file's wrap kind, read when the options menu opens: the viewer
    /// keeps one of these across file switches, so it cannot capture the kind.
    private let wrapKind: @MainActor () -> CodeEditorWrapKind

    /// The options menu's rows as they would open now. `preferences` lets a
    /// test use its own.
    func optionsElements(preferences: CodeEditorPreferences = .shared) -> [UIMenuElement] {
        WorkspaceFileEditorOptions.elements(preferences, wrapKind: wrapKind())
    }

    init(wrapKind: @escaping @MainActor () -> CodeEditorWrapKind, onTogglePreview: @escaping @MainActor () -> Void, onDone: @escaping @MainActor () -> Void) {
        self.wrapKind = wrapKind
        optionsItem = UIBarButtonItem(
            title: String(localized: "Editor Options"),
            image: UIImage(systemName: "slider.horizontal.3"),
            menu: WorkspaceFileEditorOptions.menu(wrapKind: wrapKind)
        )
        optionsItem.accessibilityIdentifier = "workspace-file-editor.options"
        previewItem = UIBarButtonItem(primaryAction: UIAction { _ in onTogglePreview() })
        previewItem.accessibilityIdentifier = "workspace-file-editor.preview-toggle"
        doneItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in onDone() })
        doneItem.style = .prominent
        doneItem.accessibilityIdentifier = "workspace-file-editor.done"
        update(status: .saved, isShowingPreview: false)
    }

    /// `rightBarButtonItems` order: Done is the trailing-most.
    var items: [UIBarButtonItem] {
        [doneItem, previewItem, optionsItem, statusItem]
    }

    func update(status: WorkspaceFileEditSession.Status, isShowingPreview: Bool) {
        switch WorkspaceFileEditStatusPresentation.indicator(for: status) {
        case .symbol(let name):
            statusItem.image = UIImage(systemName: name)
        case .progress:
            statusItem.image = UIImage(systemName: "arrow.triangle.2.circlepath")
        }
        statusItem.accessibilityLabel = WorkspaceFileEditStatusPresentation.label(for: status)
        let title = isShowingPreview ? String(localized: "Source") : String(localized: "Preview")
        if previewItem.title != title {
            previewItem.title = title
            previewItem.image = UIImage(systemName: isShowingPreview ? "doc.text" : "eye")
        }
    }
}

/// Quick editor settings while editing; the same values as Settings > Editor.
/// Built each time it opens, so it shows the current values.
@MainActor
enum WorkspaceFileEditorOptions {
    /// `wrapKind` is the open file's, read when the menu opens: Wrap Lines in
    /// the menu changes that kind's setting, as Settings > Editor does.
    static func menu(wrapKind: @escaping @MainActor () -> CodeEditorWrapKind, preferences: CodeEditorPreferences = .shared) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                completion(elements(preferences, wrapKind: wrapKind()))
            },
        ])
    }

    static func elements(_ preferences: CodeEditorPreferences, wrapKind: CodeEditorWrapKind) -> [UIMenuElement] {
        let keybindings = UIMenu(
            title: String(localized: "Keybindings"),
            options: [.displayInline, .singleSelection],
            children: CodeEditorKeybindings.allCases.map { keybindings in
                UIAction(
                    title: keybindings.label,
                    state: preferences.keybindings == keybindings ? .on : .off
                ) { _ in preferences.keybindings = keybindings }
            }
        )
        let toggles: [(String, Bool, (Bool) -> Void)] = [
            (String(localized: "Syntax Highlighting"), preferences.highlightsSyntax, { preferences.highlightsSyntax = $0 }),
            (String(localized: "Line Numbers"), preferences.showsLineNumbers, { preferences.showsLineNumbers = $0 }),
            (String(localized: "Wrap Lines"), preferences.wrapsLines(for: wrapKind), { preferences.setWrapsLines($0, for: wrapKind) }),
            (String(localized: "Keyboard Bar"), preferences.showsKeyBar, { preferences.showsKeyBar = $0 }),
        ]
        let settings = UIMenu(options: .displayInline, children: toggles.map { title, isOn, set in
            UIAction(title: title, state: isOn ? .on : .off) { _ in set(!isOn) }
        })
        return [keybindings, settings]
    }
}
