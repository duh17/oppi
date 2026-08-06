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

    private(set) var mode: Mode = .message

    @ObservationIgnored private weak var store: ComposerDraftStore?
    @ObservationIgnored private var key: ComposerDraftKey?
    @ObservationIgnored private var messagePayload: ComposerDraftPayload
    @ObservationIgnored private var initialSeed: ComposerDraftPayload?
    @ObservationIgnored private var isEphemeral = false
    @ObservationIgnored private var isApplyingVisiblePayload = false

    init(
        initialText: String = "",
        initialRepoPointers: [PendingFileReference] = []
    ) {
        let payload = ComposerDraftPayload(
            text: initialText,
            repoPointers: initialRepoPointers.map(\.composerDraftPointer)
        )
        text = initialText
        repoPointers = initialRepoPointers
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
        if isEphemeral {
            store.clearDraft(for: key)
        } else if !restoredPayload.isEmpty, store.record(for: key)?.payload != restoredPayload {
            store.setDraft(restoredPayload, for: key)
        }

        if mode == .message {
            applyVisiblePayload(restoredPayload)
        }
    }

    func detachForSessionChange() {
        store = nil
        key = nil
        isEphemeral = true
        initialSeed = nil
        messagePayload = .empty
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
        setMode(newMode)
        text = newText
    }

    func replaceMessage(
        text: String,
        repoPointers: [PendingFileReference]? = nil
    ) {
        messagePayload.text = text
        if let repoPointers {
            messagePayload.repoPointers = repoPointers.map(\.composerDraftPointer)
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
        messagePayload = .empty
        if mode == .message {
            applyVisiblePayload(.empty)
        }
        return snapshot
    }

    func completeSubmission(_ snapshot: SubmissionSnapshot) {
        guard !snapshot.wasEphemeral,
              let snapshotKey = snapshot.key,
              let revision = snapshot.revision else {
            return
        }
        store?.clearDraft(for: snapshotKey, ifRevision: revision)
    }

    func failSubmission(_ snapshot: SubmissionSnapshot) {
        guard key == snapshot.key else { return }

        if messagePayload.isEmpty {
            messagePayload = snapshot.payload
            if !isEphemeral,
               let key,
               store?.record(for: key)?.payload != snapshot.payload {
                store?.setDraft(snapshot.payload, for: key)
            }
        } else if messagePayload != snapshot.payload {
            messagePayload = Self.combinedPayload(
                failed: snapshot.payload,
                current: messagePayload
            )
            persistMessagePayload()
        }

        if mode == .message {
            applyVisiblePayload(messagePayload)
        }
    }

    private func persistMessagePayload() {
        guard !isEphemeral, let key, let store else { return }
        if messagePayload.isEmpty {
            store.clearDraft(for: key)
        } else {
            store.setDraft(messagePayload, for: key)
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
        return ComposerDraftPayload(text: combinedText, repoPointers: combinedPointers)
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
