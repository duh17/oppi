import UIKit

/// One document's edit entry, and the only place that decides what it offers.
///
/// The owner answers the three questions every reader used to answer for
/// itself: can these bytes open our editor (a pencil), is there a session to
/// offer beside it (a "…" holding Edit with Session), and what the reader
/// shows while an editor is open (the tagged read, a recovered draft, the
/// conflict banner). The pencil appears only when the subject resolves to an
/// edit identity, the server advertises editing for it, and the bytes are a
/// tagged UTF-8 text read within the server's limit — or when a session already
/// exists, which is how a draft kept for a deleted file opens again.
///
/// It also owns the editor's presentation: a screen that embeds the page (the
/// file viewer) hosts `makeEditorPage`, and a reader with no editor of its own
/// asks the owner to present it (`presentEditorIfNeeded(from:)`) and the owner
/// closes it when `isEditing` ends.
///
/// Saves stay with `WorkspaceFileEditSession` and the `WorkspaceFileWriteOutcome`
/// contract; the owner picks the backend, so a document served by something
/// other than `/files/current` (an Agent's or a schedule's prompt) plugs into
/// the same outcomes.
@MainActor
final class DocumentEditOwner {
    /// Reads and writes one document. The live backend is the paired server's
    /// `/files/current`, or the record's own route; tests and previews script
    /// the answers.
    struct Backend {
        /// Nil when the server does not edit this owner's files.
        var capability: (WorkspaceFileEditIdentity.Owner) async -> ServerInfo.WorkspaceFileEditingCapability?
        var transport: WorkspaceFileEditTransport

        static func api(_ api: APIClient) -> Self {
            Self(
                // The API client is an actor: the capability is its answer, not ours.
                capability: { await api.fileEditingCapability(for: $0) },
                transport: .api(api)
            )
        }

        /// A record's prompt: its own route and version tag, and no file-editing
        /// capability to check (the server has none), so its limit is this
        /// client's.
        static func record(transport: WorkspaceFileEditTransport) -> Self {
            Self(capability: { _ in recordPromptCapability }, transport: transport)
        }

        /// What serves this subject on `api`: a record's own route for a prompt,
        /// `/files/current` for a file. One rule, so a reader never picks.
        static func make(for subject: DocumentEditSubject, api: APIClient) -> Self {
            switch subject {
            case .agentInstructions(let agentId):
                return .record(transport: .agentInstructions(api: api, agentId: agentId))
            case .schedulePrompt(let scheduleId):
                return .record(transport: .schedulePrompt(api: api, scheduleId: scheduleId))
            case .file, .snapshot, .piFile:
                return .api(api)
            }
        }

        /// What a reader may type into a record's prompt. A prompt is text a
        /// person wrote; this only keeps a runaway buffer out of the editor.
        static let recordPromptMaxBytes = 1_048_576

        private static let recordPromptCapability = ServerInfo.WorkspaceFileEditingCapability(
            version: 1,
            maxBytes: recordPromptMaxBytes
        )
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
        /// The editor closed: the screen shows the document again, read fresh
        /// when it can (a prompt's reader shows its whole definition).
        var didFinishEditing: () -> Void = {}
        /// The file is gone and the draft was discarded: reload it.
        var didReload: () -> Void = {}
        /// The reader a Preview shows, built over the editor's draft.
        var makePreview: (String) -> UIViewController = { _ in UIViewController() }
        /// What Done's confirmation says about this document beyond its name.
        /// Pi's own files add that Pi uses them for every new session on the
        /// server, which is display metadata the screen showing them knows. Nil
        /// keeps the confirmation short.
        var saveConfirmationMessage: @MainActor () -> String? = { nil }
    }

    private(set) var subject: DocumentEditSubject
    let handlers: Handlers
    /// Edit with Session, when the screen offers one.
    let agentAction: DocumentAgentEditAction?
    /// The server a record's prompt lives on, read when the owner reads: a file
    /// subject carries its own, and a reader's server can arrive after the owner.
    private let serverIdSource: @MainActor () -> String?
    /// The server's client, read when the owner reads for the same reason.
    private let backendSource: @MainActor () -> Backend?
    /// Construction context for the editor page's conflict sheet.
    private let reviewCommentSelectionScope: ReviewCommentSelectionScope?
    let draftStore: WorkspaceFileDraftStore
    private let registry: WorkspaceFileEditSessionRegistry
    private let onChange: @MainActor () -> Void
    /// Auto-Save, handed to every session this owner opens: one editor setting
    /// for every document, whatever its owner or name.
    private let isAutoSaveOn: @MainActor () -> Bool
    /// Bumped by every `begin`: a read that started for the previous document
    /// must not write this one's state.
    private var generation = 0

    /// The file this document edits, once the subject resolved to one.
    private(set) var identity: WorkspaceFileEditIdentity?
    /// The tagged read the editor starts from. Nil means no pencil, whatever
    /// else is true of the document.
    private(set) var base: WorkspaceFileDiskSnapshot?
    /// The canonical host path the resolving read reported, when it was read in
    /// a host context: the base a host Markdown file's relative links need, which
    /// the reader would otherwise get from its own read.
    private(set) var resolvedHostPath: String?
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
    /// The page this owner presented over a reader, while it is up.
    private weak var presentedEditor: DocumentEditEditorPage?

    private var cachedOffersEditor: Bool?
    private var cachedBarItems: [UIBarButtonItem] = []

    init(
        subject: DocumentEditSubject,
        serverId: @escaping @MainActor () -> String? = { nil },
        agentAction: DocumentAgentEditAction? = nil,
        backend: @escaping @MainActor () -> Backend?,
        reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil,
        draftStore: WorkspaceFileDraftStore = .shared,
        registry: WorkspaceFileEditSessionRegistry = .shared,
        handlers: Handlers = Handlers(),
        isAutoSaveOn: @MainActor @escaping () -> Bool = { CodeEditorPreferences.shared.autoSaves },
        onChange: @escaping @MainActor () -> Void
    ) {
        self.subject = subject
        self.serverIdSource = serverId
        self.agentAction = agentAction
        self.backendSource = backend
        self.reviewCommentSelectionScope = reviewCommentSelectionScope
        self.draftStore = draftStore
        self.registry = registry
        self.handlers = handlers
        self.isAutoSaveOn = isAutoSaveOn
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
    ///
    /// A file is first read where the reader reached it, and the server names
    /// the origin that edits it (`FileEditResolution`): a link, a session's
    /// path, and the workspace tree all land on one identity for one file, so
    /// they share one session, one draft, and one pencil rule. A server that
    /// cannot say leaves the subject's own identity in charge.
    func read() async -> ReadResult {
        let generation = generation
        let serverId = serverIdSource()
        guard subject.fileKind?.previewCategory == .text,
              let backend = backendSource() else {
            reset()
            return .ownRead
        }
        var subjectIdentity = subject.editIdentity(serverId: serverId)
        var resolved: WorkspaceFileDiskSnapshot?
        if let location = subject.resolutionLocation(serverId: serverId) {
            let resolution = await backend.transport.resolve(location)
            guard generation == self.generation else { return .ownRead }
            switch resolution {
            case .editable(let canonical, let snapshot, let resolvedHostPath):
                subjectIdentity = canonical
                resolved = snapshot
                self.resolvedHostPath = resolvedHostPath
            case .readOnly:
                // The server's word on this file. A subject with an identity of
                // its own still reads it, untagged, so a deleted file's draft and
                // the reader's text stay as they were.
                if subjectIdentity == nil {
                    reset()
                    return .ownRead
                }
            case .unresolved:
                break
            }
        }
        guard let identity = subjectIdentity else {
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
        let outcome: WorkspaceFileReadOutcome
        if let resolved {
            outcome = resolved.creatable ? .creatable : .snapshot(resolved)
        } else {
            outcome = await backend.transport.read(identity)
        }
        switch outcome {
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
        case .creatable:
            guard generation == self.generation else { return .ownRead }
            // A file the server offers to create: the editor starts from the text
            // the reader supplied — Pi's default prompt for `SYSTEM.md`, nothing
            // for a template — so Done with no change is not a change and writes
            // nothing, and the first real edit's save creates the file. The
            // reader keeps showing what it had (Pi's default prompt).
            let seed = WorkspaceFileDiskSnapshot(
                bytes: Data((subject.creatableSeedText ?? "").utf8),
                etag: nil,
                creatable: true
            )
            base = Self.editableBase(seed, maxBytes: capability.maxBytes)
            return .bytes(
                seed,
                draftText: prepareEditing(
                    identity: identity,
                    snapshot: seed,
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
                draftStore: draftStore,
                isAutoSaveOn: isAutoSaveOn
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

    /// The server offered these bytes for editing: a version to overwrite or a
    /// file to create, exact UTF-8, and within its limit. The same conditions
    /// `WorkspaceFileEditSession` needs, so the pencil can never open an editor
    /// that cannot start.
    private static func editableBase(
        _ snapshot: WorkspaceFileDiskSnapshot,
        maxBytes: Int
    ) -> WorkspaceFileDiskSnapshot? {
        guard snapshot.writeCondition != nil,
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
                  draftStore: draftStore,
                  isAutoSaveOn: isAutoSaveOn
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
        if cachedOffersEditor != offersEditor {
            cachedOffersEditor = offersEditor
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
        // Editing is the reader's main action: on a narrow bar the reader's
        // other buttons fold into the system's "…" before these do.
        if #available(iOS 27.0, *) {
            for item in items { item.visibilityPriority = .high }
        }
        return items
    }

    private func pencilItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            title: DocumentEditLabels.edit,
            image: UIImage(systemName: DocumentEditLabels.systemImage),
            primaryAction: UIAction { [weak self] _ in self?.beginEditing() }
        )
        item.accessibilityLabel = DocumentEditLabels.editFile
        // One identifier for the pencil in either bar: the primary control the
        // reader's own tests and the tree pane's both look for.
        item.accessibilityIdentifier = "workspace-file-editor.edit"
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

    // MARK: Editing

    /// Opens our editor on the displayed bytes, reusing a live session so one
    /// file never has two writers with different base tags.
    func beginEditing() {
        guard let session = editSession() else { return }
        adopt(session)
    }

    /// The session that writes this document: a live one, else the newest this
    /// owner held (it keeps the latest acknowledged tag after an edit settled),
    /// else one made from the tagged read.
    private func editSession() -> WorkspaceFileEditSession? {
        guard let identity, let maxBytes, let backend = backendSource() else { return nil }
        let session: WorkspaceFileEditSession
        if let live = registry.session(for: identity) {
            session = live
        } else if let existing = self.session, existing.identity == identity {
            session = existing
            registry.register(existing)
        } else if let base,
                  let created = WorkspaceFileEditSession(
                      identity: identity,
                      disk: base,
                      maxBytes: maxBytes,
                      transport: backend.transport,
                      draftStore: draftStore,
                      isAutoSaveOn: isAutoSaveOn
                  ) {
            session = created
            registry.register(created)
        } else {
            return nil
        }
        self.session = session
        return session
    }

    // MARK: Edits from the reader

    /// Whether the reader may edit the document it shows in place (a tapped
    /// task control): the same tagged, editable text read that offers the
    /// pencil, and no editor open over it.
    var allowsReaderEdits: Bool {
        identity != nil && maxBytes != nil && base != nil && !isEditing
    }

    enum ReaderEditOutcome: Equatable {
        /// Saved: the reader shows this text.
        case saved(String)
        /// The edit changed nothing.
        case unchanged
        /// The save did not land (the file changed on disk, is gone, or could
        /// not be reached). The editor opened over the reader with the edit in
        /// its buffer, and its banner offers the existing conflict choices.
        case needsAttention
        case unavailable
    }

    /// The task controls for a Markdown or Org reader of this document, or nil
    /// when the reader may not edit in place (the pencil's rule, so a file the
    /// editor cannot save shows none) or the file is neither. `show` receives the
    /// text each saved edit leaves, for the reader to render; an edit that did not
    /// land has opened the editor instead, and its banner takes over.
    func makeReaderTaskEditing(
        path: String,
        show: @escaping @MainActor (String) -> Void
    ) -> ReaderTaskEditing? {
        guard allowsReaderEdits else { return nil }
        let dialect: TaskSourceEdit.Dialect
        switch FileKind.detect(from: path) {
        case .markdown: dialect = .markdown
        case .orgMode: dialect = .org
        default: return nil
        }
        return ReaderTaskEditing(
            dialect: dialect,
            isAvailable: { [weak self] in self?.allowsReaderEdits == true },
            source: { [weak self] in
                guard let self else { return "" }
                return session?.currentText ?? base.flatMap { WorkspaceFileTextCodec.decode($0.bytes) } ?? ""
            },
            apply: { [weak self] transform in
                guard case .saved(let text)? = await self?.saveReaderEdit(transform) else { return }
                show(text)
            }
        )
    }

    /// Saves the edit `transform` makes to the document's current text, through
    /// the document's edit session: the same write, version check and conflict
    /// handling as the editor. Nothing is written but the edited text.
    func saveReaderEdit(_ transform: (String) -> String?) async -> ReaderEditOutcome {
        guard allowsReaderEdits, let session = editSession() else { return .unavailable }
        guard let edited = transform(session.currentText), edited != session.currentText else { return .unchanged }
        guard session.saveReaderEdit(edited) else {
            adopt(session)
            return .needsAttention
        }
        await session.waitForInFlightWrite()
        guard session.status == .saved else {
            adopt(session)
            return .needsAttention
        }
        return .saved(session.currentText)
    }

    /// Done: the editor hands its buffer back and starts the save, and the page
    /// goes because `isEditing` ended. The screen hears about it once the write
    /// in flight has landed, so a reader that re-reads the record shows the save
    /// and not what it replaced.
    func endEditing() {
        guard let session else {
            isEditing = false
            closeEditor()
            onChange()
            return
        }
        // Teardown first, so the session holds the final buffer.
        editorPage?.finishEditing()
        editorPage = nil
        isEditing = false
        closeEditor()
        onChange()
        Task { [weak self] in
            await session.waitForInFlightWrite()
            guard let self, self.session === session || !self.isEditing else { return }
            self.handlers.didFinishEditing()
        }
    }

    /// Presents the open editor over a reader that has none of its own. The
    /// owner closes it in `endEditing`, so the page never outlives `isEditing`.
    func presentEditorIfNeeded(from presenter: UIViewController) {
        guard isEditing else {
            closeEditor()
            return
        }
        guard presentedEditor == nil, let page = makeEditorPage(checkoutSubtitle: nil) else { return }
        page.title = editorTitle
        presentedEditor = page
        Router.present(
            page,
            presentation: .fullScreen.inNavigation(),
            from: presenter,
            onDismiss: { [weak self] in
                self?.presentedEditor = nil
                guard let self, self.isEditing else { return }
                // Closed by another hand: the reader and the owner stay in step.
                self.endEditing()
            }
        )
    }

    private func closeEditor() {
        guard let presentedEditor else { return }
        self.presentedEditor = nil
        if let container = presentedEditor.navigationController {
            Router.finish(container)
        }
    }

    private var editorTitle: String {
        switch subject {
        case .agentInstructions: String(localized: "System Prompt")
        case .schedulePrompt: String(localized: "Prompt")
        case .piFile(let path, _): (path as NSString).lastPathComponent
        case .file, .snapshot: String(localized: "Edit")
        }
    }

    /// What Done's confirmation calls the document. A file — a workspace file, a
    /// Skill's own file, Pi's own — is its own name; a record's prompt has no
    /// file, so it keeps the subject's word. The editor's title cannot answer
    /// this: it reads "Edit" for a file, which would ask "Save Edit?".
    static func saveConfirmationName(subject: DocumentEditSubject, identity: WorkspaceFileEditIdentity) -> String {
        switch subject {
        case .agentInstructions: String(localized: "System Prompt")
        case .schedulePrompt: String(localized: "Prompt")
        case .file, .piFile, .snapshot: (identity.path as NSString).lastPathComponent
        }
    }

    /// Hosts the editor page of an open session; nil when nothing is open.
    /// Each open editor is its own page: finishing one detaches the session
    /// for good, so it is never handed back. `checkoutSubtitle` is the screen's
    /// answer for this update, as main recomputed it on every pass.
    func makeEditorPage(checkoutSubtitle: String?) -> DocumentEditEditorPage? {
        guard isEditing, let session else { return nil }
        if let editorPage { return editorPage }
        let page = DocumentEditEditorPage(
            session: session,
            checkoutSubtitle: checkoutSubtitle,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            onDone: { [weak self] in self?.endEditing() },
            onTogglePreview: { [weak self] in
                self?.editorPage?.togglePreview()
                self?.onChange()
            },
            makePreview: handlers.makePreview,
            saveConfirmationName: Self.saveConfirmationName(subject: subject, identity: session.identity),
            // A screen that has something to say about the document beyond its
            // name supplies the sentence; the owner does not decide which
            // documents get one.
            saveConfirmationMessage: handlers.saveConfirmationMessage(),
            onUseDisk: { [weak self] in self?.useDiskVersion() }
        )
        editorPage = page
        return page
    }

    /// Repaints the open editor and applies a replaced draft.
    func updateEditorPage(palette: ThemePalette, checkoutSubtitle: String?) {
        guard let editorPage else { return }
        editorPage.apply(
            palette: palette,
            checkoutSubtitle: checkoutSubtitle,
            replacement: replacement,
            notice: notice
        )
    }

    /// The page is going away (the viewer is popped, or shows another file):
    /// the editor hands its buffer to the session and closes its sheets first.
    func finishEditing() {
        editorPage?.finishEditing()
        editorPage = nil
    }

    private func adopt(_ session: WorkspaceFileEditSession) {
        self.session = session
        notice = nil
        isEditing = true
        onChange()
    }

    private func useDiskVersion() {
        guard let session else { return }
        let generation = generation
        Task { [weak self] in
            let outcome = await session.useDiskVersion()
            // The reader may have moved on to another file meanwhile: its state
            // is not this read's to change.
            guard let self, generation == self.generation else { return }
            switch outcome {
            case .replaced(let text):
                notice = nil
                replacement = WorkspaceFileEditorReplacement(text: text)
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
        // The page's editor holds the live buffer: hand it back (and close its
        // sheets) before the page goes, or the session keeps a provider over a
        // freed text view.
        editorPage?.finishEditing()
        editorPage = nil
        closeEditor()
        identity = nil
        base = nil
        resolvedHostPath = nil
        maxBytes = nil
        session = nil
        isEditing = false
        notice = nil
        replacement = nil
        onChange()
    }
}
