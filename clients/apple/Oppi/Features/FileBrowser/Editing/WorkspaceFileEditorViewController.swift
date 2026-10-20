import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Live edit sessions by identity. Reopening a file while a save is in flight
/// reuses that session, so one file never has two writers with different base
/// tags. Settled sessions are dropped. Background checkpoints every session and
/// keeps the process alive for in-flight writes without blocking the transition.
@MainActor
final class WorkspaceFileEditSessionRegistry {
    static let shared = WorkspaceFileEditSessionRegistry()

    private var sessions: [WorkspaceFileEditIdentity: WorkspaceFileEditSession] = [:]
    private var backgroundObserver: NSObjectProtocol?
    private let backgroundTasks: any AppBackgroundTasks

    init(
        observesBackground: Bool = true,
        backgroundTasks: any AppBackgroundTasks = UIApplicationBackgroundTasks(name: "workspace-file-save")
    ) {
        self.backgroundTasks = backgroundTasks
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
        let saveTask = SaveTask(backgroundTasks)
        saveTask.identifier = backgroundTasks.begin {
            // Out of time: keep each latest draft for the next launch.
            for session in pending { session.checkpoint() }
            saveTask.finish()
        }
        if saveTask.over {
            // The expiration handler already ran inside `begin`.
            saveTask.finish()
            return
        }
        Task { @MainActor in
            for session in pending { await session.waitForInFlightWrite() }
            saveTask.finish()
        }
    }

    /// The background task kept for in-flight writes. Expiration or the
    /// finished writes, whichever comes first, ends it; the other does nothing.
    /// iOS may call the expiration handler before `begin` returns.
    @MainActor
    private final class SaveTask {
        private let backgroundTasks: any AppBackgroundTasks
        var identifier: UIBackgroundTaskIdentifier?
        private(set) var over = false
        private var ended = false

        init(_ backgroundTasks: any AppBackgroundTasks) {
            self.backgroundTasks = backgroundTasks
        }

        func finish() {
            over = true
            guard let identifier, !ended else { return }
            ended = true
            backgroundTasks.end(identifier)
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

/// The workspace code editor: one continuous `CodeEditorTextView` for a
/// workspace text file, with syntax color, a line-number gutter, a status
/// line, a configurable key bar, Mac-style editor shortcuts, and optional Vim
/// keybindings (`CodeEditorPreferences`).
///
/// The text view owns input, selection, marked text, and undo for the whole
/// edit. Every editor command is one `replace` of the text view, so it is one
/// undo step and reaches the session like typing. Theme changes recolor it in
/// place; Preview hides it behind a reader built from the current draft and
/// shows the same instance again. Nothing in this controller replaces the
/// text view or its undo stack, except Use Disk Version, which the user chose
/// explicitly.
final class WorkspaceFileEditorViewController: UIViewController, UITextViewDelegate, CodeEditorTextViewInputHandler, VimBuffer {
    let session: WorkspaceFileEditSession
    let textView = CodeEditorTextView()
    let vim = VimEngine()
    private let statusBar = CodeEditorStatusBar()
    private let keyBar = CodeEditorKeyBar()
    private let preferences: CodeEditorPreferences
    private let isMarkdown: Bool
    private let grammar: CodeEditorHighlightEngine.Grammar
    private let languageName: String
    private let onDone: () -> Void
    private let makePreview: (String) -> UIViewController
    private var highlighter: CodeEditorHighlighter?
    private var previewController: UIViewController?
    private var appliedThemeID: ThemeID
    private var detectedIndentation: CodeIndentation?
    private var appliedKeybindings: CodeEditorKeybindings?
    private var appliedTabWidth: Int?
    private var keyCommandCache: (key: String, commands: [UIKeyCommand])?
    /// Set while this controller moves the selection, so the change is not
    /// reported back to Vim as a tap.
    private var isApplyingSelection = false
    private(set) var isShowingPreview = false
    private var isFinished = false

    init(
        session: WorkspaceFileEditSession,
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
        preferences: CodeEditorPreferences = .shared,
        onDone: @escaping () -> Void = {},
        makePreview: @escaping (String) -> UIViewController
    ) {
        self.session = session
        let path = session.identity.path
        self.isMarkdown = FileType.detect(from: path) == .markdown
        self.grammar = CodeEditorHighlightEngine.grammar(forPath: path)
        self.languageName = switch grammar {
        case .markdown: "Markdown"
        case .treeSitter(let language), .scanner(let language): language.displayName
        case .plain: String(localized: "Plain Text")
        }
        self.preferences = preferences
        self.appliedThemeID = themeID
        self.onDone = onDone
        self.makePreview = makePreview
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private var vimEnabled: Bool { preferences.keybindings == .vim }

    /// Indentation for Tab, Return, `>`, and the status line.
    private var indentation: CodeIndentation {
        preferences.detectsIndentation ? (detectedIndentation ?? preferences.indentation) : preferences.indentation
    }

    private var editorFont: UIFont {
        FontPreferences.scaledCodeFont(baseSize: 13, textStyle: .body)
    }

    private var highlightStyle: CodeEditorHighlighter.Style {
        .make(themeID: appliedThemeID, font: editorFont, tabWidth: indentation.width)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.accessibilityIdentifier = "workspace-file-editor.text"
        textView.font = editorFont
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        // Source text: no smart punctuation, autocorrect, capitalization, or predictions.
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.dataDetectorTypes = []
        textView.isFindInteractionEnabled = true
        textView.text = session.currentText
        textView.delegate = self
        textView.inputHandler = self
        detectedIndentation = CodeIndentation.detect(in: textView.textStorage.mutableString, fallback: preferences.indentation)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.onCommand = { [weak self] prompt, entry in self?.runCommandLine(prompt, entry) }
        statusBar.onCommandEnded = { [weak self] in self?.textView.becomeFirstResponder() }
        statusBar.onGoToLine = { [weak self] in self?.presentGoToLine() }
        keyBar.onKey = { [weak self] key in self?.press(key) }
        keyBar.onHideKeyboard = { [weak self] in self?.textView.resignFirstResponder() }
        vim.buffer = self
        // Device-local: a yank never travels to other devices over Universal Clipboard.
        vim.onYank = { text in
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        }
        textView.onFloatingCursorChange = { [weak self] _ in self?.vimStateDidChange(scrolls: false) }

        view.addSubview(textView)
        view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        highlighter = CodeEditorHighlighter(
            textView: textView,
            grammar: grammar,
            style: highlightStyle,
            isEnabled: preferences.highlightsSyntax
        )
        appliedTabWidth = indentation.width
        applyColors()
        session.attachEditor { [weak textView] in textView?.text ?? "" }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontDidChange),
            name: FontPreferences.didChangeNotification,
            object: nil
        )
        setNeedsUpdateProperties()
    }

    /// Preferences are observable: any change in Settings or the toolbar menu
    /// lands here while the editor is open.
    override func updateProperties() {
        super.updateProperties()
        textView.showsLineNumbers = preferences.showsLineNumbers
        textView.highlightsCurrentLine = preferences.highlightsCurrentLine
        textView.wrapsLines = preferences.wrapsLines
        highlighter?.isEnabled = preferences.highlightsSyntax
        if indentation.width != appliedTabWidth {
            appliedTabWidth = indentation.width
            highlighter?.restyle(highlightStyle)
        }

        let keybindings = preferences.keybindings
        if keybindings != appliedKeybindings {
            appliedKeybindings = keybindings
            keyCommandCache = nil
            if keybindings == .vim {
                vim.reset(to: .normal)
            }
            vimStateDidChange()
        }

        let keys = preferences.keyBarKeys.filter { $0 != .escape || keybindings == .vim }
        keyBar.apply(keys: keys, foreground: UIColor(appliedThemeID.palette.fg), background: UIColor(appliedThemeID.palette.bg))
        let accessory: UIView? = preferences.showsKeyBar ? keyBar : nil
        if textView.inputAccessoryView !== accessory {
            textView.inputAccessoryView = accessory
            if textView.isFirstResponder { textView.reloadInputViews() }
        }
        refreshStatus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Covered or popped: checkpoint and start a save; never wait.
        if !isFinished { session.flush() }
    }

    // MARK: - Text view delegate

    func textViewDidChange(_ textView: UITextView) {
        textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if vimEnabled, !isApplyingSelection {
            vim.selectionDidChange()
            vimStateDidChange(scrolls: false)
        }
        self.textView.selectionDidMove()
        refreshStatus()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        self.textView.selectionDidMove()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        highlighter?.viewportDidChange()
    }

    private func textDidChange() {
        session.noteEdit()
        highlighter?.textDidChange()
        refreshStatus()
    }

    // MARK: - Buffer edits

    /// One undoable replace through the text view. `replace` reports
    /// `textViewDidChange` itself, so the session hears it like typing.
    private func replace(_ range: NSRange, with text: String) {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else { return }
        textView.replace(textRange, withText: text)
    }

    private func select(_ range: NSRange) {
        isApplyingSelection = true
        textView.selectedRange = range
        isApplyingSelection = false
    }

    private func apply(_ edit: CodeTextEdit) {
        isApplyingSelection = true
        replace(edit.range, with: edit.replacement)
        textView.selectedRange = edit.selection
        isApplyingSelection = false
        textView.scrollRangeToVisible(edit.selection)
        if vimEnabled { vim.selectionDidChange() }
    }

    // MARK: - Input

    func codeEditor(_ textView: CodeEditorTextView, handleInsert text: String) -> Bool {
        if vimEnabled, vim.mode != .insert {
            for key in VimKey.keys(for: text) { handleVim(key) }
            return true
        }
        let buffer = textView.textStorage.mutableString
        let selection = textView.selectedRange
        switch text {
        case "\n":
            if isMarkdown, selection.length == 0,
               let edit = MarkdownListContinuation.edit(in: buffer, caret: selection.location) {
                let caret = edit.range.location + (edit.replacement as NSString).length
                apply(CodeTextEdit(range: edit.range, replacement: edit.replacement, selection: NSRange(location: caret, length: 0)))
                return true
            }
            let colonBlocks: Bool = switch grammar {
            case .treeSitter(let language), .scanner(let language): language == .python || language == .yaml
            default: false
            }
            apply(CodeTextEditing.newline(buffer, selection: selection, indentation: indentation, colonOpensBlock: colonBlocks))
            return true
        case "\t":
            apply(CodeTextEditing.insertTab(buffer, selection: selection, indentation: indentation))
            return true
        default:
            guard preferences.closesBrackets, grammar != .plain,
                  let edit = CodeTextEditing.pairedInsertion(buffer, selection: selection, typed: text, pairsQuotes: !isMarkdown) else {
                return false
            }
            apply(edit)
            return true
        }
    }

    func codeEditorHandleDeleteBackward(_ textView: CodeEditorTextView) -> Bool {
        if vimEnabled, vim.mode != .insert {
            handleVim(.backspace)
            return true
        }
        let selection = textView.selectedRange
        guard selection.length == 0 else { return false }
        let buffer = textView.textStorage.mutableString
        if preferences.closesBrackets, grammar != .plain,
           let edit = CodeTextEditing.pairDeletion(buffer, caret: selection.location) {
            apply(edit)
            return true
        }
        if let edit = CodeTextEditing.softTabDeletion(buffer, caret: selection.location, indentation: indentation) {
            apply(edit)
            return true
        }
        return false
    }

    // MARK: - Vim

    private func handleVim(_ key: VimKey) {
        isApplyingSelection = true
        let requests = vim.handle(key)
        isApplyingSelection = false
        perform(requests)
        vimStateDidChange()
    }

    private func runCommandLine(_ prompt: Character, _ entry: String) {
        isApplyingSelection = true
        let requests = vim.runCommandLine(prompt, entry)
        isApplyingSelection = false
        perform(requests)
        vimStateDidChange()
    }

    private func perform(_ requests: [VimHostRequest]) {
        for request in requests {
            switch request {
            case .save:
                session.flush()
            case .quit, .saveAndQuit:
                onDone()
            case .commandLine(let prompt):
                statusBar.beginCommand(prompt)
            case .scrollCaret(let position):
                scrollCaret(to: position)
            }
        }
    }

    private func vimStateDidChange(scrolls: Bool = true) {
        // Normal mode draws its own block; the system caret would sit beside
        // it, except during a space-bar trackpad drag, when only the system's
        // floating caret shows where the cursor goes.
        let block = vimEnabled && vim.mode == .normal
        textView.usesBlockCaret = block
        textView.tintColor = block && !textView.isFloatingCursorActive ? .clear : UIColor(appliedThemeID.palette.blue)
        if keyCommandCache?.key != keyCommandKey { keyCommandCache = nil }
        if scrolls {
            textView.scrollRangeToVisible(textView.selectedRange)
            if vimEnabled, vim.mode.isVisual { textView.revealHorizontally(offset: vim.cursorOffset) }
        }
        refreshStatus()
    }

    private func scrollCaret(to position: VimScrollPosition) {
        guard let caret = textView.position(from: textView.beginningOfDocument, offset: textView.selectedRange.location) else { return }
        let rect = textView.caretRect(for: caret)
        let visible = textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom
        let target: CGFloat = switch position {
        case .top: rect.minY - textView.adjustedContentInset.top
        case .center: rect.midY - visible / 2 - textView.adjustedContentInset.top
        case .bottom: rect.maxY - visible - textView.adjustedContentInset.top
        }
        let maxY = max(-textView.adjustedContentInset.top, textView.contentSize.height - visible - textView.adjustedContentInset.top)
        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: min(max(-textView.adjustedContentInset.top, target), maxY)), animated: false)
    }

    // MARK: VimBuffer

    var vimText: NSString { textView.textStorage.mutableString }
    var vimSelection: NSRange { textView.selectedRange }
    var vimVisibleLineCount: Int { max(1, Int(textView.bounds.height / max(1, editorFont.lineHeight))) }
    var vimIndentation: CodeIndentation { indentation }
    func vimSelect(_ range: NSRange) { select(range) }
    func vimReplace(_ range: NSRange, with text: String) { replace(range, with: text) }

    func vimUndo() -> Bool {
        guard let undoManager = textView.undoManager, undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    func vimRedo() -> Bool {
        guard let undoManager = textView.undoManager, undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    // MARK: - Key commands

    private var keyCommandKey: String {
        "\(vimEnabled)|\(vimEnabled ? vim.mode.label : "")|\(isMarkdown)"
    }

    func codeEditorKeyCommands(_ textView: CodeEditorTextView) -> [UIKeyCommand] {
        let key = keyCommandKey
        if let keyCommandCache, keyCommandCache.key == key { return keyCommandCache.commands }
        let commands = makeKeyCommands()
        keyCommandCache = (key, commands)
        return commands
    }

    private func makeKeyCommands() -> [UIKeyCommand] {
        func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ id: String, hidden: Bool = false) -> UIKeyCommand {
            let command = UIKeyCommand(
                title: title,
                action: #selector(CodeEditorTextView.performEditorKeyCommand(_:)),
                input: input,
                modifierFlags: flags,
                propertyList: id
            )
            command.wantsPriorityOverSystemBehavior = true
            if hidden { command.attributes = .hidden }
            return command
        }
        var commands = [
            command(String(localized: "Save"), "s", .command, "save"),
            command(String(localized: "Go to Line…"), "l", .command, "goToLine"),
            command(String(localized: "Toggle Comment"), "/", .command, "comment"),
            command(String(localized: "Indent"), "]", .command, "indent"),
            command(String(localized: "Outdent"), "[", .command, "outdent"),
            command(String(localized: "Outdent"), "\t", .shift, "outdent", hidden: true),
            command(String(localized: "Move Line Up"), "[", [.command, .alternate], "moveUp"),
            command(String(localized: "Move Line Down"), "]", [.command, .alternate], "moveDown"),
            command(String(localized: "Duplicate Line"), "d", .command, "duplicate"),
            command(String(localized: "Delete Line"), "k", [.command, .shift], "deleteLine"),
            command(String(localized: "Insert Line Below"), "\r", .command, "lineBelow"),
            command(String(localized: "Insert Line Above"), "\r", [.command, .shift], "lineAbove"),
        ]
        if isMarkdown {
            commands += [
                command(String(localized: "Bold"), "b", .command, "bold"),
                command(String(localized: "Italic"), "i", .command, "italic"),
            ]
        }
        guard vimEnabled else {
            commands.append(command(String(localized: "Indent"), "\t", [], "tab", hidden: true))
            return commands
        }
        commands += [
            command(String(localized: "Normal Mode"), UIKeyCommand.inputEscape, [], "vim.escape"),
            command("", "[", .control, "vim.escape", hidden: true),
            command("", "c", .control, "vim.escape", hidden: true),
        ]
        if vim.mode == .insert {
            commands.append(command(String(localized: "Indent"), "\t", [], "tab", hidden: true))
            return commands
        }
        for (input, id) in [
            (UIKeyCommand.inputLeftArrow, "vim.left"), (UIKeyCommand.inputRightArrow, "vim.right"),
            (UIKeyCommand.inputUpArrow, "vim.up"), (UIKeyCommand.inputDownArrow, "vim.down"),
            ("\t", "vim.tab"), ("\r", "vim.enter"),
        ] {
            commands.append(command("", input, [], id, hidden: true))
        }
        for letter in "rdufbnpeyo" {
            commands.append(command("", String(letter), .control, "vim.ctrl.\(letter)", hidden: true))
        }
        return commands
    }

    func codeEditor(_ textView: CodeEditorTextView, perform command: String) {
        let buffer = textView.textStorage.mutableString
        let selection = textView.selectedRange
        switch command {
        case "save": session.flush()
        case "goToLine": presentGoToLine()
        case "comment": toggleComment()
        case "indent": apply(CodeTextEditing.indent(buffer, selection: selection, indentation: indentation))
        case "outdent":
            if let edit = CodeTextEditing.outdent(buffer, selection: selection, indentation: indentation) { apply(edit) }
        case "tab": apply(CodeTextEditing.insertTab(buffer, selection: selection, indentation: indentation))
        case "moveUp":
            if let edit = CodeTextEditing.moveLines(buffer, selection: selection, up: true) { apply(edit) }
        case "moveDown":
            if let edit = CodeTextEditing.moveLines(buffer, selection: selection, up: false) { apply(edit) }
        case "duplicate": apply(CodeTextEditing.duplicateLines(buffer, selection: selection))
        case "deleteLine": apply(CodeTextEditing.deleteLines(buffer, selection: selection))
        case "lineBelow": apply(CodeTextEditing.insertLine(buffer, selection: selection, below: true))
        case "lineAbove": apply(CodeTextEditing.insertLine(buffer, selection: selection, below: false))
        case "bold": apply(CodeTextEditing.toggleWrap(buffer, selection: selection, marker: "**"))
        case "italic": apply(CodeTextEditing.toggleWrap(buffer, selection: selection, marker: "_"))
        case "vim.escape": handleVim(.escape)
        case "vim.left": handleVim(.left)
        case "vim.right": handleVim(.right)
        case "vim.up": handleVim(.up)
        case "vim.down": handleVim(.down)
        case "vim.tab": handleVim(.tab)
        case "vim.enter": handleVim(.enter)
        default:
            if command.hasPrefix("vim.ctrl."), let letter = command.last { handleVim(.ctrl(letter)) }
        }
    }

    private func toggleComment() {
        let buffer = textView.textStorage.mutableString
        let selection = textView.selectedRange
        let edit: CodeTextEdit?
        switch grammar {
        case .markdown, .treeSitter(.html), .scanner(.html), .scanner(.xml):
            edit = CodeTextEditing.toggleBlockComment(buffer, selection: selection, open: "<!--", close: "-->")
        case .treeSitter(let language), .scanner(let language):
            edit = language.lineCommentPrefix.flatMap { CodeTextEditing.toggleLineComment(buffer, selection: selection, prefix: String($0)) }
        case .plain:
            edit = nil
        }
        if let edit { apply(edit) }
    }

    // MARK: - Key bar

    private func press(_ key: CodeEditorBarKey) {
        let modal = vimEnabled && vim.mode != .insert
        switch key {
        case .escape: if vimEnabled { handleVim(.escape) }
        case .tab: textView.insertText("\t")
        case .outdent: codeEditor(textView, perform: "outdent")
        case .comment: toggleComment()
        case .find: textView.findInteraction?.presentFindNavigator(showingReplace: false)
        case .undo: modal ? handleVim(.char("u")) : textView.undoManager?.undo()
        case .redo: modal ? handleVim(.ctrl("r")) : textView.undoManager?.redo()
        case .left: modal ? handleVim(.left) : moveCaret(.left)
        case .right: modal ? handleVim(.right) : moveCaret(.right)
        case .up: modal ? handleVim(.up) : moveCaret(.up)
        case .down: modal ? handleVim(.down) : moveCaret(.down)
        case .lineStart: modal ? handleVim(.char("^")) : moveToLineEdge(end: false)
        case .lineEnd: modal ? handleVim(.char("$")) : moveToLineEdge(end: true)
        case .symbol(let text): textView.insertText(text)
        }
    }

    private func moveCaret(_ direction: UITextLayoutDirection) {
        guard let range = textView.selectedTextRange else { return }
        let origin = direction == .left || direction == .up ? range.start : range.end
        guard let target = textView.position(from: origin, in: direction, offset: 1)
            ?? (range.isEmpty ? nil : origin) else { return }
        textView.selectedTextRange = textView.textRange(from: target, to: target)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    /// Line Start goes to the first non-blank, then to column 0.
    private func moveToLineEdge(end: Bool) {
        let buffer = textView.textStorage.mutableString
        let caret = textView.selectedRange.location
        var lineStart = 0
        var contentsEnd = 0
        buffer.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: caret, length: 0))
        let target: Int
        if end {
            target = contentsEnd
        } else {
            let firstText = NSMaxRange(CodeTextEditing.leadingWhitespace(
                buffer,
                line: NSRange(location: lineStart, length: contentsEnd - lineStart)
            ))
            target = caret == firstText ? lineStart : firstText
        }
        textView.selectedRange = NSRange(location: target, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    // MARK: - Status and Go to Line

    private func refreshStatus() {
        guard isViewLoaded else { return }
        let position = vimEnabled && vim.mode.isVisual
            ? textView.lineAndColumn(at: vim.cursorOffset)
            : textView.caretLineAndColumn
        let indent = indentation.usesTabs ? String(localized: "Tabs") : String(localized: "Spaces: \(indentation.width)")
        statusBar.update(
            mode: vimEnabled ? vim.mode : nil,
            pending: vimEnabled ? vim.pendingDisplay : "",
            message: vimEnabled ? vim.message : nil,
            line: position.line,
            column: position.column,
            detail: "\(indent) · \(languageName)"
        )
    }

    private func presentGoToLine() {
        let lineCount = textView.lineIndex.lineCount
        let alert = UIAlertController(
            title: String(localized: "Go to Line"),
            message: String(localized: "1–\(lineCount)"),
            preferredStyle: .alert
        )
        let currentLine = textView.caretLineAndColumn.line + 1
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = String(currentLine)
            field.accessibilityIdentifier = "workspace-file-editor.go-to-line.field"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.textView.becomeFirstResponder()
        })
        alert.addAction(UIAlertAction(title: String(localized: "Go"), style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text, let number = Int(text) else { return }
            let index = self.textView.lineIndex
            let line = min(max(1, number), index.lineCount) - 1
            self.textView.becomeFirstResponder()
            self.select(NSRange(location: index.starts[line], length: 0))
            if self.vimEnabled { self.vim.selectionDidChange() }
            self.scrollCaret(to: .center)
            self.refreshStatus()
        })
        present(alert, animated: true)
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
        highlighter?.restyle(highlightStyle)
        if vimEnabled { vim.reset(to: .normal) }
        if isShowingPreview { installPreview() }
        refreshStatus()
    }

    func setShowingPreview(_ showing: Bool) {
        guard showing != isShowingPreview, isViewLoaded else { return }
        isShowingPreview = showing
        if showing {
            statusBar.endCommand()
            textView.resignFirstResponder()
            installPreview()
            textView.isHidden = true
            statusBar.isHidden = true
        } else {
            removePreview()
            textView.isHidden = false
            statusBar.isHidden = false
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

    @objc private func fontDidChange() {
        textView.font = editorFont
        highlighter?.restyle(highlightStyle)
    }

    /// Recolor in place. Text view identity, selection, and undo survive.
    private func applyColors() {
        let palette = appliedThemeID.palette
        overrideUserInterfaceStyle = appliedThemeID.preferredColorScheme == .light ? .light : .dark
        let background = UIColor(palette.bgDark)
        let foreground = UIColor(palette.fg)
        let dim = UIColor(palette.comment)
        let divider = foreground.withAlphaComponent(0.08)
        view.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.keyboardAppearance = appliedThemeID.preferredColorScheme == .light ? .light : .dark
        textView.chrome = CodeEditorTextView.Chrome(
            gutterBackground: background,
            number: dim.withAlphaComponent(0.7),
            currentNumber: foreground,
            currentLine: foreground.withAlphaComponent(0.05),
            divider: divider,
            blockCursor: UIColor(palette.blue).withAlphaComponent(0.5)
        )
        statusBar.applyColors(
            background: UIColor(palette.bg),
            foreground: foreground,
            dim: dim,
            accent: UIColor(palette.blue),
            divider: divider
        )
        keyBar.apply(
            keys: preferences.keyBarKeys.filter { $0 != .escape || vimEnabled },
            foreground: foreground,
            background: UIColor(palette.bg)
        )
        highlighter?.restyle(highlightStyle)
        vimStateDidChange(scrolls: false)
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
    /// Vim `:q` and `:wq`, the same as tapping Done.
    let onDone: () -> Void
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
            onDone: onDone,
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
                if fence == backtick || fence == tilde,
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
