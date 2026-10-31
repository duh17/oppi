import UIKit

/// One document's edit entry, and the only place that decides what it offers.
///
/// The owner answers the three questions every reader used to answer for
/// itself: can these bytes open our editor (a pencil), is there a session to
/// offer beside it (a "…" holding Edit with Session), and what does the reader
/// show while an editor is open (the tagged read, a recovered draft, the
/// conflict banner). The pencil appears only when the subject resolves to an
/// edit identity, the server advertises editing for it, and the bytes are a
/// tagged UTF-8 text read within the server's limit — or when a session already
/// exists, which is how a draft kept for a deleted file opens again. A screen
/// shows `barItems` and hosts `editorPage`.
///
/// Saves stay with `WorkspaceFileEditSession` and the `WorkspaceFileWriteOutcome`
/// contract; the owner only picks the transport, so a document served by
/// something other than `/files/current` (an Agent's prompt) plugs into the
/// same outcomes.
@MainActor
final class DocumentEditOwner {
    /// The bar the owner's items and its editor page join. The identifier of
    /// the pencil follows the bar it lives in, because both predate the owner.
    enum Placement {
        /// A reader with its own glass bar (`FullScreenCodeViewController`).
        case readerBar
        /// A screen with its own bar: a host file, a tree pane, a review file.
        case screenBar
    }

    /// Reads and writes one document. The live backend is the paired server's
    /// `/files/current`; tests and previews script the answers. `read` answers
    /// with the transport's own outcome, so a missing file and an unreachable
    /// server are the API layer's words, not a second mapping here.
    struct Backend {
        /// Nil when the server does not edit this owner's files.
        var capability: (WorkspaceFileEditIdentity.Owner) async -> ServerInfo.WorkspaceFileEditingCapability?
        var read: (WorkspaceFileEditIdentity) async -> WorkspaceFileReadOutcome
        var transport: WorkspaceFileEditTransport

        static func api(_ api: APIClient) -> Backend {
            Backend(
                // The API client is an actor: the capability is its answer, not ours.
                capability: { await api.fileEditingCapability(for: $0) },
                read: { await api.readFileForEditingOutcome($0) },
                transport: .api(api)
            )
        }
    }

    enum ReadResult: Equatable {
        /// Nothing to edit: the caller reads the document its own way.
        case ownRead
        /// The reader's bytes, and a kept draft that wins over them.
        case bytes(WorkspaceFileDiskSnapshot, draftText: String?)
        /// The file is gone; its kept draft reopens in the editor.
        case deletedDraft(String)
    }

    /// What the screen offers the owner beyond its subject.
    @MainActor
    struct Handlers {
        /// The reader shows this text: Done, or Use Disk Version.
        var didShowText: (String) -> Void = { _ in }
        /// The file is gone and the draft was discarded: reload it.
        var didReload: () -> Void = {}
        /// The reader a Preview shows, built over the editor's draft.
        var makePreview: (String) -> UIViewController = { _ in UIViewController() }
    }

    private(set) var subject: DocumentEditSubject
    /// Shown above the editor: the checkout the file writes to.
    var checkoutSubtitle: String? {
        didSet { if checkoutSubtitle != oldValue { onChange() } }
    }
    let handlers: Handlers
    /// Edit with Session, when the screen offers one.
    let agentAction: DocumentAgentEditAction?

    private let placement: Placement
    private let backendSource: @MainActor () -> Backend?
    /// Construction context for the editor page's conflict sheet.
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    let draftStore: WorkspaceFileDraftStore
    private let registry: WorkspaceFileEditSessionRegistry
    private let onChange: @MainActor () -> Void
    /// Bumped by every `begin`: a read that started for the previous document
    /// must not write this one's state.
    private var generation = 0

    /// The file this document edits, once the subject resolved to one.
    private(set) var identity: WorkspaceFileEditIdentity?
    /// The tagged read the editor starts from. Nil means no pencil, whatever
    /// else is true of the document.
    private(set) var base: WorkspaceFileDiskSnapshot?
    private(set) var maxBytes: Int?
    private(set) var session: WorkspaceFileEditSession?
    private(set) var isEditing = false {
        didSet { if isEditing != oldValue { onChange() } }
    }
    private(set) var notice: String? {
        didSet { if notice != oldValue { onChange() } }
    }
    private(set) var replacement: WorkspaceFileEditorReplacement? {
        didSet { onChange() }
    }
    /// The open editor, made on first use and reused until editing ends.
    private(set) var editorPage: DocumentEditEditorPage?

    private var barKey: BarKey?
    private var cachedBarItems: [UIBarButtonItem] = []

    init(
        subject: DocumentEditSubject,
        placement: Placement,
        agentAction: DocumentAgentEditAction? = nil,
        backend: @escaping @MainActor () -> Backend?,
        reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil,
        draftStore: WorkspaceFileDraftStore = .shared,
        registry: WorkspaceFileEditSessionRegistry = .shared,
        handlers: Handlers = Handlers(),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.subject = subject
        self.placement = placement
        self.agentAction = agentAction
        self.backendSource = backend
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        self.draftStore = draftStore
        self.registry = registry
        self.handlers = handlers
        self.onChange = onChange
    }

    // MARK: The reader

    /// The reader is about to load `subject`. Whatever the previous document
    /// resolved is dropped (and an open editor's buffer handed back first), so a
    /// pencil never outlives the file it was read for; the read that follows
    /// adopts whatever is live or kept.
    func begin(subject: DocumentEditSubject) {
        self.subject = subject
        generation &+= 1
        reset()
    }

    /// The reader's read. Only an editable document has a tagged read, so the
    /// editor's base is exactly the bytes the reader shows.
    func read() async -> ReadResult {
        let generation = generation
        guard let identity = subject.editIdentity,
              subject.fileType?.previewCategory == .text,
              let backend = backendSource() else {
            reset()
            return .ownRead
        }
        // A server that does not edit this owner's files has no tagged read to
        // offer, so the reader loads the file its own way.
        guard let capability = await backend.capability(identity.owner) else {
            guard generation == self.generation else { return .ownRead }
            reset()
            return .ownRead
        }
        guard generation == self.generation else { return .ownRead }
        self.identity = identity
        maxBytes = capability.maxBytes
        switch await backend.read(identity) {
        case .snapshot(let snapshot):
            guard generation == self.generation else { return .ownRead }
            base = Self.editableBase(snapshot, maxBytes: capability.maxBytes)
            return .bytes(
                snapshot,
                draftText: prepareEditing(
                    identity: identity,
                    snapshot: snapshot,
                    maxBytes: capability.maxBytes,
                    backend: backend
                )
            )
        case .missing:
            guard generation == self.generation else { return .ownRead }
            guard let session = WorkspaceFileEditRecovery.sessionForMissingFile(
                identity: identity,
                maxBytes: capability.maxBytes,
                transport: backend.transport,
                registry: registry,
                draftStore: draftStore
            ) else {
                // Nothing kept: the reader reports the miss its own way.
                reset()
                return .ownRead
            }
            adopt(session)
            return .deletedDraft(session.currentText)
        case .failed:
            guard generation == self.generation else { return .ownRead }
            reset()
            return .ownRead
        }
    }

    /// The server offered these bytes for editing: tagged, exact UTF-8, and
    /// within its limit. The same three conditions `WorkspaceFileEditSession`
    /// needs, so the pencil can never open an editor that cannot start.
    private static func editableBase(
        _ snapshot: WorkspaceFileDiskSnapshot,
        maxBytes: Int
    ) -> WorkspaceFileDiskSnapshot? {
        guard snapshot.etag != nil,
              snapshot.bytes.count <= maxBytes,
              WorkspaceFileTextCodec.decode(snapshot.bytes) != nil else { return nil }
        return snapshot
    }

    /// Adopt a live session or recover a stored draft. Returns the text the
    /// reader should show when it differs from disk.
    private func prepareEditing(
        identity: WorkspaceFileEditIdentity,
        snapshot: WorkspaceFileDiskSnapshot,
        maxBytes: Int,
        backend: Backend
    ) -> String? {
        if let live = registry.session(for: identity) {
            session = live
            if live.hasUnsavedChanges, live.status.stopsAutosave || live.recoveredDraft {
                isEditing = true
            }
            return live.hasUnsavedChanges ? live.currentText : nil
        }
        guard base != nil,
              draftStore.loadResult(identity) != .none,
              let recovered = WorkspaceFileEditSession(
                  identity: identity,
                  disk: snapshot,
                  maxBytes: maxBytes,
                  transport: backend.transport,
                  draftStore: draftStore
              ) else { return nil }
        // A recovered draft, or a notice that an unreadable one was moved aside.
        guard recovered.recoveredDraft || recovered.draftNotice != nil else { return nil }
        registry.register(recovered)
        session = recovered
        isEditing = true
        return recovered.currentText
    }

    // MARK: The bar

    /// The document's controls in `rightBarButtonItems` order (the leading
    /// element is trailing-most): the editor's own controls while typing, else
    /// the "…" and the pencil. Empty when this document offers no edit at all.
    var barItems: [UIBarButtonItem] {
        if isEditing { return editorPage?.barButtons ?? [] }
        let key = BarKey(offersEditor: offersEditor, hasAgentAction: agentAction != nil)
        if key != barKey {
            barKey = key
            cachedBarItems = makeBarItems()
        }
        return cachedBarItems
    }

    /// The pencil's rule: a tagged, editable text read, or a session that still
    /// exists — a draft kept for a file that has since been deleted.
    private var offersEditor: Bool {
        maxBytes != nil && (base != nil || session != nil)
    }

    private func makeBarItems() -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = []
        if let more = moreItem() { items.append(more) }
        if offersEditor { items.append(pencilItem()) }
        return items
    }

    private func pencilItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: DocumentEditLabels.edit,
            image: UIImage(systemName: DocumentEditLabels.systemImage),
            primaryAction: UIAction { [weak self] _ in self?.beginEditing() }
        )
        item.accessibilityLabel = DocumentEditLabels.editFile
        item.accessibilityIdentifier = placement == .readerBar
            ? "fullscreen-code.action.workspace-file-edit"
            : "workspace-file-editor.edit"
        return item
    }

    /// The overflow item: same pattern as an Agent's or a schedule's actions
    /// menu, so a reader with only a session to offer still has a control.
    private func moreItem() -> UIBarButtonItem? {
        guard let agentAction else { return nil }
        let edit = UIAction(
            title: DocumentEditLabels.editWithSession,
            image: UIImage(systemName: DocumentEditLabels.editWithSessionImage)
        ) { _ in agentAction.start() }
        edit.accessibilityIdentifier = "controlFile.editInSession"
        let item = UIBarButtonItem(
            image: UIImage(systemName: DocumentEditLabels.moreImage),
            menu: UIMenu(children: [edit])
        )
        item.accessibilityLabel = DocumentEditLabels.more
        item.accessibilityIdentifier = "document.edit.more"
        return item
    }

    private struct BarKey: Equatable {
        var offersEditor = false
        var hasAgentAction = false
    }

    // MARK: Editing

    /// Opens our editor on the displayed bytes, reusing a live session so one
    /// file never has two writers with different base tags.
    func beginEditing() {
        guard let identity, let maxBytes, let backend = backendSource() else { return }
        let session: WorkspaceFileEditSession
        if let live = registry.session(for: identity) {
            session = live
        } else if let existing = self.session, existing.identity == identity {
            // Keeps the newest acknowledged tag after an earlier edit settled.
            session = existing
            registry.register(existing)
        } else if let base,
                  let created = WorkspaceFileEditSession(
                      identity: identity,
                      disk: base,
                      maxBytes: maxBytes,
                      transport: backend.transport,
                      draftStore: draftStore
                  ) {
            session = created
            registry.register(created)
        } else {
            return
        }
        adopt(session)
    }

    /// Done: the reader shows the current draft. The editor teardown
    /// checkpoints and starts the save; the network is not awaited.
    func endEditing() {
        guard let session else {
            isEditing = false
            setNeedsUpdate()
            return
        }
        // Teardown first, so the session holds the final buffer.
        editorPage?.finishEditing()
        let text = session.currentText
        isEditing = false
        editorPage = nil
        handlers.didShowText(text)
        setNeedsUpdate()
    }

    /// Hosts the editor page of an open session; nil when nothing is open.
    /// Each open editor is its own page: finishing one detaches the session
    /// for good, so it is never handed back.
    func makeEditorPage() -> DocumentEditEditorPage? {
        guard isEditing, let session else { return nil }
        if let editorPage { return editorPage }
        let page = DocumentEditEditorPage(
            session: session,
            checkoutSubtitle: checkoutSubtitle,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            onDone: { [weak self] in self?.endEditing() },
            onTogglePreview: { [weak self] in
                self?.editorPage?.togglePreview()
                self?.setNeedsUpdate()
            },
            makePreview: handlers.makePreview,
            onUseDisk: { [weak self] in self?.useDiskVersion() }
        )
        editorPage = page
        return page
    }

    /// Repaints the open editor and applies a replaced draft.
    func updateEditorPage(palette: ThemePalette) {
        guard let editorPage else { return }
        editorPage.apply(
            palette: palette,
            checkoutSubtitle: checkoutSubtitle,
            replacement: replacement,
            notice: notice
        )
    }

    /// The page is going away (the viewer is popped, or shows another file):
    /// the editor hands its buffer to the session first.
    func finishEditing() {
        editorPage?.finishEditing()
        editorPage = nil
    }

    private func adopt(_ session: WorkspaceFileEditSession) {
        self.session = session
        notice = nil
        isEditing = true
        setNeedsUpdate()
    }

    private func useDiskVersion() {
        guard let session else { return }
        Task { [weak self] in
            let outcome = await session.useDiskVersion()
            guard let self else { return }
            switch outcome {
            case .replaced(let text):
                notice = nil
                replacement = WorkspaceFileEditorReplacement(text: text)
                handlers.didShowText(text)
            case .missing, .notEditable:
                reset()
                handlers.didReload()
            case .unavailable:
                notice = String(localized: "Couldn't read the disk version. Your edits were not changed.")
            }
        }
    }

    // MARK: Plumbing

    private func reset() {
        // The page's editor holds the live buffer: hand it back before the page
        // goes, or the session keeps a provider over a freed text view.
        editorPage?.finishEditing()
        editorPage = nil
        identity = nil
        base = nil
        maxBytes = nil
        session = nil
        isEditing = false
        notice = nil
        replacement = nil
        setNeedsUpdate()
    }

    private func setNeedsUpdate() {
        onChange()
    }
}
