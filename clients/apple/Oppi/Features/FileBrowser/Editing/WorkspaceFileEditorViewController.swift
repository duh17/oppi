import SwiftUI
import UIKit

/// Live edit sessions by identity. Reopening a file while a save is in flight
/// reuses that session, so one file never has two writers with different base
/// tags. Settled sessions are dropped. Background checkpoints every session and
/// keeps the process alive for in-flight writes without blocking the transition.
@MainActor
final class WorkspaceFileEditSessionRegistry {
    static let shared = WorkspaceFileEditSessionRegistry()

    private var sessions: [WorkspaceFileEditIdentity: WorkspaceFileEditSession] = [:]
    private var backgroundObserver: NSObjectProtocol?

    init(observesBackground: Bool = true) {
        guard observesBackground else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushAllForBackground()
            }
        }
    }

    func session(for identity: WorkspaceFileEditIdentity) -> WorkspaceFileEditSession? {
        sessions[identity]
    }

    func register(_ session: WorkspaceFileEditSession) {
        sessions[session.identity] = session
        session.onSettled = { [weak self] settled in
            guard let self, self.sessions[settled.identity] === settled, settled.isSettled else { return }
            self.sessions[settled.identity] = nil
        }
    }

    func flushAllForBackground() {
        let pending = sessions.values.filter { $0.hasUnsavedChanges }
        guard !pending.isEmpty else { return }
        for session in pending { session.flush() }
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "workspace-file-save") {
            UIApplication.shared.endBackgroundTask(taskID)
        }
        Task { @MainActor in
            for session in pending { await session.waitForInFlightWrite() }
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
}

/// Open-time recovery when the file itself is gone.
@MainActor
enum WorkspaceFileEditRecovery {
    /// A 404 on open: move a live session with unsaved edits into the
    /// non-writing deleted state, or reopen a kept draft in that state. An
    /// unreadable draft is left in place untouched. Nil means there is nothing
    /// to recover.
    static func sessionForMissingFile(
        identity: WorkspaceFileEditIdentity,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        registry: WorkspaceFileEditSessionRegistry = .shared,
        draftStore: WorkspaceFileDraftStore = .shared
    ) -> WorkspaceFileEditSession? {
        if let live = registry.session(for: identity), live.hasUnsavedChanges {
            live.noteFileMissing()
            return live
        }
        guard case .draft(let draft) = draftStore.loadResult(identity),
              let session = WorkspaceFileEditSession(
                  identity: identity,
                  deletedFileDraft: draft,
                  maxBytes: maxBytes,
                  transport: transport,
                  draftStore: draftStore
              ) else { return nil }
        registry.register(session)
        return session
    }
}

/// One continuous `UITextView` for a workspace text file.
///
/// The text view owns input, selection, marked text, and undo for the whole
/// edit. Theme changes recolor it in place; Preview hides it behind a reader
/// built from the current draft and shows the same instance again. Nothing in
/// this controller replaces the text view or its undo stack, except Use Disk
/// Version, which the user chose explicitly.
final class WorkspaceFileEditorViewController: UIViewController, UITextViewDelegate {
    let session: WorkspaceFileEditSession
    let textView = UITextView(usingTextLayoutManager: true)
    private let makePreview: (String) -> UIViewController
    private var previewController: UIViewController?
    private var appliedThemeID: ThemeID
    private(set) var isShowingPreview = false
    private var isFinished = false

    init(
        session: WorkspaceFileEditSession,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        makePreview: @escaping (String) -> UIViewController
    ) {
        self.session = session
        self.appliedThemeID = themeID
        self.makePreview = makePreview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "workspace-file-editor.text"
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 8)
        // Source text: no smart punctuation, autocorrect, or capitalization.
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.dataDetectorTypes = []
        textView.text = session.currentText
        textView.delegate = self
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        applyColors()
        session.attachEditor { [weak textView] in textView?.text ?? "" }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Covered or popped: checkpoint and start a save; never wait.
        if !isFinished { session.flush() }
    }

    func textViewDidChange(_ textView: UITextView) {
        session.noteEdit()
    }

    /// Done, Back, or teardown. Hands the final buffer to the session.
    func finishEditing() {
        guard !isFinished else { return }
        isFinished = true
        if isViewLoaded { textView.resignFirstResponder() }
        session.detachEditor()
    }

    /// Use Disk Version: the only path that replaces the buffer.
    func replaceText(_ text: String) {
        textView.text = text
        textView.undoManager?.removeAllActions()
        if isShowingPreview { installPreview() }
    }

    func setShowingPreview(_ showing: Bool) {
        guard showing != isShowingPreview, isViewLoaded else { return }
        isShowingPreview = showing
        if showing {
            textView.resignFirstResponder()
            installPreview()
            textView.isHidden = true
        } else {
            removePreview()
            textView.isHidden = false
        }
    }

    func applyThemeIfNeeded(_ themeID: ThemeID) {
        guard themeID != appliedThemeID else { return }
        appliedThemeID = themeID
        guard isViewLoaded else { return }
        applyColors()
        if isShowingPreview { installPreview() }
    }

    @objc private func themeDidChange() {
        applyThemeIfNeeded(ThemeRuntimeState.currentThemeID())
    }

    /// Recolor in place. Text view identity, selection, and undo survive.
    private func applyColors() {
        let palette = appliedThemeID.palette
        overrideUserInterfaceStyle = appliedThemeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(palette.bgDark)
        textView.backgroundColor = UIColor(palette.bgDark)
        textView.textColor = UIColor(palette.fg)
        textView.tintColor = UIColor(palette.blue)
        textView.keyboardAppearance = appliedThemeID.preferredColorScheme == .light ? .light : .dark
    }

    private func installPreview() {
        removePreview()
        let preview = makePreview(session.currentText)
        addChild(preview)
        preview.view.translatesAutoresizingMaskIntoConstraints = false
        preview.view.accessibilityIdentifier = "workspace-file-editor.preview"
        view.addSubview(preview.view)
        NSLayoutConstraint.activate([
            preview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            preview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preview.view.topAnchor.constraint(equalTo: view.topAnchor),
            preview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        preview.didMove(toParent: self)
        previewController = preview
    }

    private func removePreview() {
        guard let previewController else { return }
        previewController.willMove(toParent: nil)
        previewController.view.removeFromSuperview()
        previewController.removeFromParent()
        self.previewController = nil
    }
}

/// SwiftUI host. The controller is created once per edit; updates only recolor
/// and toggle preview. Teardown hands the buffer back to the session.
struct WorkspaceFileEditorView: UIViewControllerRepresentable {
    let session: WorkspaceFileEditSession
    let isShowingPreview: Bool
    let replacementText: WorkspaceFileEditorReplacement?
    let makePreview: (String) -> UIViewController

    @Environment(\.themeID) private var themeID

    final class Coordinator {
        var appliedReplacementID: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> WorkspaceFileEditorViewController {
        context.coordinator.appliedReplacementID = replacementText?.id
        return WorkspaceFileEditorViewController(
            session: session,
            themeID: themeID,
            makePreview: makePreview
        )
    }

    func updateUIViewController(_ controller: WorkspaceFileEditorViewController, context: Context) {
        controller.applyThemeIfNeeded(themeID)
        if let replacementText, context.coordinator.appliedReplacementID != replacementText.id {
            context.coordinator.appliedReplacementID = replacementText.id
            controller.replaceText(replacementText.text)
        }
        controller.setShowingPreview(isShowingPreview)
    }

    static func dismantleUIViewController(_ controller: WorkspaceFileEditorViewController, coordinator: Coordinator) {
        controller.finishEditing()
    }
}

/// One-shot buffer replacement request (Use Disk Version).
struct WorkspaceFileEditorReplacement: Equatable {
    let id = UUID()
    let text: String
}
