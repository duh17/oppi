import Foundation
import Observation

@MainActor @Observable
final class ChatComposerDraftController {
    enum Mode: Equatable {
        case message
        case ask
        case reviewComment
    }

    struct SubmissionSnapshot: Equatable {
        let key: ComposerDraftKey?
        let payload: ComposerDraftPayload
        let revision: UInt64?
        let wasEphemeral: Bool
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
            guard !isApplyingVisiblePayload, mode == .message else { return }
            messagePayload.attachments = pendingAttachments.map(\.composerDraftMetadata)
            persistMessagePayload()
        }
    }

    private(set) var mode: Mode = .message

    @ObservationIgnored private weak var store: ComposerDraftStore?
    @ObservationIgnored private var key: ComposerDraftKey?
    @ObservationIgnored private var messagePayload: ComposerDraftPayload
    @ObservationIgnored private var initialSeed: ComposerDraftPayload?
    @ObservationIgnored private var isEphemeral = false
    @ObservationIgnored private var isApplyingVisiblePayload = false
    @ObservationIgnored private var lastAskVisibleText = ""
    @ObservationIgnored private var discardedAskSubmissionText: String?
    @ObservationIgnored private var isSubmissionInFlight = false

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
                    data: store.attachmentData(for: key, attachmentID: attachment.id)
                )
            }
        } else {
            restoredAttachments = pendingUnscopedAttachments
            if !restoredPayload.isEmpty {
                let normalized = store.setDraft(
                    restoredPayload,
                    attachmentData: Dictionary(uniqueKeysWithValues: restoredAttachments.compactMap {
                        guard let data = $0.composerDraftData else { return nil }
                        return ($0.id, data)
                    }),
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

    func detachForSessionChange() {
        store = nil
        key = nil
        isEphemeral = true
        initialSeed = nil
        messagePayload = .empty
        pendingAttachments = []
        lastAskVisibleText = ""
        discardedAskSubmissionText = nil
        isSubmissionInFlight = false
        mode = .message
        applyVisiblePayload(.empty)
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
        if newMode == .message {
            discardedAskSubmissionText = nil
            lastAskVisibleText = ""
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

    func setPendingAttachments(_ attachments: [PendingAttachment]) {
        guard mode == .message else { return }
        guard !(isSubmissionInFlight && messagePayload.isEmpty && attachments.isEmpty) else { return }
        pendingAttachments = attachments
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
            messagePayload.attachments = pendingAttachments.map(\.composerDraftMetadata)
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

    func beginSubmission() -> SubmissionSnapshot {
        let revision = key.flatMap { store?.record(for: $0)?.revision }
        let snapshot = SubmissionSnapshot(
            key: key,
            payload: messagePayload,
            revision: revision,
            wasEphemeral: isEphemeral
        )
        isSubmissionInFlight = true
        messagePayload = .empty
        isApplyingVisiblePayload = true
        pendingAttachments = []
        isApplyingVisiblePayload = false
        if mode == .message {
            applyVisiblePayload(.empty)
        }
        return snapshot
    }

    func completeSubmission(_ snapshot: SubmissionSnapshot) {
        isSubmissionInFlight = false
        guard !snapshot.wasEphemeral,
              let snapshotKey = snapshot.key,
              let revision = snapshot.revision else {
            return
        }
        store?.clearDraft(for: snapshotKey, ifRevision: revision)
    }

    func failSubmission(_ snapshot: SubmissionSnapshot) {
        guard key == snapshot.key else { return }
        isSubmissionInFlight = false

        if messagePayload.isEmpty {
            messagePayload = snapshot.payload
            pendingAttachments = snapshot.payload.attachments.compactMap { attachment in
                guard let key else { return nil }
                return PendingAttachment(
                    composerDraftAttachment: attachment,
                    data: store?.attachmentData(for: key, attachmentID: attachment.id)
                )
            }
            if !isEphemeral,
               let key,
               store?.record(for: key)?.payload != snapshot.payload {
                store?.setDraft(
                    snapshot.payload,
                    attachmentData: Dictionary(uniqueKeysWithValues: pendingAttachments.compactMap { attachment -> (String, Data)? in
                        guard let data = attachment.composerDraftData else { return nil }
                        return (attachment.id, data)
                    }),
                    for: key
                )
            }
        } else if messagePayload != snapshot.payload {
            messagePayload = Self.combinedPayload(
                failed: snapshot.payload,
                current: messagePayload
            )
            let failedAttachments = snapshot.payload.attachments.compactMap { attachment -> PendingAttachment? in
                guard let key else { return nil }
                return PendingAttachment(
                    composerDraftAttachment: attachment,
                    data: store?.attachmentData(for: key, attachmentID: attachment.id)
                )
            }
            pendingAttachments = Self.combinedAttachments(
                failed: failedAttachments,
                current: pendingAttachments
            )
            persistMessagePayload()
        }

        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
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
        guard !isEphemeral, let key, let store else { return }
        if messagePayload.isEmpty {
            store.clearDraft(for: key)
        } else {
            let record = store.setDraft(
                messagePayload,
                attachmentData: Dictionary(uniqueKeysWithValues: pendingAttachments.compactMap { attachment -> (String, Data)? in
                    guard let data = attachment.composerDraftData else { return nil }
                    return (attachment.id, data)
                }),
                for: key
            )
            if let record {
                messagePayload = record.payload
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

private extension PendingFileReference {
    var composerDraftPointer: ComposerDraftRepoPointer {
        let draftKind: ComposerDraftRepoPointer.Kind
        switch kind {
        case .workspaceFile:
            draftKind = .workspaceFile
        case .reviewFile:
            draftKind = .reviewFile
        }

        return ComposerDraftRepoPointer(
            path: path,
            isDirectory: isDirectory,
            kind: draftKind,
            displayPrefix: displayPrefix
        )
    }

    init(composerDraftPointer: ComposerDraftRepoPointer) {
        let referenceKind: PendingFileReferenceKind
        switch composerDraftPointer.kind {
        case .workspaceFile:
            referenceKind = .workspaceFile
        case .reviewFile:
            referenceKind = .reviewFile
        }

        self.init(
            path: composerDraftPointer.path,
            isDirectory: composerDraftPointer.isDirectory,
            kind: referenceKind,
            displayPrefix: composerDraftPointer.displayPrefix
        )
    }
}
