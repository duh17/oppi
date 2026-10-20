import Foundation
import Observation

@MainActor @Observable
final class ChatComposerDraftController {
    enum Mode: Equatable {
        case message
        case ask
        case reviewComment
    }

    enum SubmissionDraftClearance: Equatable {
        case immediately
        case afterSuccess
    }

    struct SubmissionSnapshot {
        let id: UUID
        let store: ComposerDraftStore?
        let key: ComposerDraftKey?
        let payload: ComposerDraftPayload
        let pendingAttachments: [PendingAttachment]
        let revision: UInt64?
        let wasEphemeral: Bool
        let draftClearance: SubmissionDraftClearance
    }

    var text: String {
        didSet {
            if !isApplyingVisiblePayload, mode == .ask, !text.isEmpty {
                lastAskVisibleText = text
            }
            guard !isApplyingVisiblePayload, mode == .message else { return }
            messagePayload.text = text
            persistMessagePayload()
        }
    }

    var repoPointers: [PendingFileReference] {
        didSet {
            guard !isApplyingVisiblePayload, mode == .message else { return }
            messagePayload.repoPointers = repoPointers.map(\.composerDraftPointer)
            persistMessagePayload()
        }
    }

    var pendingAttachments: [PendingAttachment] {
        didSet {
            if isEphemeral, store != nil {
                discardImportedFiles(
                    in: oldValue,
                    retaining: pendingAttachments + (setAside?.attachments ?? []) + dispatchedHiddenAttachments
                )
            }
            guard !isApplyingVisiblePayload, mode == .message else { return }
            messagePayload.attachments = draftAttachmentMetadata
            persistMessagePayload()
        }
    }

    private(set) var mode: Mode = .message
    let mediaImportGate = ComposerMediaImportGate()

    @ObservationIgnored private weak var store: ComposerDraftStore?
    @ObservationIgnored private var key: ComposerDraftKey?
    @ObservationIgnored private var messagePayload: ComposerDraftPayload
    @ObservationIgnored private var initialSeed: ComposerDraftPayload?
    @ObservationIgnored private var isEphemeral = false
    @ObservationIgnored private var isApplyingVisiblePayload = false
    @ObservationIgnored private var lastAskVisibleText = ""
    @ObservationIgnored private var discardedAskSubmissionText: String?
    private(set) var isSubmissionInFlight = false
    @ObservationIgnored private var activeSubmissionID: UUID?
    /// Exact composer text hidden because that send is already in the timeline
    /// or queue. A text-view echo of it must not become a new draft. Cleared on
    /// ack, failure, or any different edit.
    @ObservationIgnored private var dispatchedVisibleClearEcho: String?
    @ObservationIgnored private var dispatchedVisibleClearEchoUntil: Date?
    /// Attachments of a send already in the timeline or queue, hidden from the
    /// composer with its text. The draft keeps them until ack; failure puts
    /// them back, so their imported files stay until the send settles.
    @ObservationIgnored private var dispatchedHiddenAttachments: [PendingAttachment] = []
    /// The message draft set aside while a Live Voice call holds the composer. The store
    /// keeps it, untouched by the call's own typing and sends, so a crash mid-call still
    /// restores it.
    @ObservationIgnored private var setAside: (payload: ComposerDraftPayload, attachments: [PendingAttachment])?
    /// The call ended while a message sent during it awaited the server. Its text is still
    /// the message payload until then, so the draft comes back once that send settles.
    @ObservationIgnored private var restoresSetAsideAfterSubmission = false

    init(
        initialText: String = "",
        initialRepoPointers: [PendingFileReference] = [],
        initialPendingAttachments: [PendingAttachment] = []
    ) {
        let payload = ComposerDraftPayload(
            text: initialText,
            repoPointers: initialRepoPointers.map(\.composerDraftPointer),
            attachments: initialPendingAttachments.map(\.composerDraftMetadata)
        )
        text = initialText
        repoPointers = initialRepoPointers
        pendingAttachments = initialPendingAttachments
        messagePayload = payload
        initialSeed = payload.isEmpty ? nil : payload
    }

    func attach(
        store: ComposerDraftStore,
        key: ComposerDraftKey,
        isEphemeral: Bool
    ) {
        let isSameScope = self.store === store && self.key == key
        if !isSameScope {
            mediaImportGate.invalidate()
        }
        if isSameScope {
            guard self.isEphemeral != isEphemeral else { return }
            self.isEphemeral = isEphemeral
            if isEphemeral {
                store.clearDraft(for: key)
            } else {
                persistMessagePayload()
            }
            return
        }

        let pendingUnscopedPayload = self.key == nil && !messagePayload.isEmpty
            ? messagePayload
            : nil
        let pendingUnscopedAttachments = self.key == nil ? pendingAttachments : []
        self.store = store
        self.key = key
        self.isEphemeral = isEphemeral

        let restoredPayload: ComposerDraftPayload
        if let initialSeed {
            restoredPayload = initialSeed
            self.initialSeed = nil
        } else if let pendingUnscopedPayload {
            restoredPayload = pendingUnscopedPayload
        } else if isEphemeral {
            restoredPayload = .empty
        } else if let record = store.record(for: key) {
            restoredPayload = record.payload
        } else if let migrated = store.consumeLegacyDraft(for: key) {
            restoredPayload = migrated
        } else {
            restoredPayload = .empty
        }

        messagePayload = restoredPayload
        let restoredAttachments: [PendingAttachment]
        if isEphemeral {
            store.clearDraft(for: key)
            restoredAttachments = pendingUnscopedAttachments
        } else if let record = store.record(for: key), record.payload == restoredPayload {
            restoredAttachments = restoredPayload.attachments.compactMap { attachment in
                PendingAttachment(
                    composerDraftAttachment: attachment,
                    data: store.attachmentData(for: key, attachmentID: attachment.id),
                    fileURL: store.attachmentFileURL(for: key, attachmentID: attachment.id)
                )
            }
        } else {
            restoredAttachments = pendingUnscopedAttachments
            if !restoredPayload.isEmpty {
                let normalized = store.setDraft(
                    restoredPayload,
                    attachmentData: Self.attachmentData(from: restoredAttachments),
                    attachmentFiles: Self.attachmentFiles(from: restoredAttachments),
                    for: key
                )
                messagePayload = normalized?.payload ?? restoredPayload
            }
        }
        pendingAttachments = restoredAttachments

        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
    }

    isolated deinit {
        guard isEphemeral else { return }
        discardImportedFiles(pendingAttachments + (setAside?.attachments ?? []) + dispatchedHiddenAttachments)
    }

    /// A Live Voice call starts with an empty field. The draft typed before it waits, and
    /// anything typed during the call is an ordinary message that sends as usual.
    func setAsideMessage() {
        // A new call before the last one's send settled keeps the same draft aside.
        restoresSetAsideAfterSubmission = false
        guard setAside == nil else { return }
        // The set-aside draft takes over an in-flight send's hidden attachments:
        // a failure during the call must not add them to what the call typed.
        setAside = (messagePayload, pendingAttachments + dispatchedHiddenAttachments)
        dispatchedHiddenAttachments = []
        messagePayload = .empty
        isApplyingVisiblePayload = true
        pendingAttachments = []
        isApplyingVisiblePayload = false
        if mode == .message {
            applyVisiblePayload(.empty)
        }
    }

    /// The call ended: the draft from before it comes back, ahead of anything typed during
    /// the call and not sent. A send still in flight settles first: a delivered message must
    /// not come back as part of the draft, and a failed one returns after it.
    func restoreSetAsideMessage() {
        guard let setAside else { return }
        guard activeSubmissionID == nil else {
            restoresSetAsideAfterSubmission = true
            return
        }
        restoresSetAsideAfterSubmission = false
        self.setAside = nil
        let restoredAttachments = Self.combinedAttachments(failed: setAside.attachments, current: pendingAttachments)
        messagePayload = Self.combinedPayload(failed: setAside.payload, current: messagePayload)
        isApplyingVisiblePayload = true
        pendingAttachments = restoredAttachments
        isApplyingVisiblePayload = false
        persistMessagePayload()
        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
    }

    func setMode(
        _ newMode: Mode,
        resetTransientInput: Bool = false
    ) {
        guard mode != newMode else {
            if resetTransientInput, newMode != .message {
                applyVisiblePayload(.empty)
            }
            return
        }
        mode = newMode
        if newMode == .message {
            applyVisiblePayload(messagePayload)
        } else {
            applyVisiblePayload(.empty)
        }
    }

    func updateVisibleText(_ newText: String, for newMode: Mode) {
        if shouldIgnoreDiscardedAskSubmission(newText, for: newMode) {
            if mode != newMode {
                setMode(newMode)
            }
            return
        }
        if shouldIgnoreDispatchedVisibleEcho(newText, for: newMode) {
            return
        }
        if newMode == .message {
            discardedAskSubmissionText = nil
            lastAskVisibleText = ""
            // An empty binding write is the clear itself, not a new draft.
            // Dropping the echo here would let the text view put the sent
            // message back.
            if !newText.isEmpty {
                dispatchedVisibleClearEcho = nil
                dispatchedVisibleClearEchoUntil = nil
            }
        }
        setMode(newMode)
        if newMode == .ask, !newText.isEmpty {
            lastAskVisibleText = newText
        }
        text = newText
    }

    /// Forget a just-submitted or ignored ask answer so a stale composer write
    /// cannot become the restored message draft after the ask card leaves.
    func clearSubmittedAskAnswer() {
        let candidate = text.isEmpty ? lastAskVisibleText : text
        discardedAskSubmissionText = candidate.isEmpty ? nil : candidate
        if mode == .ask {
            applyVisiblePayload(.empty)
        }
    }

    @discardableResult
    func setPendingAttachments(_ attachments: [PendingAttachment]) -> Bool {
        guard mode == .message, !isSubmissionInFlight else {
            discardImportedFiles(in: attachments, retaining: pendingAttachments)
            return false
        }
        pendingAttachments = attachments
        return true
    }

    func replaceMessage(
        text: String,
        repoPointers: [PendingFileReference]? = nil,
        pendingAttachments: [PendingAttachment]? = nil
    ) {
        messagePayload.text = text
        if let repoPointers {
            messagePayload.repoPointers = repoPointers.map(\.composerDraftPointer)
        }
        if let pendingAttachments {
            self.pendingAttachments = pendingAttachments
            messagePayload.attachments = draftAttachmentMetadata
        }
        persistMessagePayload()
        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
    }

    func mutateMessage(_ mutation: (inout String, inout [PendingFileReference]) -> Void) {
        var nextText = messagePayload.text
        var nextRepoPointers = messagePayload.repoPointers.map(PendingFileReference.init(composerDraftPointer:))
        mutation(&nextText, &nextRepoPointers)
        replaceMessage(text: nextText, repoPointers: nextRepoPointers)
    }

    func clearMessage() {
        messagePayload = .empty
        pendingAttachments = []
        persistMessagePayload()
        if mode == .message {
            applyVisiblePayload(.empty)
        }
    }

    func beginSubmission(
        draftClearance: SubmissionDraftClearance
    ) -> SubmissionSnapshot? {
        guard activeSubmissionID == nil else { return nil }

        let submissionID = UUID()
        let revision = key.flatMap { store?.record(for: $0)?.revision }
        let snapshot = SubmissionSnapshot(
            id: submissionID,
            store: store,
            key: key,
            payload: messagePayload,
            pendingAttachments: pendingAttachments,
            revision: revision,
            // A send during a call leaves the stored, set-aside draft alone.
            wasEphemeral: isEphemeral || setAside != nil,
            draftClearance: draftClearance
        )
        activeSubmissionID = submissionID
        isSubmissionInFlight = true
        mediaImportGate.invalidate()

        if draftClearance == .immediately {
            messagePayload = .empty
            persistMessagePayload()
            isApplyingVisiblePayload = true
            pendingAttachments = []
            isApplyingVisiblePayload = false
            if mode == .message {
                applyVisiblePayload(.empty)
            }
        }
        return snapshot
    }

    /// The send is now visible (optimistic user row or queued item). Hide its
    /// text and attachments immediately. The persisted draft stays until ack so
    /// a crash before the frame is acknowledged can still restore it; failure
    /// paints the in-memory snapshot back into the field.
    func clearVisibleDraftForDispatchedSubmission(_ snapshot: SubmissionSnapshot) {
        guard activeSubmissionID == snapshot.id else { return }
        guard snapshot.draftClearance == .afterSuccess, mode == .message else { return }
        guard messagePayload.text == snapshot.payload.text,
              messagePayload.repoPointers == snapshot.payload.repoPointers else {
            return
        }

        let echo = snapshot.payload.text
        if echo.isEmpty {
            dispatchedVisibleClearEcho = nil
            dispatchedVisibleClearEchoUntil = nil
        } else {
            dispatchedVisibleClearEcho = echo
            dispatchedVisibleClearEchoUntil = Date().addingTimeInterval(1)
        }
        applyVisiblePayload(ComposerDraftPayload(
            text: "",
            repoPointers: [],
            attachments: messagePayload.attachments
        ))

        let submittedAttachmentIDs = Set(snapshot.pendingAttachments.map(\.id))
        dispatchedHiddenAttachments = pendingAttachments.filter { submittedAttachmentIDs.contains($0.id) }
        isApplyingVisiblePayload = true
        pendingAttachments.removeAll { submittedAttachmentIDs.contains($0.id) }
        isApplyingVisiblePayload = false
    }

    /// The draft payload's attachments: the field's, plus a dispatched send's
    /// hidden ones until it settles, so an edit during the send (a queue
    /// restore, say) cannot drop them from the crash draft.
    private var draftAttachmentMetadata: [ComposerDraftAttachment] {
        Self.combinedAttachments(failed: dispatchedHiddenAttachments, current: pendingAttachments)
            .map(\.composerDraftMetadata)
    }

    /// Ack: the hidden attachments were sent. Ephemeral drafts delete their
    /// imported files, as they would had the attachments stayed visible.
    private func discardSentHiddenAttachmentFiles(_ sent: [PendingAttachment]) {
        guard isEphemeral, store != nil else { return }
        discardImportedFiles(in: sent, retaining: pendingAttachments + (setAside?.attachments ?? []))
    }

    /// Failure: the hidden attachments go back into the field ahead of any
    /// added since. The draft payload never dropped them.
    private func restoreDispatchedHiddenAttachments() {
        guard !dispatchedHiddenAttachments.isEmpty else { return }
        let restored = Self.combinedAttachments(failed: dispatchedHiddenAttachments, current: pendingAttachments)
        dispatchedHiddenAttachments = []
        isApplyingVisiblePayload = true
        pendingAttachments = restored
        isApplyingVisiblePayload = false
    }

    @discardableResult
    func completeSubmission(_ snapshot: SubmissionSnapshot) -> Bool {
        let ownsActiveSubmission = activeSubmissionID == snapshot.id
        defer { restoreSetAsideIfSettled() }
        let submittedAttachmentIDs = Set(
            snapshot.payload.attachments.map(\.id) + snapshot.pendingAttachments.map(\.id)
        )
        let didClearSubmittedDraft: Bool

        if ownsActiveSubmission {
            activeSubmissionID = nil
            isSubmissionInFlight = false
            dispatchedVisibleClearEcho = nil
            dispatchedVisibleClearEchoUntil = nil
            // Settle the hidden attachments first: clearing the field below must
            // not write them back into the draft payload.
            let sentHidden = dispatchedHiddenAttachments
            dispatchedHiddenAttachments = []
            defer { discardSentHiddenAttachmentFiles(sentHidden) }

            if snapshot.draftClearance == .afterSuccess {
                if messagePayload == snapshot.payload {
                    messagePayload = .empty
                    pendingAttachments = []
                    if mode == .message {
                        applyVisiblePayload(.empty)
                    }
                } else {
                    pendingAttachments.removeAll { submittedAttachmentIDs.contains($0.id) }
                    messagePayload.attachments.removeAll { submittedAttachmentIDs.contains($0.id) }
                }
                persistMessagePayload()
                didClearSubmittedDraft = true
            } else {
                didClearSubmittedDraft = true
            }
        } else {
            didClearSubmittedDraft = false
        }

        // A successful acknowledgement must drop the in-flight attachments even
        // if newer typing changed the payload or revision, and even if
        // navigation detached this controller in the meantime.
        if !snapshot.wasEphemeral,
           let snapshotKey = snapshot.key,
           let store = snapshot.store {
            if snapshot.draftClearance == .afterSuccess {
                Self.removeSubmittedAttachments(
                    submittedAttachmentIDs,
                    matching: snapshot,
                    from: store,
                    key: snapshotKey
                )
            } else if let revision = snapshot.revision {
                store.clearDraft(for: snapshotKey, ifRevision: revision)
            }
        }
        return didClearSubmittedDraft
    }

    private static func removeSubmittedAttachments(
        _ submittedAttachmentIDs: Set<String>,
        matching snapshot: SubmissionSnapshot,
        from store: ComposerDraftStore,
        key: ComposerDraftKey
    ) {
        guard let current = store.record(for: key) else { return }
        if current.payload == snapshot.payload || current.revision == snapshot.revision {
            store.clearDraft(for: key)
            return
        }
        guard current.payload.attachments.contains(where: { submittedAttachmentIDs.contains($0.id) }) else {
            return
        }
        var remaining = current.payload
        remaining.attachments.removeAll { submittedAttachmentIDs.contains($0.id) }
        if remaining.isEmpty {
            store.clearDraft(for: key)
        } else {
            _ = store.setDraft(remaining, for: key)
        }
    }

    func failSubmission(_ snapshot: SubmissionSnapshot) {
        guard activeSubmissionID == snapshot.id, key == snapshot.key else { return }
        defer { restoreSetAsideIfSettled() }
        activeSubmissionID = nil
        isSubmissionInFlight = false
        dispatchedVisibleClearEcho = nil
        dispatchedVisibleClearEchoUntil = nil
        restoreDispatchedHiddenAttachments()

        if snapshot.draftClearance == .afterSuccess {
            if messagePayload.isEmpty {
                messagePayload = snapshot.payload
                pendingAttachments = snapshot.pendingAttachments
            }
            if !isEphemeral,
               let key,
               store?.record(for: key)?.payload != messagePayload {
                persistMessagePayload()
            }
            if mode == .message {
                applyVisiblePayload(messagePayload)
            }
            return
        }

        if messagePayload.isEmpty {
            messagePayload = snapshot.payload
            pendingAttachments = snapshot.pendingAttachments
            if !isEphemeral,
               let key,
               store?.record(for: key)?.payload != snapshot.payload {
                persistMessagePayload()
            }
        } else if messagePayload != snapshot.payload {
            messagePayload = Self.combinedPayload(
                failed: snapshot.payload,
                current: messagePayload
            )
            pendingAttachments = Self.combinedAttachments(
                failed: snapshot.pendingAttachments,
                current: pendingAttachments
            )
            persistMessagePayload()
        }

        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
    }

    private func restoreSetAsideIfSettled() {
        guard restoresSetAsideAfterSubmission, activeSubmissionID == nil else { return }
        restoreSetAsideMessage()
    }

    private func shouldIgnoreDispatchedVisibleEcho(_ newText: String, for newMode: Mode) -> Bool {
        guard newMode == .message,
              text.isEmpty,
              let echo = dispatchedVisibleClearEcho,
              let until = dispatchedVisibleClearEchoUntil,
              Date() < until,
              !echo.isEmpty,
              newText == echo else {
            return false
        }
        return true
    }

    private func shouldIgnoreDiscardedAskSubmission(_ newText: String, for newMode: Mode) -> Bool {
        guard newMode == .message,
              let discarded = discardedAskSubmissionText,
              !discarded.isEmpty else {
            return false
        }
        return newText == discarded
    }

    private func persistMessagePayload() {
        guard !isEphemeral, setAside == nil, let key, let store else { return }
        if messagePayload.isEmpty {
            store.clearDraft(for: key)
        } else {
            let draftAttachments = pendingAttachments + dispatchedHiddenAttachments
            let record = store.setDraft(
                messagePayload,
                attachmentData: Self.attachmentData(from: draftAttachments),
                attachmentFiles: Self.attachmentFiles(from: draftAttachments),
                for: key
            )
            if let record {
                messagePayload = record.payload
            }
        }
    }

    private static func attachmentData(from attachments: [PendingAttachment]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: attachments.compactMap { attachment in
            guard let data = attachment.composerDraftData else { return nil }
            return (attachment.id, data)
        })
    }

    private static func attachmentFiles(from attachments: [PendingAttachment]) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: attachments.compactMap { attachment in
            guard let url = attachment.composerDraftFileURL else { return nil }
            return (attachment.id, url)
        })
    }

    private func discardImportedFiles(_ attachments: [PendingAttachment]) {
        discardImportedFiles(in: attachments, retaining: [])
    }

    private func discardImportedFiles(
        in previous: [PendingAttachment],
        retaining next: [PendingAttachment]
    ) {
        let retained = Set(next.compactMap { $0.composerDraftFileURL?.standardizedFileURL.path })
        for attachment in previous {
            guard let url = attachment.composerDraftFileURL else { continue }
            if !retained.contains(url.standardizedFileURL.path) {
                store?.deleteImportedAttachmentFile(url)
            }
        }
    }

    private func applyVisiblePayload(_ payload: ComposerDraftPayload) {
        isApplyingVisiblePayload = true
        text = payload.text
        repoPointers = payload.repoPointers.map(PendingFileReference.init(composerDraftPointer:))
        isApplyingVisiblePayload = false
    }

    private static func combinedPayload(
        failed: ComposerDraftPayload,
        current: ComposerDraftPayload
    ) -> ComposerDraftPayload {
        let combinedText: String
        if failed.text.isEmpty || failed.text == current.text {
            combinedText = current.text
        } else if current.text.isEmpty {
            combinedText = failed.text
        } else {
            combinedText = failed.text + "\n\n" + current.text
        }

        var seenPointers = Set<String>()
        let combinedPointers = (failed.repoPointers + current.repoPointers).filter { pointer in
            seenPointers.insert("\(pointer.kind.rawValue):\(pointer.path)").inserted
        }
        var seenAttachments = Set<String>()
        let combinedAttachments = (failed.attachments + current.attachments).filter {
            seenAttachments.insert($0.id).inserted
        }
        return ComposerDraftPayload(
            text: combinedText,
            repoPointers: combinedPointers,
            attachments: combinedAttachments
        )
    }

    private static func combinedAttachments(
        failed: [PendingAttachment],
        current: [PendingAttachment]
    ) -> [PendingAttachment] {
        var seen = Set<String>()
        return (failed + current).filter { seen.insert($0.id).inserted }
    }
}
