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
    private let continuesMarkdownLists: Bool
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
        self.continuesMarkdownLists = FileType.detect(from: session.identity.path) == .markdown
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

    /// Markdown Return at a collapsed caret continues the list item as one
    /// undoable replace. IME composition and other files keep the plain newline.
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard continuesMarkdownLists,
              text == "\n",
              range.length == 0,
              textView.markedTextRange == nil,
              let edit = MarkdownListContinuation.edit(in: textView.text as NSString, caret: range.location),
              let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let replaceRange = textView.textRange(from: start, to: end) else { return true }
        textView.replace(replaceRange, withText: edit.replacement)
        return false
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

/// Return in a Markdown list. Offsets are UTF-16, matching `UITextView`.
///
/// - `- item`, `* item`, `+ item` continue with the same marker and spacing.
/// - `3. item` / `3) item` continue as `4.` / `4)`.
/// - Task items (`- [ ]`, `- [x]`, `1. [ ]`) continue as a new unchecked task.
/// - Return on an item with no text removes the marker and ends the list.
/// - The newline matches the line's own ending, so CRLF files stay CRLF.
/// - Lines inside fenced code blocks and a caret inside the marker are ignored.
enum MarkdownListContinuation {
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
    }

    private static let itemPattern = try? NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|([0-9]{1,9})([.)]))([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#
    )

    static func edit(in text: NSString, caret: Int) -> Edit? {
        guard caret >= 0, caret <= text.length, let itemPattern else { return nil }
        var lineStart = 0
        var contentsEnd = 0
        text.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let line = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard caret <= NSMaxRange(line),
              let match = itemPattern.firstMatch(in: text as String, range: line),
              caret >= NSMaxRange(match.range),
              !isInsideFencedCode(text, before: lineStart) else { return nil }

        let itemText = text.substring(with: NSRange(
            location: NSMaxRange(match.range),
            length: NSMaxRange(line) - NSMaxRange(match.range)
        ))
        if itemText.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: end the list on this line.
            return Edit(range: line, replacement: "")
        }

        let indent = text.substring(with: match.range(at: 1))
        let spacing = text.substring(with: match.range(at: 5))
        let marker: String
        if match.range(at: 2).location != NSNotFound {
            marker = text.substring(with: match.range(at: 2))
        } else {
            let digits = text.substring(with: match.range(at: 3))
            guard let number = Int(digits) else { return nil }
            marker = String(number + 1) + text.substring(with: match.range(at: 4))
        }
        let task = match.range(at: 6).location == NSNotFound ? "" : "[ ] "
        return Edit(
            range: NSRange(location: caret, length: 0),
            replacement: lineBreak(in: text, line: line) + indent + marker + spacing + task
        )
    }

    /// The line's own terminator, else the previous line's; LF by default.
    private static func lineBreak(in text: NSString, line: NSRange) -> String {
        let end = NSMaxRange(line)
        if end < text.length, text.character(at: end) == carriageReturn {
            return "\r\n"
        }
        if line.location >= 2, text.character(at: line.location - 2) == carriageReturn {
            return "\r\n"
        }
        return "\n"
    }

    private static let carriageReturn: unichar = 0x0D
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let backtick: unichar = 0x60
    private static let tilde: unichar = 0x7E

    /// An odd number of ``` or ~~~ fence lines above means the caret is in code.
    private static func isInsideFencedCode(_ text: NSString, before lineStart: Int) -> Bool {
        var inside = false
        var location = 0
        while location < lineStart {
            var next = 0
            text.getLineStart(nil, end: &next, contentsEnd: nil, for: NSRange(location: location, length: 0))
            var index = location
            while index < next, text.character(at: index) == space || text.character(at: index) == tab {
                index += 1
            }
            if index + 3 <= next {
                let fence = text.character(at: index)
                if (fence == backtick || fence == tilde),
                   text.character(at: index + 1) == fence,
                   text.character(at: index + 2) == fence {
                    inside.toggle()
                }
            }
            location = next
        }
        return inside
    }
}

/// One-shot buffer replacement request (Use Disk Version).
struct WorkspaceFileEditorReplacement: Equatable {
    let id = UUID()
    let text: String
}
