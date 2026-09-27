import Foundation

/// Uploads composer-local attachments after a session exists and before a turn is sent.
enum PendingAttachmentUploader {
    @MainActor
    static func upload(
        _ sourceAttachments: [PendingAttachment],
        api: APIClient,
        scope: SessionRouteScope,
        sessionId: String,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> [ChatAttachmentRef] {
        let localAttachments = sourceAttachments.filter {
            $0.source == .image || $0.source == .localFile
        }
        guard !sourceAttachments.isEmpty else { return [] }

        let imageAutoResize: Bool
        if localAttachments.contains(where: { $0.source == .image }) {
            imageAutoResize = await imageAutoResizeEnabled(api: api)
        } else {
            imageAutoResize = false
        }

        var uploaded: [ChatAttachmentRef] = []
        var uploadIndex = 0
        for pending in sourceAttachments {
            if case .uploaded = pending.source {
                if let reference = pending.uploadedReference {
                    uploaded.append(reference)
                }
                continue
            }

            uploadIndex += 1
            onProgress?("Uploading attachment \(uploadIndex) of \(localAttachments.count)…")

            let attachment: ChatAttachmentRef
            switch pending.source {
            case .image:
                guard let imageAttachment = pending.imageAttachment else {
                    throw APIError.server(status: 400, message: "Invalid pending image data")
                }
                let uploadAttachment = PendingImage.uploadAttachment(
                    from: imageAttachment,
                    autoResize: imageAutoResize
                )
                guard let data = Data(
                    base64Encoded: uploadAttachment.data,
                    options: .ignoreUnknownCharacters
                ) else {
                    throw APIError.server(status: 400, message: "Invalid pending image data")
                }
                let name = imageUploadName(
                    displayName: pending.displayName,
                    mimeType: uploadAttachment.mimeType,
                    index: uploadIndex - 1
                )
                attachment = try await uploadData(
                    data,
                    name: name,
                    mimeType: uploadAttachment.mimeType,
                    api: api,
                    scope: scope,
                    sessionId: sessionId
                )
            case .localFile:
                guard let mimeType = pending.localMimeType else {
                    throw APIError.server(status: 400, message: "Invalid pending file data")
                }
                if let fileURL = pending.localFileURL {
                    let sizeBytes = pending.localFileSizeBytes
                        ?? (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        ?? 0
                    let upload = try await api.createSessionAttachmentUpload(
                        scope: scope,
                        sessionId: sessionId,
                        name: pending.displayName,
                        mimeType: mimeType,
                        sizeBytes: sizeBytes
                    )
                    attachment = try await api.uploadSessionAttachmentContent(
                        scope: scope,
                        sessionId: sessionId,
                        attachmentId: upload.uploadId,
                        fileURL: fileURL,
                        contentType: mimeType
                    )
                } else if let data = pending.localFileData {
                    attachment = try await uploadData(
                        data,
                        name: pending.displayName,
                        mimeType: mimeType,
                        api: api,
                        scope: scope,
                        sessionId: sessionId
                    )
                } else {
                    throw APIError.server(status: 400, message: "Invalid pending file data")
                }
            case .uploaded:
                continue
            }
            uploaded.append(attachment)
        }
        return uploaded
    }

    private static func uploadData(
        _ data: Data,
        name: String,
        mimeType: String,
        api: APIClient,
        scope: SessionRouteScope,
        sessionId: String
    ) async throws -> ChatAttachmentRef {
        let upload = try await api.createSessionAttachmentUpload(
            scope: scope,
            sessionId: sessionId,
            name: name,
            mimeType: mimeType,
            sizeBytes: data.count
        )
        return try await api.uploadSessionAttachmentContent(
            scope: scope,
            sessionId: sessionId,
            attachmentId: upload.uploadId,
            data: data,
            contentType: mimeType
        )
    }

    private static func imageAutoResizeEnabled(api: APIClient) async -> Bool {
        do {
            return try await api.serverInfo().images?.autoResize ?? false
        } catch {
            return false
        }
    }

    private static func imageUploadName(
        displayName: String,
        mimeType: String,
        index: Int
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileExtension = imageUploadFileExtension(for: mimeType)
        if !trimmed.isEmpty, trimmed.lowercased().hasSuffix(".\(fileExtension)") {
            return trimmed
        }
        return "image-\(index + 1).\(fileExtension)"
    }

    private static func imageUploadFileExtension(for mimeType: String) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1).first?.lowercased() {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/jpeg", "image/jpg": return "jpg"
        default: return "jpg"
        }
    }
}
