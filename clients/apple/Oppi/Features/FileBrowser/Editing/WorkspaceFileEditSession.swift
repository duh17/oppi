import Foundation
import Observation

/// Read and write seams for one editable workspace file. The live adapter calls
/// `GET`/`PUT /files/current?origin=workspace`; tests supply scripted closures.
struct WorkspaceFileEditTransport: Sendable {
    var read: @Sendable (WorkspaceFileEditIdentity) async -> WorkspaceFileReadOutcome
    var write: @Sendable (WorkspaceFileEditIdentity, Data, String) async -> WorkspaceFileWriteOutcome
}

extension WorkspaceFileEditTransport {
    static func api(_ api: APIClient) -> WorkspaceFileEditTransport {
        WorkspaceFileEditTransport(
            read: { identity in
                await api.readWorkspaceFileForEditingOutcome(
                    workspaceId: identity.workspaceId,
                    path: identity.path,
                    worktreeId: identity.worktreeId
                )
            },
            write: { identity, bytes, ifMatch in
                await api.writeWorkspaceFile(
                    workspaceId: identity.workspaceId,
                    path: identity.path,
                    worktreeId: identity.worktreeId,
                    bytes: bytes,
                    ifMatch: ifMatch
                )
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
/// Autosave stops on conflict (412), deleted (404), or a server refusal. Typing
/// and draft checkpoints continue. A transport failure after the body may have
/// been sent re-reads disk before any retry.
@MainActor @Observable
final class WorkspaceFileEditSession {
    enum Status: Equatable, Sendable {
        /// Buffer equals the last acknowledged disk bytes.
        case saved
        /// Unsaved edits; autosave will run after idle.
        case pending
        case saving
        /// Request never reached the server; retrying with the same tag.
        case offline
        /// Outcome unknown; re-reading disk before any retry.
        case verifying
        /// Disk changed under the buffer. Autosave stopped.
        case conflict
        /// File deleted or no longer editable. Autosave stopped; never recreated.
        case deleted
        /// Buffer exceeds the server's edit limit. Clears on the next edit.
        case tooLarge
        /// Server refused the write. Autosave stopped.
        case failed(String)

        var stopsAutosave: Bool {
            switch self {
            case .conflict, .deleted, .failed, .verifying: true
            case .saved, .pending, .saving, .offline, .tooLarge: false
            }
        }
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

    @ObservationIgnored private(set) var baseEtag: String
    @ObservationIgnored private(set) var diskBytes: Data
    @ObservationIgnored private(set) var editGeneration = 0
    @ObservationIgnored private(set) var savedGeneration = 0
    @ObservationIgnored private var bufferText: String
    @ObservationIgnored private var textProvider: (() -> String)?
    @ObservationIgnored private let transport: WorkspaceFileEditTransport
    @ObservationIgnored private let draftStore: WorkspaceFileDraftStore
    @ObservationIgnored private let idleDelay: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var idleDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var inFlight: InFlight?
    @ObservationIgnored private var inFlightTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored var onSettled: ((WorkspaceFileEditSession) -> Void)?

    private init(
        identity: WorkspaceFileEditIdentity,
        baseEtag: String,
        diskBytes: Data,
        bufferText: String,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore,
        idleDelay: Duration,
        retryDelay: Duration
    ) {
        self.identity = identity
        self.maxBytes = maxBytes
        self.transport = transport
        self.draftStore = draftStore
        self.idleDelay = idleDelay
        self.retryDelay = retryDelay
        self.baseEtag = baseEtag
        self.diskBytes = diskBytes
        self.bufferText = bufferText
    }

    /// Opens a session from one tagged read. Returns nil when the server did not
    /// tag the bytes, they are not exact UTF-8, or they exceed `maxBytes`, or
    /// when an unreadable stored draft could not be moved aside.
    /// A stored draft is recovered: same base tag resumes autosave; a different
    /// disk tag opens in conflict with autosave stopped. A draft that cannot be
    /// applied is quarantined, never deleted.
    convenience init?(
        identity: WorkspaceFileEditIdentity,
        disk: WorkspaceFileDiskSnapshot,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore = .shared,
        idleDelay: Duration = .seconds(1),
        retryDelay: Duration = .seconds(5)
    ) {
        guard let etag = disk.etag,
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
            baseEtag: etag,
            diskBytes: disk.bytes,
            bufferText: diskText,
            maxBytes: maxBytes,
            transport: transport,
            draftStore: draftStore,
            idleDelay: idleDelay,
            retryDelay: retryDelay
        )
        draftNotice = notice
        guard let recovered else { return }
        bufferText = recovered.text
        editGeneration = 1
        recoveredDraft = true
        if recovered.draft.baseEtag == etag {
            status = .pending
            scheduleIdle()
        } else {
            // Keep the draft's own base so a later recovery still sees conflict.
            baseEtag = recovered.draft.baseEtag
            status = .conflict
        }
    }

    /// Reopens a kept draft whose file is gone (404). The session never writes:
    /// Replace needs a reviewed disk tag, and a missing file has none.
    convenience init?(
        identity: WorkspaceFileEditIdentity,
        deletedFileDraft draft: WorkspaceFileDraft,
        maxBytes: Int,
        transport: WorkspaceFileEditTransport,
        draftStore: WorkspaceFileDraftStore = .shared,
        idleDelay: Duration = .seconds(1),
        retryDelay: Duration = .seconds(5)
    ) {
        guard draft.identity == identity,
              let text = WorkspaceFileTextCodec.decodeDraft(draft.bytes) else { return nil }
        self.init(
            identity: identity,
            baseEtag: draft.baseEtag,
            diskBytes: Data(),
            bufferText: text,
            maxBytes: maxBytes,
            transport: transport,
            draftStore: draftStore,
            idleDelay: idleDelay,
            retryDelay: retryDelay
        )
        editGeneration = 1
        recoveredDraft = true
        status = .deleted
    }

    private static let quarantineNotice = String(
        localized: "A stored draft for this file could not be read. It was moved aside on this device and not applied."
    )

    var currentText: String { textProvider?() ?? bufferText }

    var hasUnsavedChanges: Bool { editGeneration != savedGeneration }

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
            baseEtag: baseEtag,
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
        idleTask?.cancel()
        idleTask = nil
        idleDeadline = nil
        checkpoint()
        startSaveIfPossible()
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
    /// conflict resolves to that tag.
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
                acknowledge(bytes: snapshot.bytes, etag: tag, generation: editGeneration)
            } else {
                reviewedDisk = snapshot
                // The file exists again: that is a conflict against this tag,
                // never a create.
                if status == .deleted { setStatus(.conflict) }
            }
        case .missing:
            reviewedDisk = nil
            if inFlight == nil { setStatus(.deleted) }
        case .failed:
            break
        }
        return outcome
    }

    /// Overwrite disk with the buffer, conditioned on the reviewed disk tag.
    /// Never recreates a deleted file.
    func replaceDiskVersion() {
        guard status == .conflict, inFlight == nil,
              let reviewed = reviewedDisk, let tag = reviewed.etag else { return }
        let bytes = WorkspaceFileTextCodec.encode(currentText)
        guard bytes.count <= maxBytes else {
            setStatus(.tooLarge)
            return
        }
        reviewedDisk = nil
        send(bytes: bytes, generation: editGeneration, ifMatch: tag)
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
            case .missing:
                discardForMissingFile()
                return .missing
            case .failed:
                return .unavailable
            }
        }
        cancelPendingWork()
        guard let tag = snapshot.etag,
              snapshot.bytes.count <= maxBytes,
              let text = WorkspaceFileTextCodec.decode(snapshot.bytes) else {
            draftStore.remove(identity)
            savedGeneration = editGeneration
            setStatus(.failed(String(localized: "This file is no longer editable.")))
            return .notEditable
        }
        bufferText = text
        baseEtag = tag
        diskBytes = snapshot.bytes
        editGeneration &+= 1
        savedGeneration = editGeneration
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

    private func startSaveIfPossible() {
        guard inFlight == nil, !status.stopsAutosave else { return }
        guard hasUnsavedChanges else {
            if status != .saved { setStatus(.saved) }
            return
        }
        let generation = editGeneration
        let bytes = WorkspaceFileTextCodec.encode(currentText)
        if bytes == diskBytes {
            acknowledge(bytes: bytes, etag: baseEtag, generation: generation)
            return
        }
        guard bytes.count <= maxBytes else {
            setStatus(.tooLarge)
            return
        }
        send(bytes: bytes, generation: generation, ifMatch: baseEtag)
    }

    private func send(bytes: Data, generation: Int, ifMatch: String) {
        retryTask?.cancel()
        retryTask = nil
        let flight = InFlight(token: UUID(), epoch: epoch, generation: generation, bytes: bytes)
        inFlight = flight
        setStatus(.saving)
        let transport = transport
        let identity = identity
        inFlightTask = Task { [weak self] in
            let outcome = await transport.write(identity, bytes, ifMatch)
            self?.handleWrite(outcome, for: flight)
        }
    }

    private func handleWrite(_ outcome: WorkspaceFileWriteOutcome, for flight: InFlight) {
        guard inFlight?.token == flight.token else { return }
        inFlight = nil
        inFlightTask = nil
        guard flight.epoch == epoch else { return }
        switch outcome {
        case .saved(let etag):
            acknowledge(bytes: flight.bytes, etag: etag, generation: flight.generation)
        case .stale:
            reviewedDisk = nil
            setStatus(.conflict)
            checkpoint()
        case .missing:
            reviewedDisk = nil
            setStatus(.deleted)
            checkpoint()
        case .rejected(let status, let message):
            setStatus(status == 413 ? .tooLarge : .failed(message))
            checkpoint()
        case .notSent:
            setStatus(.offline)
            checkpoint()
            scheduleRetry()
        case .unknown:
            setStatus(.verifying)
            checkpoint()
            verify(after: flight, delay: nil)
        }
    }

    private func acknowledge(bytes: Data, etag: String, generation: Int) {
        baseEtag = etag
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
            if idleTask == nil { startSaveIfPossible() }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        let delay = retryDelay
        let startEpoch = epoch
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.epoch == startEpoch, self.status == .offline else { return }
            self.retryTask = nil
            self.startSaveIfPossible()
        }
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
                acknowledge(bytes: flight.bytes, etag: tag, generation: flight.generation)
            } else if snapshot.etag == baseEtag {
                setStatus(.pending)
                startSaveIfPossible()
            } else {
                setStatus(.conflict)
                checkpoint()
            }
        case .missing:
            setStatus(.deleted)
            checkpoint()
        case .failed:
            verify(after: flight, delay: retryDelay)
        }
    }

    private func discardForMissingFile() {
        cancelPendingWork()
        draftStore.remove(identity)
        savedGeneration = editGeneration
        reviewedDisk = nil
        setStatus(.deleted)
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
    }

    private func setStatus(_ next: Status) {
        if status != next { status = next }
    }

    private func notifySettledIfNeeded() {
        if isSettled { onSettled?(self) }
    }

#if DEBUG
    var hasInFlightWriteForTesting: Bool { inFlight != nil }
#endif
}
