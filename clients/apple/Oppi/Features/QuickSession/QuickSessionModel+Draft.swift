import UIKit

func quickSessionText(_ existingText: String, appending incomingText: String?) -> String {
    guard let incomingText = incomingText?.trimmingCharacters(in: .whitespacesAndNewlines),
          !incomingText.isEmpty else { return existingText }
    if existingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return incomingText
    }
    return existingText + "\n" + incomingText
}

/// Quick Session's one saved draft: loaded as it opens, saved on every edit
/// (and once more on dismissal, by `QuickSessionPresentation`), cleared by a
/// launch that sent it.
extension QuickSessionModel {
    // MARK: Edits

    /// The composer changed the text: typing, dictation, a slash command or
    /// file mention, the expanded composer.
    func editText(_ value: String) {
        guard value != text else { return }
        text = value
        persistQuickSessionDraft()
    }

    /// The composer added, removed, or replaced an attachment.
    func editAttachments(_ value: [PendingAttachment]) {
        pendingAttachments = value
        persistQuickSessionDraft()
    }

    /// The composer added or removed a file reference.
    func editRepoPointers(_ value: [PendingFileReference]) {
        pendingRepoPointers = value
        persistQuickSessionDraft()
    }

    // MARK: Loads and restores

    /// The saved draft into the composer. It is already saved: nothing is written.
    func loadStoredDraft() {
        guard let composerDraftStore else { return }
        let payload = composerDraftStore.quickSessionDraftPayload
        text = payload.text
        pendingRepoPointers = payload.repoPointers.map(PendingFileReference.init(composerDraftPointer:))
        let attachmentData = composerDraftStore.quickSessionDraftAttachmentData()
        pendingAttachments = payload.attachments.compactMap { attachment in
            PendingAttachment(
                composerDraftAttachment: attachment,
                data: attachmentData[attachment.id],
                fileURL: composerDraftStore.quickSessionDraftAttachmentFileURL(attachmentID: attachment.id)
            )
        }
    }

    /// A Live Voice start that stopped with an error leaves an ordinary Quick Session: the
    /// stored draft comes back ahead of the start's own text and saves again from here on.
    func restoreStoredDraftAfterLiveVoiceStart() {
        // An Agent launch that may have reached the server keeps its composer as is, so a
        // retry reuses the same launch key and resumes that session instead of making a
        // second one. The stored draft stays saved, untouched, meanwhile.
        guard keepsStoredDraft, agentSubmitAttempt == nil else { return }
        keepsStoredDraft = false
        guard let composerDraftStore else { return }
        let stored = composerDraftStore.quickSessionDraftPayload
        let attachmentData = composerDraftStore.quickSessionDraftAttachmentData()
        let storedAttachments = stored.attachments.compactMap { attachment in
            PendingAttachment(
                composerDraftAttachment: attachment,
                data: attachmentData[attachment.id],
                fileURL: composerDraftStore.quickSessionDraftAttachmentFileURL(attachmentID: attachment.id)
            )
        }
        text = quickSessionText(stored.text, appending: text)
        pendingRepoPointers = stored.repoPointers.map(PendingFileReference.init(composerDraftPointer:))
            + pendingRepoPointers
        pendingAttachments = storedAttachments + pendingAttachments
        persistQuickSessionDraft()
    }

    /// Text and files a start brings (Shortcuts, App Intents), after the draft.
    func applyInitialPayload(_ payload: QuickSessionInitialPayload) {
        text = quickSessionText(text, appending: payload.text)
        for attachment in payload.attachments {
            appendInitialAttachment(
                name: attachment.name,
                data: attachment.data,
                mimeType: attachment.mimeType
            )
        }
        persistQuickSessionDraft()
    }

    private func appendInitialAttachment(name: String, data: Data, mimeType: String) {
        if mimeType.hasPrefix("image/"), let image = UIImage(data: data) {
            pendingAttachments.append(PendingImage.from(data: data, mimeType: mimeType, image: image).pendingAttachment)
        } else {
            pendingAttachments.append(PendingAttachment.localFile(
                name: name,
                data: data,
                mimeType: mimeType
            ))
        }
    }

    var currentDraftPayload: ComposerDraftPayload {
        ComposerDraftPayload(
            text: text,
            repoPointers: pendingRepoPointers.map(\.composerDraftPointer),
            attachments: pendingAttachments.map(\.composerDraftMetadata)
        )
    }

    @discardableResult
    func persistQuickSessionDraft() -> ComposerDraftRecord? {
        guard !keepsStoredDraft else { return nil }
        let payload = currentDraftPayload
        // A text view echo while the sheet closes would resurrect the sent message.
        if let launchedDraftPayload, launchedDraftPayload == payload { return nil }
        let data: [String: Data] = Dictionary(uniqueKeysWithValues: pendingAttachments.compactMap { attachment -> (String, Data)? in
            guard let data = attachment.composerDraftData else { return nil }
            return (attachment.id, data)
        })
        let files: [String: URL] = Dictionary(uniqueKeysWithValues: pendingAttachments.compactMap { attachment -> (String, URL)? in
            guard let url = attachment.composerDraftFileURL else { return nil }
            return (attachment.id, url)
        })
        return composerDraftStore?.setQuickSessionDraft(payload, attachmentData: data, attachmentFiles: files)
    }
}
