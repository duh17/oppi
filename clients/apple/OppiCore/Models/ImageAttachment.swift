import Foundation

/// Local base64 image blob used for pending/optimistic UI rendering and old trace display.
///
/// This type is intentionally not part of the chat send protocol. Composer sends
/// images by uploading them first and carrying `ChatAttachmentRef` values over the wire.
struct ImageAttachment: Codable, Sendable, Equatable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.
}
