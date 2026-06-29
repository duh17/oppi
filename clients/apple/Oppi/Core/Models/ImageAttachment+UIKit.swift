#if canImport(UIKit)
import Foundation
import UIKit

extension ImageAttachment {
    // periphery:ignore - API surface for image attachment display in UI
    /// Decode base64 data to UIImage for display.
    var decodedImage: UIImage? {
        guard let imageData = Data(base64Encoded: data) else { return nil }
        return UIImage(data: imageData)
    }
}
#endif
