import UIKit

/// Centralized photo-library write helper for image save actions.
@MainActor
enum PhotoLibrarySaver {
    static func save(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}
