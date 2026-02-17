import UIKit

/// Centralized photo-library write helper for image save actions.
///
/// Keeping writes behind an indirection makes UI code simpler and allows
/// unit tests to inject a mock writer without touching Photos APIs.
@MainActor
enum PhotoLibrarySaver {
    static var write: @MainActor (UIImage) -> Void = { image in
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }

    static func save(_ image: UIImage) {
        write(image)
    }
}
