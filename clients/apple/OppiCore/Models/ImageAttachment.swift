import Foundation

/// One image on a user message row.
///
/// An optimistic row (a just-sent photo) carries its bytes in `data`. A committed user message
/// carries a stored attachment reference instead: `attachmentId` names bytes in the session
/// attachment store, which the row fetches when it becomes visible, and `data` is empty. Older
/// servers that do not store user images, and images they could not store, still send base64.
struct ImageAttachment: Codable, Sendable, Equatable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.
    /// Stored session attachment to fetch instead of `data`.
    let attachmentId: String?
    /// The session whose attachment store holds `attachmentId`, when the server names it.
    let attachmentSessionId: String?
    let fileName: String?
    let sizeBytes: Int?
    /// Pixel size of the stored image, so the row reserves layout before the bytes arrive.
    let width: Int?
    let height: Int?

    init(
        data: String,
        mimeType: String,
        attachmentId: String? = nil,
        attachmentSessionId: String? = nil,
        fileName: String? = nil,
        sizeBytes: Int? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.attachmentId = attachmentId
        self.attachmentSessionId = attachmentSessionId
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
    }

    /// True when the bytes live in the session attachment store, not in `data`.
    var storedAttachmentID: String? {
        guard let attachmentId, !attachmentId.isEmpty else { return nil }
        return attachmentId
    }

    /// Width over height from the reference, when the server reported both.
    var aspectRatio: CGFloat? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGFloat(width) / CGFloat(height)
    }
}
