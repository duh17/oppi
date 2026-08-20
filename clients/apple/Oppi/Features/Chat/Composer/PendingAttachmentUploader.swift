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

            let payload: (data: Data, mimeType: String, name: String)
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
                payload = (
                    data,
                    uploadAttachment.mimeType,
                    imageUploadName(
                        displayName: pending.displayName,
                        mimeType: uploadAttachment.mimeType,
                        index: uploadIndex - 1
                    )
                )
            case .localFile:
                guard let data = pending.localFileData,
                      let mimeType = pending.localMimeType else {
                    throw APIError.server(status: 400, message: "Invalid pending file data")
                }
                payload = (data, mimeType, pending.displayName)
            case .uploaded:
                continue
            }

            let upload = try await api.createSessionAttachmentUpload(
                scope: scope,
                sessionId: sessionId,
                name: payload.name,
                mimeType: payload.mimeType,
                sizeBytes: payload.data.count
            )
            let attachment = try await api.uploadSessionAttachmentContent(
                scope: scope,
                sessionId: sessionId,
                attachmentId: upload.uploadId,
                data: payload.data,
                contentType: payload.mimeType
            )
            uploaded.append(attachment)
        }
        return uploaded
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
