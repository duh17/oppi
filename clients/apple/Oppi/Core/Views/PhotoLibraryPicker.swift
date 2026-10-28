import PhotosUI

/// The photo library picker configuration both stable composers share.
///
/// `PhotosPicker` cannot mix videos with stills without dropping movies, so
/// both present `PHPickerViewController` from the composer root. Keyboard
/// dismissal can remove the attach menu, so the presenter must not live on
/// the plus button.
enum PhotoLibraryPicker {
    static func makeConfiguration(selectionLimit: Int = 10) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = selectionLimit
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }
}
