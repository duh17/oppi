import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Local base64 image blob used for pending/optimistic UI rendering and old trace display.
///
/// This type is intentionally not part of the chat send protocol. Composer sends
/// images by uploading them first and carrying `ChatAttachmentRef` values over the wire.
struct ImageAttachment: Codable, Sendable, Equatable {
    let data: String      // base64
    let mimeType: String  // image/jpeg, image/png, etc.

#if canImport(UIKit)
    // periphery:ignore - API surface for image attachment display in UI
    /// Decode base64 data to UIImage for display.
    var decodedImage: UIImage? {
        guard let imageData = Data(base64Encoded: data) else { return nil }
        return UIImage(data: imageData)
    }
#endif
}
