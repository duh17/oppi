import Foundation
import Synchronization

/// Where one attachment's upload stands. The uploader reports each change from
/// the URLSession task's own byte counts.
struct AttachmentUploadProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case uploading
        /// The connection dropped; the file starts over after a short wait.
        case retrying(attempt: Int, maxAttempts: Int, reason: String)
        case uploaded
        case failed(String)
    }

    let attachmentId: String
    let name: String
    var sentBytes: Int64
    var totalBytes: Int64
    var phase: Phase
}

/// An upload that failed for good, after its retries, with the reason in words.
struct AttachmentUploadError: LocalizedError, Equatable {
    let attachmentId: String
    let name: String
    let reason: String
    let attempts: Int

    var errorDescription: String? {
        attempts > 1
            ? "Couldn't upload \(name) after \(attempts) tries: \(reason)"
            : "Couldn't upload \(name): \(reason)"
    }
}

/// Uploads composer-local attachments after a session exists and before a turn is sent.
enum PendingAttachmentUploader {
    /// One try plus this many retries when the connection drops.
    static let maxAttempts = 5
    /// Waits before each retry: long enough to ride out a route change or a server restart.
    static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]

    /// `api` resolves the server's client for each try, so a retry after a route
    /// change (LAN to Tailscale, a new address) uses the current route.
    @MainActor
    static func upload(
        _ sourceAttachments: [PendingAttachment],
        api: @escaping @MainActor () -> APIClient?,
        scope: SessionRouteScope,
        sessionId: String,
        onProgress: (@MainActor (AttachmentUploadProgress) -> Void)? = nil,
        onUploaded: (@MainActor (_ attachmentId: String, ChatAttachmentRef) -> Void)? = nil
    ) async throws -> [ChatAttachmentRef] {
        let localAttachments = sourceAttachments.filter {
            $0.source == .image || $0.source == .localFile
        }
        guard !sourceAttachments.isEmpty else { return [] }

        let imageAutoResize: Bool
        if localAttachments.contains(where: { $0.source == .image }), let client = api() {
            imageAutoResize = await imageAutoResizeEnabled(api: client)
        } else {
            imageAutoResize = true
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
            let body = try await uploadBody(for: pending, index: uploadIndex, imageAutoResize: imageAutoResize)
            var progress = AttachmentUploadProgress(
                attachmentId: pending.id,
                name: body.name,
                sentBytes: 0,
                totalBytes: Int64(body.sizeBytes),
                phase: .uploading
            )
            onProgress?(progress)
            let attachment = try await uploadWithRetries(
                body,
                progress: &progress,
                api: api,
                scope: scope,
                sessionId: sessionId,
                onProgress: onProgress
            )
            progress.sentBytes = progress.totalBytes
            progress.phase = .uploaded
            onProgress?(progress)
            onUploaded?(pending.id, attachment)
            uploaded.append(attachment)
        }
        return uploaded
    }

    /// The same, against one client for every try.
    @MainActor
    static func upload(
        _ sourceAttachments: [PendingAttachment],
        api client: APIClient,
        scope: SessionRouteScope,
        sessionId: String,
        onProgress: (@MainActor (AttachmentUploadProgress) -> Void)? = nil
    ) async throws -> [ChatAttachmentRef] {
        try await upload(sourceAttachments, api: { client }, scope: scope, sessionId: sessionId, onProgress: onProgress)
    }

    struct UploadBody: Sendable {
        enum Content: Sendable {
            case data(Data)
            /// Streamed from disk; never read into memory.
            case file(URL)
        }

        let name: String
        let mimeType: String
        let sizeBytes: Int
        let content: Content
    }

    @MainActor
    private static func uploadBody(
        for pending: PendingAttachment,
        index: Int,
        imageAutoResize: Bool
    ) async throws -> UploadBody {
        switch pending.source {
        case .image:
            guard let imageAttachment = pending.imageAttachment else {
                throw APIError.server(status: 400, message: "Invalid pending image data")
            }
            // Decoding, resizing, and re-encoding a full-size screenshot takes
            // long enough to hitch the composer on the main actor.
            let prepared = await Task.detached(priority: .userInitiated) {
                let upload = PendingImage.uploadAttachment(from: imageAttachment, autoResize: imageAutoResize)
                return Data(base64Encoded: upload.data, options: .ignoreUnknownCharacters)
                    .map { (data: $0, mimeType: upload.mimeType) }
            }.value
            guard let prepared else {
                throw APIError.server(status: 400, message: "Invalid pending image data")
            }
            return UploadBody(
                name: imageUploadName(displayName: pending.displayName, mimeType: prepared.mimeType, index: index - 1),
                mimeType: prepared.mimeType,
                sizeBytes: prepared.data.count,
                content: .data(prepared.data)
            )
        case .localFile:
            guard let mimeType = pending.localMimeType else {
                throw APIError.server(status: 400, message: "Invalid pending file data")
            }
            if let fileURL = pending.localFileURL {
                let sizeBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? pending.localFileSizeBytes
                    ?? 0
                return UploadBody(name: pending.displayName, mimeType: mimeType, sizeBytes: sizeBytes, content: .file(fileURL))
            }
            if let data = pending.localFileData {
                return UploadBody(name: pending.displayName, mimeType: mimeType, sizeBytes: data.count, content: .data(data))
            }
            throw APIError.server(status: 400, message: "Invalid pending file data")
        case .uploaded:
            throw APIError.server(status: 400, message: "Attachment is already uploaded")
        }
    }

    /// Creates the upload and sends its bytes. A dropped connection starts that
    /// file over as a new upload (the server discards the cut one), up to
    /// `maxAttempts` tries; anything else, or the last try, fails with the reason.
    @MainActor
    private static func uploadWithRetries(
        _ body: UploadBody,
        progress: inout AttachmentUploadProgress,
        api: @MainActor () -> APIClient?,
        scope: SessionRouteScope,
        sessionId: String,
        onProgress: (@MainActor (AttachmentUploadProgress) -> Void)?
    ) async throws -> ChatAttachmentRef {
        var attempt = 1
        while true {
            do {
                guard let client = api() else {
                    throw APIError.server(status: 503, message: "No server connection available")
                }
                let snapshot = progress
                let throttle = ProgressThrottle()
                // Byte counts hop to the main actor; one that lands after this try
                // ended must not overwrite its outcome.
                defer { throttle.close() }
                let report = onProgress.map { reporter(from: snapshot, throttle: throttle, onProgress: $0) }
                return try await uploadOnce(body, client: client, scope: scope, sessionId: sessionId, progress: report)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                let reason = failureReason(error)
                guard attempt < maxAttempts, isTransient(error) else {
                    progress.phase = .failed(reason)
                    onProgress?(progress)
                    throw AttachmentUploadError(
                        attachmentId: progress.attachmentId,
                        name: body.name,
                        reason: reason,
                        attempts: attempt
                    )
                }
                attempt += 1
                progress.sentBytes = 0
                progress.phase = .retrying(attempt: attempt, maxAttempts: maxAttempts, reason: reason)
                onProgress?(progress)
                try await Task.sleep(for: retryDelays[min(attempt - 2, retryDelays.count - 1)])
                progress.phase = .uploading
                onProgress?(progress)
            }
        }
    }

    private static func reporter(
        from snapshot: AttachmentUploadProgress,
        throttle: ProgressThrottle,
        onProgress: @escaping @MainActor (AttachmentUploadProgress) -> Void
    ) -> AttachmentUploadTransport.Progress {
        { (sent: Int64, total: Int64) in
            guard throttle.shouldReport(sent: sent, total: total) else { return }
            Task { @MainActor in
                guard throttle.isOpen else { return }
                var update = snapshot
                update.sentBytes = sent
                if total > 0 { update.totalBytes = total }
                update.phase = .uploading
                onProgress(update)
            }
        }
    }

    private static func uploadOnce(
        _ body: UploadBody,
        client: APIClient,
        scope: SessionRouteScope,
        sessionId: String,
        progress: AttachmentUploadTransport.Progress?
    ) async throws -> ChatAttachmentRef {
        let upload = try await client.createSessionAttachmentUpload(
            scope: scope,
            sessionId: sessionId,
            name: body.name,
            mimeType: body.mimeType,
            sizeBytes: body.sizeBytes
        )
        switch body.content {
        case .data(let data):
            return try await client.uploadSessionAttachmentContent(
                scope: scope,
                sessionId: sessionId,
                attachmentId: upload.uploadId,
                data: data,
                contentType: body.mimeType,
                progress: progress
            )
        case .file(let fileURL):
            return try await client.uploadSessionAttachmentContent(
                scope: scope,
                sessionId: sessionId,
                attachmentId: upload.uploadId,
                fileURL: fileURL,
                contentType: body.mimeType,
                progress: progress
            )
        }
    }

    /// A dropped or refused connection, a stall, or the server briefly away
    /// (restarting, a gateway between). Not a refusal the server meant (auth,
    /// size, space, type), which a retry would only repeat.
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected,
                 .secureConnectionFailed, .badServerResponse:
                return true
            default:
                return false
            }
        }
        if case let APIError.server(status, _) = error {
            return [408, 502, 503, 504].contains(status)
        }
        return false
    }

    private static func failureReason(_ error: Error) -> String {
        if case let APIError.server(status, message) = error {
            if status == 404, message.isEmpty { return "this server does not support attachment uploads" }
            return message.isEmpty ? "the server answered \(status)" : message
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "no data moved for two minutes"
            case .networkConnectionLost: return "the connection dropped"
            case .notConnectedToInternet: return "this device is offline"
            case .cannotConnectToHost, .cannotFindHost: return "the server can't be reached"
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Missing or unreadable server info falls back to the server default (`true`).
    private static func imageAutoResizeEnabled(api: APIClient) async -> Bool {
        (try? await api.serverInfo().images?.autoResize) ?? true
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

/// URLSession reports sent bytes many times a second; the composer needs a
/// change it can see: each whole percent, and the last byte.
private final class ProgressThrottle: Sendable {
    private let lastPercent = Mutex<Int>(-1)
    private let open = Mutex(true)

    var isOpen: Bool { open.withLock { $0 } }

    func close() {
        open.withLock { $0 = false }
    }

    func shouldReport(sent: Int64, total: Int64) -> Bool {
        guard total > 0 else { return true }
        let percent = Int(sent * 100 / total)
        return lastPercent.withLock { last in
            guard percent != last else { return false }
            last = percent
            return true
        }
    }
}
