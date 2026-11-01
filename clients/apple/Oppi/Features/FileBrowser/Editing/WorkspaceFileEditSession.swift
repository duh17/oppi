import Foundation
import Observation

/// Read and write seams for one document. The live adapter calls
/// `GET`/`PUT /files/current` with the owner's origin (`workspace`, `skill`, or
/// `pi`); a record's prompt has its own route. Tests supply scripted closures.
struct WorkspaceFileEditTransport: Sendable {
    var read: @Sendable (WorkspaceFileEditIdentity) async -> WorkspaceFileReadOutcome
    var write: @Sendable (
        WorkspaceFileEditIdentity,
        Data,
        WorkspaceFileWriteCondition
    ) async -> WorkspaceFileWriteOutcome
}

extension WorkspaceFileEditTransport {
    static func api(_ api: APIClient) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { identity in
                await api.readFileForEditingOutcome(identity)
            },
            write: { identity, bytes, condition in
                await api.writeEditedFile(identity, bytes: bytes, condition: condition)
            }
        )
    }
}

/// Headless edit core for one workspace file.
///
/// The text view owns the live buffer. Keystrokes only bump `editGeneration`
/// and move an idle deadline; bytes are pulled from the attached text provider
/// at checkpoint and save time. One write is in flight at a time. Every write
/// is scoped by generation and a request token, so a late response can never
/// mark newer edits saved or clear their draft.
///
/// Saving stops on conflict (412), deleted (404), or a server refusal. Typing
/// and draft checkpoints continue. A transport failure after the body may have
/// been sent re-reads disk before any retry.
///
/// Every write passes one gate (`WriteOrigin`): with Auto-Save off (the default
/// editor setting) the session's own writes — the idle timer, the flush on the
/// way out, retries, a lost answer checked again — only checkpoint the local
/// draft, and a person's save (Done → Save, ⌘S, `:w`/`:wq`, Replace) is the only
/// thing that reaches the server.
@MainActor @Observable
final class WorkspaceFileEditSession {
    enum Status: Equatable, Sendable {
        /// Buffer equals the last acknowledged disk bytes.
        case saved
        /// Unsaved edits; a save runs after idle when Auto-Save is on, and
        /// otherwise waits for the person.
        case pending
        case saving
        /// Request never reached the server; retrying with the same tag.
        case offline
        /// Outcome unknown; re-reading disk before any retry.
        case verifying
        /// Disk changed under the buffer. Saving stopped.
        case conflict
        /// File deleted or no longer editable. Saving stopped; never recreated.
        case deleted
        /// Buffer exceeds the server's edit limit. Clears on the next edit.
        case tooLarge
        /// Server refused the write. Saving stopped.
        case failed(String)

        var stopsAutosave: Bool {
            switch self {
            case .conflict, .deleted, .failed, .verifying: true
            case .saved, .pending, .saving, .offline, .tooLarge: false
            }
        }
    }

    /// Why a write is starting: the session's own care, or a person asking.
    enum WriteOrigin: Sendable, Equatable {
        /// The session wrote on its own: the idle timer, handing the buffer
        /// back on the way out, a retry, or a lost answer checked again. Runs
        /// only while Auto-Save is on.
        case automatic
        /// A person saved: Done → Save, ⌘S, Vim's `:w`/`:wq`, the conflict
        /// sheet's Replace, or a retry of bytes they already confirmed. The
        /// only origin that writes with Auto-Save off.
        case confirmed
    }

    enum UseDiskResult: Equatable {
        case replaced(String)
        /// The file is gone. The draft was discarded; the caller leaves edit mode.
        case missing
        /// The disk version is no longer editable. The draft was discarded.
        case notEditable
        /// Disk could not be read. Nothing changed.
        case unavailable
    }

    private struct InFlight {
        let token: UUID
        let epoch: Int
        let generation: Int
        let bytes: Data
        let origin: WriteOrigin
    }

    /// A person's save that arrived while a write was in flight: one write runs
    /// at a time, so their bytes wait and go next as `.confirmed`, whatever
    /// origin the flight had.
    private struct PendingSave {
        let generation: Int
        let bytes: Data
    }

    let identity: WorkspaceFileEditIdentity
    let maxBytes: Int
    private(set) var status: Status = .saved
    /// Disk version fetched by Review. Replace uses exactly this tag.
    private(set) var reviewedDisk: WorkspaceFileDiskSnapshot?
    private(set) var recoveredDraft = false
    private(set) var isEditorAttached = false
    /// Last protected-draft write failure. While set, the edits exist only in
    /// memory and the UI must not say they are kept.
    private(set) var draftPersistenceError: String?
    /// A stored draft could not be applied and was moved aside, not deleted.
    private(set) var draftNotice: String?

    @ObservationIgnored private(set) var baseCondition: WorkspaceFileWriteCondition
    @ObservationIgnored private(set) var diskBytes: Data
    @ObservationIgnored private(set) var editGeneration = 0
    @ObservationIgnored private(set) var savedGeneration = 0
    @ObservationIgnored private var bufferText: String
    @ObservationIgnored private var textProvider: (() -> String)?
    @ObservationIgnored private let transport: WorkspaceFileEditTransport
    /// Auto-Save, read at every write rather than captured, so the setting
    /// takes effect in an editor that is already open.
    @ObservationIgnored private let autoSaveSetting: @MainActor () -> Bool
    @ObservationIgnored private let draftStore: WorkspaceFileDraftStore
    @ObservationIgnored private let idleDelay: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var idleDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: InFlight?
    @ObservationIgnored private var inFlightTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    /// The generation a person last confirmed a save of: Done asks only for
    /// edits made after it, so `:wq` and Done → Save close without asking twice.
    @ObservationIgnored private var confirmedGeneration = 0
    /// A person's save waiting for the write in flight; see `saveNow()`.
    @ObservationIgnored private var pendingConfirmedSave: PendingSave?
    /// The notice a refused Discard left, so the write that was in flight can
    /// clear it when it lands instead of leaving a stale sentence behind.
    @ObservationIgnored private var refusedDiscardNotice: String?
    @ObservationIgnored var onSettled: ((WorkspaceFileEditSession) -> Void)?

    private init(
        identity: WorkspaceFileEditIdentity,
        baseCondition: WorkspaceFileWriteCondition,
        diskBytes: Data,
        bufferText: String,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore,
        idleDelay: Duration,
        retryDelay: Duration,
        isAutoSaveOn: @MainActor @escaping () -> Bool
    ) {
        self.identity = identity
        self.maxBytes = maxBytes
        self.transport = transport
        self.autoSaveSetting = isAutoSaveOn
        self.draftStore = draftStore
        self.idleDelay = idleDelay
        self.retryDelay = retryDelay
        self.baseCondition = baseCondition
        self.diskBytes = diskBytes
        self.bufferText = bufferText
    }

    /// Opens a session from one tagged read, or from a read that answered a file
    /// the server offers to create. Returns nil when the server offered neither a
    /// version nor a creation, the bytes are not exact UTF-8, or they exceed
    /// `maxBytes`, or when an unreadable stored draft could not be moved aside.
    /// A stored draft is recovered: same base resumes saving; a different base
    /// opens in conflict with saving stopped. A draft that cannot be applied is
    /// quarantined, never deleted.
    convenience init?(
        identity: WorkspaceFileEditIdentity,
        disk: WorkspaceFileDiskSnapshot,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore = .shared,
        idleDelay: Duration = .seconds(1),
        retryDelay: Duration = .seconds(5),
        isAutoSaveOn: @MainActor @escaping () -> Bool = { CodeEditorPreferences.shared.autoSaves }
    ) {
        guard let condition = disk.writeCondition,
              disk.bytes.count <= maxBytes,
              let diskText = WorkspaceFileTextCodec.decode(disk.bytes) else { return nil }
        let stored = draftStore.loadResult(identity)
        var recovered: (draft: WorkspaceFileDraft, text: String)?
        var notice: String?
        switch stored {
        case .none:
            break
        case .draft(let draft) where draft.bytes == disk.bytes:
            // Disk already holds exactly these bytes: the draft is saved.
            draftStore.remove(identity)
        case .draft(let draft):
            if let text = WorkspaceFileTextCodec.decodeDraft(draft.bytes) {
                recovered = (draft, text)
            } else {
                guard draftStore.quarantine(identity) else { return nil }
                notice = Self.quarantineNotice
            }
        case .unreadable:
            guard draftStore.quarantine(identity) else { return nil }
            notice = Self.quarantineNotice
        }
        self.init(
            identity: identity,
            baseCondition: condition,
            diskBytes: disk.bytes,
            bufferText: diskText,
            maxBytes: maxBytes,
            transport: transport,
            draftStore: draftStore,
            idleDelay: idleDelay,
            retryDelay: retryDelay,
            isAutoSaveOn: isAutoSaveOn
        )
        draftNotice = notice
        guard let recovered else { return }
        bufferText = recovered.text
        editGeneration = 1
        recoveredDraft = true
        if recovered.draft.baseEtag == condition.storedTag {
            status = .pending
            // Recovery is not consent: with Auto-Save off the draft waits for a
            // save, so opening a file never writes it.
            if autoSaveSetting() { scheduleIdle() }
        } else {
            // Keep the draft's own base so a later recovery still sees conflict.
            baseCondition = WorkspaceFileWriteCondition(storedTag: recovered.draft.baseEtag)
            status = .conflict
        }
    }

    /// Reopens a kept draft whose file is gone (404). The session never writes:
    /// Replace needs a reviewed disk version, and a missing file has none.
    convenience init?(
        identity: WorkspaceFileEditIdentity,
        deletedFileDraft draft: WorkspaceFileDraft,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore = .shared,
        idleDelay: Duration = .seconds(1),
        retryDelay: Duration = .seconds(5),
        isAutoSaveOn: @MainActor @escaping () -> Bool = { CodeEditorPreferences.shared.autoSaves }
    ) {
        guard draft.identity == identity,
              let text = WorkspaceFileTextCodec.decodeDraft(draft.bytes) else { return nil }
        self.init(
            identity: identity,
            baseCondition: WorkspaceFileWriteCondition(storedTag: draft.baseEtag),
            diskBytes: Data(),
            bufferText: text,
            maxBytes: maxBytes,
            transport: transport,
            draftStore: draftStore,
            idleDelay: idleDelay,
            retryDelay: retryDelay,
            isAutoSaveOn: isAutoSaveOn
        )
        editGeneration = 1
        recoveredDraft = true
        status = .deleted
    }

    private static let quarantineNotice = String(
        localized: "A stored draft for this file could not be read. It was moved aside on this device and not applied."
    )

    var currentText: String { textProvider?() ?? bufferText }

    /// The save that follows creates the file: nothing is on disk yet, so a clean
    /// buffer has not been saved anywhere. The editor shows "New" rather than
    /// "Saved" while this holds. Read when the chrome applies, which a status
    /// change already triggers, so it needs no observation of its own.
    var createsOnFirstSave: Bool { baseCondition == .absent }

    /// Auto-Save as the setting says right now. The editor's page asks this
    /// rather than holding a copy of the preference, so the one value is the
    /// session's to report.
    var isAutoSaveOn: Bool { autoSaveSetting() }

    var hasUnsavedChanges: Bool {
        editGeneration != savedGeneration
    }

    /// Whether Done must ask before leaving: there are edits no save of the
    /// person's covers, so closing would lose them.
    var hasUnconfirmedChanges: Bool {
        editGeneration != savedGeneration && editGeneration != confirmedGeneration
    }

    /// Clean, idle, and not shown. The registry may drop it.
    var isSettled: Bool { !hasUnsavedChanges && inFlight == nil && !isEditorAttached }

    // MARK: - Editor attachment

    func attachEditor(textProvider: @escaping () -> String) {
        self.textProvider = textProvider
        isEditorAttached = true
    }

    /// Done, Back, or navigation: keep the final buffer, checkpoint, and start a
    /// save without waiting for the network.
    func detachEditor() {
        if let textProvider { bufferText = textProvider() }
        textProvider = nil
        isEditorAttached = false
        flush()
        notifySettledIfNeeded()
    }

    // MARK: - Editing

    /// Keystroke path: O(1), no text copy.
    func noteEdit() {
        editGeneration &+= 1
        if status == .saved || status == .tooLarge { setStatus(.pending) }
        // The timer runs either way: with Auto-Save off it only checkpoints the
        // draft, because the save it then asks for is gated by the setting.
        scheduleIdle()
    }

    /// Synchronous protected draft write. Clean buffers remove the draft.
    func checkpoint() {
        guard hasUnsavedChanges else {
            draftStore.remove(identity)
            if draftPersistenceError != nil { draftPersistenceError = nil }
            return
        }
        let draft = WorkspaceFileDraft(
            identity: identity,
            baseEtag: baseCondition.storedTag,
            bytes: WorkspaceFileTextCodec.encode(currentText),
            updatedAt: Date()
        )
        do {
            try draftStore.save(draft)
            if draftPersistenceError != nil { draftPersistenceError = nil }
        } catch {
            draftPersistenceError = error.localizedDescription
        }
    }

    /// Checkpoint now and start a save if one is allowed. Never waits.
    func flush() {
        cancelIdleSave()
        checkpoint()
        startSaveIfPossible()
    }

    /// A person saved: Done → Save, ⌘S, or Vim's `:w`/`:wq`. The one save that
    /// runs with Auto-Save off, and the only one that marks their edits
    /// confirmed, so closing straight after it does not ask again.
    ///
    /// A save asked for now replaces one that was queued behind the write in
    /// flight: the newer bytes are the person's last word on the document.
    ///
    /// - Returns: whether their bytes were sent or queued behind the write in
    ///   flight. False means nothing was sent — the buffer is over the server's
    ///   limit, or the session has stopped saving — so the caller keeps the
    ///   editor open and its banner is what the person reads.
    @discardableResult
    func saveNow() -> Bool {
        cancelIdleSave()
        checkpoint()
        guard !status.stopsAutosave else { return false }
        let bytes = WorkspaceFileTextCodec.encode(currentText)
        if inFlight != nil {
            // One write at a time: their bytes wait for this one and go next.
            guard bytes.count <= maxBytes else {
                setStatus(.tooLarge)
                return false
            }
            pendingConfirmedSave = PendingSave(generation: editGeneration, bytes: bytes)
            confirmedGeneration = editGeneration
            return true
        }
        // Sent now: anything queued is older than this save.
        pendingConfirmedSave = nil
        guard startSaveIfPossible(origin: .confirmed) else { return false }
        confirmedGeneration = editGeneration
        return true
    }

    /// Where a Discard came from, for the sentence a refusal leaves behind.
    enum DiscardSource {
        /// Done → Discard Changes.
        case page
        /// Vim's quit-without-saving.
        case commandLine

        var refusalNotice: String {
            switch self {
            case .page: String(localized: "Saving… Discard Changes again when it finishes.")
            case .commandLine: String(localized: "Saving… quit again when it finishes.")
            }
        }
    }

    /// The person discarded the changes: back to the disk bytes, draft dropped.
    /// The editor's own buffer goes first: while a text view is attached it *is*
    /// `currentText`, so restoring `bufferText` alone would leave the discarded
    /// edits on screen and hand them back to the reader.
    ///
    /// A write in flight holds the bytes it is writing, so discarding now would
    /// show disk while the server takes the buffer: it is refused, and the
    /// notice line says why. A write that already carries every edit is the
    /// exception — nothing would be lost, so the caller may simply close.
    /// - Returns: whether the edits were discarded (or already on their way).
    @discardableResult
    func discardChanges(from source: DiscardSource = .page) -> Bool {
        if let flight = inFlight {
            if flight.generation == editGeneration,
               flight.bytes == WorkspaceFileTextCodec.encode(currentText) {
                // The write out is exactly what is on screen: closing loses nothing.
                return true
            }
            let notice = source.refusalNotice
            refusedDiscardNotice = notice
            draftNotice = notice
            return false
        }
        draftNotice = nil
        refusedDiscardNotice = nil
        pendingConfirmedSave = nil
        cancelPendingWork()
        textProvider = nil
        bufferText = WorkspaceFileTextCodec.decode(diskBytes) ?? ""
        reviewedDisk = nil
        recoveredDraft = false
        savedGeneration = editGeneration
        confirmedGeneration = editGeneration
        draftStore.remove(identity)
        setStatus(.saved)
        notifySettledIfNeeded()
        return true
    }

    /// Auto-Save was turned on or off while this editor is open: on, an editor
    /// with unsaved edits owes the idle save it had not scheduled; off, any timer
    /// that would have saved is dropped, and the edits are checkpointed now so
    /// the draft keeps them until the person saves.
    func autoSaveSettingChanged(isOn: Bool) {
        guard hasUnsavedChanges, inFlight == nil else { return }
        if isOn {
            if idleTask == nil { scheduleIdle() }
        } else {
            cancelIdleSave()
            checkpoint()
        }
    }

    /// Waits for the current write (and any follow-up it starts) to finish.
    func waitForInFlightWrite() async {
        while let task = inFlightTask {
            await task.value
        }
    }

    /// An open read returned 404 while this session still holds unsaved edits.
    /// Stop idle saves, retries, and verification; ignore any late write result;
    /// keep the draft; and enter the non-writing deleted state so Review and
    /// Use Disk Version are offered. The file is never recreated.
    func noteFileMissing() {
        guard hasUnsavedChanges else { return }
        cancelPendingWork()
        reviewedDisk = nil
        setStatus(.deleted)
        checkpoint()
    }

    // MARK: - Conflict actions

    /// Fetch the disk version for review. If disk already equals the buffer the
    /// conflict resolves to that version.
    @discardableResult
    func reviewDisk() async -> WorkspaceFileReadOutcome {
        let startEpoch = epoch
        let outcome = await transport.read(identity)
        guard startEpoch == epoch else { return outcome }
        switch outcome {
        case .snapshot(let snapshot):
            guard let tag = snapshot.etag else {
                reviewedDisk = nil
                setStatus(.failed(String(localized: "This file is no longer editable.")))
                return outcome
            }
            if snapshot.bytes == WorkspaceFileTextCodec.encode(currentText), inFlight == nil {
                acknowledge(
                    bytes: snapshot.bytes,
                    condition: .version(tag),
                    generation: editGeneration
                )
            } else {
                reviewedDisk = snapshot
                // The file exists again: that is a conflict against this tag,
                // never a create.
                if status == .deleted { setStatus(.conflict) }
            }
        case .creatable:
            // The file is still absent. A session that read it as absent has
            // nothing to review: the create simply did not land, so it retries.
            // Any other base lost the file: there is no disk version to keep.
            reviewedDisk = nil
            if baseCondition == .absent {
                if inFlight == nil {
                    setStatus(.pending)
                    startSaveIfPossible()
                }
            } else if inFlight == nil {
                setStatus(.deleted)
            }
        case .missing:
            // No disk version at all: there is nothing to review or to keep.
            reviewedDisk = nil
            if inFlight == nil { setStatus(.deleted) }
        case .failed:
            break
        }
        return outcome
    }

    /// Overwrite disk with the buffer, conditioned on the reviewed disk version.
    /// Never recreates a deleted file. A person chose Replace, so it writes
    /// whatever Auto-Save says.
    func replaceDiskVersion() {
        guard status == .conflict, inFlight == nil,
              let reviewed = reviewedDisk,
              case .version(let tag) = reviewed.writeCondition else { return }
        let bytes = WorkspaceFileTextCodec.encode(currentText)
        guard bytes.count <= maxBytes else {
            setStatus(.tooLarge)
            return
        }
        reviewedDisk = nil
        confirmedGeneration = editGeneration
        // Replace writes the buffer: a save queued behind the flight is older.
        pendingConfirmedSave = nil
        send(bytes: bytes, generation: editGeneration, condition: .version(tag), origin: .confirmed)
    }

    /// Discard the buffer for the disk version (reviewed, else freshly read).
    func useDiskVersion() async -> UseDiskResult {
        guard inFlight == nil else { return .unavailable }
        let snapshot: WorkspaceFileDiskSnapshot
        if let reviewedDisk {
            snapshot = reviewedDisk
        } else {
            let startEpoch = epoch
            switch await transport.read(identity) {
            case .snapshot(let read):
                guard startEpoch == epoch, inFlight == nil else { return .unavailable }
                snapshot = read
            case .missing, .creatable:
                // No disk version: a file that is not there is the same answer
                // as one that was deleted.
                discardForMissingFile()
                return .missing
            case .failed:
                return .unavailable
            }
        }
        cancelPendingWork()
        guard let condition = snapshot.writeCondition,
              snapshot.bytes.count <= maxBytes,
              let text = WorkspaceFileTextCodec.decode(snapshot.bytes) else {
            draftStore.remove(identity)
            savedGeneration = editGeneration
            confirmedGeneration = editGeneration
            setStatus(.failed(String(localized: "This file is no longer editable.")))
            return .notEditable
        }
        bufferText = text
        baseCondition = condition
        diskBytes = snapshot.bytes
        editGeneration &+= 1
        savedGeneration = editGeneration
        confirmedGeneration = editGeneration
        reviewedDisk = nil
        recoveredDraft = false
        draftStore.remove(identity)
        setStatus(.saved)
        notifySettledIfNeeded()
        return .replaced(text)
    }

    // MARK: - Save machine

    private func scheduleIdle() {
        idleDeadline = ContinuousClock.now.advanced(by: idleDelay)
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while true {
                guard let deadline = self?.idleDeadline else { return }
                if ContinuousClock.now >= deadline { break }
                try? await Task.sleep(until: deadline, clock: .continuous)
                if Task.isCancelled { return }
            }
            guard let self else { return }
            self.idleTask = nil
            self.idleDeadline = nil
            self.checkpoint()
            self.startSaveIfPossible()
        }
    }

    private func startSaveIfPossible(origin: WriteOrigin = .automatic) -> Bool {
        guard inFlight == nil, !status.stopsAutosave else { return false }
        guard hasUnsavedChanges else {
            if status != .saved { setStatus(.saved) }
            return true
        }
        let generation = editGeneration
        let bytes = WorkspaceFileTextCodec.encode(currentText)
        if bytes == diskBytes {
            // Nothing to send: an empty document that was never created stays
            // uncreated, so the base stays the creation it was. Bytes that are
            // the disk's again are clean — Done has nothing left to ask.
            acknowledge(bytes: bytes, condition: baseCondition, generation: generation)
            return true
        }
        guard bytes.count <= maxBytes else {
            setStatus(.tooLarge)
            return false
        }
        return send(bytes: bytes, generation: generation, condition: baseCondition, origin: origin)
    }

    /// The one gate every write passes: the session's own care (the idle timer,
    /// the flush on the way out, a retry, a lost answer checked again) needs
    /// Auto-Save on, and a person's save is the only thing that writes without
    /// it. Nothing reaches the server any other way, so no caller — the conflict
    /// sheet's Replace included — can write around the setting.
    /// - Returns: whether the write started.
    @discardableResult
    private func send(
        bytes: Data,
        generation: Int,
        condition: WorkspaceFileWriteCondition,
        origin: WriteOrigin
    ) -> Bool {
        guard origin == .confirmed || autoSaveSetting() else { return false }
        retryTask?.cancel()
        retryTask = nil
        let flight = InFlight(
            token: UUID(),
            epoch: epoch,
            generation: generation,
            bytes: bytes,
            origin: origin
        )
        inFlight = flight
        setStatus(.saving)
        let transport = transport
        let identity = identity
        inFlightTask = Task { [weak self] in
            let outcome = await transport.write(identity, bytes, condition)
            self?.handleWrite(outcome, for: flight)
        }
        return true
    }

    private func handleWrite(_ outcome: WorkspaceFileWriteOutcome, for flight: InFlight) {
        guard inFlight?.token == flight.token else { return }
        inFlight = nil
        inFlightTask = nil
        // The write it waited for is over, so the notice it left is stale.
        clearRefusedDiscardNotice()
        guard flight.epoch == epoch else { return }
        switch outcome {
        case .saved(let etag):
            acknowledge(bytes: flight.bytes, condition: .version(etag), generation: flight.generation)
        case .stale:
            // Nothing a person queued can be sent now: their save was made
            // against a version that is gone, and Review or Use Disk decides
            // what the buffer becomes.
            pendingConfirmedSave = nil
            reviewedDisk = nil
            setStatus(.conflict)
            checkpoint()
        case .missing:
            pendingConfirmedSave = nil
            reviewedDisk = nil
            setStatus(.deleted)
            checkpoint()
        case .rejected(let status, let message):
            pendingConfirmedSave = nil
            setStatus(status == 413 ? .tooLarge : .failed(message))
            checkpoint()
        case .notSent:
            setStatus(.offline)
            checkpoint()
            scheduleRetry(after: flight)
        case .unknown:
            setStatus(.verifying)
            checkpoint()
            verify(after: flight, delay: nil)
        }
    }

    /// The write landed (or nothing needed writing): the session's base is now
    /// what the next save is conditioned on.
    private func acknowledge(
        bytes: Data,
        condition: WorkspaceFileWriteCondition,
        generation: Int
    ) {
        baseCondition = condition
        diskBytes = bytes
        savedGeneration = generation
        reviewedDisk = nil
        if editGeneration == generation {
            setStatus(.saved)
            draftStore.remove(identity)
            notifySettledIfNeeded()
        } else {
            setStatus(.pending)
            checkpoint()
        }
        // A person's save that waited for this flight goes first: it is the
        // bytes they asked for, not whatever the session would send next. A
        // buffer over the limit stays Too Large rather than being called saved.
        if !sendPendingConfirmedSave(), editGeneration != generation, idleTask == nil, status != .tooLarge {
            startSaveIfPossible()
        }
    }

    /// Sends the save a person asked for while a write was in flight, as a
    /// confirmed write of the bytes they had on screen then.
    /// - Returns: whether it had something to send.
    @discardableResult
    private func sendPendingConfirmedSave() -> Bool {
        guard let pending = pendingConfirmedSave else { return false }
        pendingConfirmedSave = nil
        guard !status.stopsAutosave else { return false }
        guard pending.bytes != diskBytes else {
            // The flight that just landed wrote their bytes: nothing is left to
            // send, and their save is acknowledged against the base it left.
            acknowledge(bytes: pending.bytes, condition: baseCondition, generation: pending.generation)
            return false
        }
        guard pending.bytes.count <= maxBytes else {
            setStatus(.tooLarge)
            return false
        }
        return send(
            bytes: pending.bytes,
            generation: pending.generation,
            condition: baseCondition,
            origin: .confirmed
        )
    }

    private func scheduleRetry(after flight: InFlight) {
        // A retry is the session's own write. With Auto-Save off only bytes a
        // person already confirmed go again; the rest stay pending and kept.
        guard flight.origin == .confirmed || autoSaveSetting() else {
            // A save the person queued behind this flight is still theirs to
            // send: Auto-Save has nothing to do with it.
            if sendPendingConfirmedSave() { return }
            setStatus(.pending)
            checkpoint()
            return
        }
        retryTask?.cancel()
        let delay = retryDelay
        let startEpoch = epoch
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.epoch == startEpoch, self.status == .offline else { return }
            self.retryTask = nil
            self.retry(flight)
        }
    }

    /// The same bytes under the same generation go again. A retry never picks up
    /// newer edits: a person's confirmed save stays the save they asked for, and
    /// the session's own retry is the write it started, not whatever the buffer
    /// holds by now.
    private func retry(_ flight: InFlight) {
        guard flight.epoch == epoch, inFlight == nil else { return }
        guard flight.origin == .confirmed || autoSaveSetting() else {
            // Auto-Save went off while this retry waited: nothing is owed. The
            // edits are unsaved, not unreachable — the banner says so, and the
            // draft keeps them. A save the person queued is still theirs to send.
            if sendPendingConfirmedSave() { return }
            setStatus(.pending)
            checkpoint()
            return
        }
        guard !status.stopsAutosave else { return }
        send(bytes: flight.bytes, generation: flight.generation, condition: baseCondition, origin: flight.origin)
    }

    /// Unknown outcome: never re-send until a read says whether the write landed.
    private func verify(after flight: InFlight, delay: Duration?) {
        retryTask?.cancel()
        let transport = transport
        let identity = identity
        retryTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            let outcome = await transport.read(identity)
            guard let self, !Task.isCancelled else { return }
            self.handleVerify(outcome, for: flight)
        }
    }

    private func handleVerify(_ outcome: WorkspaceFileReadOutcome, for flight: InFlight) {
        guard flight.epoch == epoch, status == .verifying, inFlight == nil else { return }
        retryTask = nil
        switch outcome {
        case .snapshot(let snapshot):
            if snapshot.bytes == flight.bytes, let tag = snapshot.etag {
                acknowledge(bytes: flight.bytes, condition: .version(tag), generation: flight.generation)
            } else if snapshot.writeCondition == baseCondition {
                setStatus(.pending)
                retry(flight)
            } else {
                // Disk is a version nobody can write over: a queued save was
                // made against the old one.
                pendingConfirmedSave = nil
                setStatus(.conflict)
                checkpoint()
            }
        case .missing:
            pendingConfirmedSave = nil
            setStatus(.deleted)
            checkpoint()
        case .creatable:
            // A create whose answer was lost, and the file is still not there:
            // it did not land. With Auto-Save on the save goes again rather
            // than stranding the editor (a person's confirmed save likewise);
            // off, the edits stay pending and kept, and only a save sends them.
            if baseCondition == .absent {
                setStatus(.pending)
                checkpoint()
                retry(flight)
            } else {
                pendingConfirmedSave = nil
                setStatus(.deleted)
                checkpoint()
            }
        case .failed:
            verify(after: flight, delay: retryDelay)
        }
    }

    private func discardForMissingFile() {
        cancelPendingWork()
        pendingConfirmedSave = nil
        textProvider = nil
        draftStore.remove(identity)
        savedGeneration = editGeneration
        confirmedGeneration = editGeneration
        reviewedDisk = nil
        setStatus(.deleted)
    }

    private func cancelIdleSave() {
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
    }

    private func cancelPendingWork() {
        epoch &+= 1
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        retryTask?.cancel()
        retryTask = nil
        inFlight = nil
        inFlightTask = nil
        pendingConfirmedSave = nil
    }

    /// The notice a refused Discard left goes once the write it waited for ends:
    /// it described a moment that is over.
    private func clearRefusedDiscardNotice() {
        guard let refusedDiscardNotice, draftNotice == refusedDiscardNotice else { return }
        self.refusedDiscardNotice = nil
        draftNotice = nil
    }

    private func setStatus(_ next: Status) {
        if status != next { status = next }
    }

    private func notifySettledIfNeeded() {
        if isSettled { onSettled?(self) }
    }

#if DEBUG
#endif
}
