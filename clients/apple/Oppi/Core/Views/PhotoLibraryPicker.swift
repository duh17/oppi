import PhotosUI

/// The photo library picker configuration both stable composers share (the
/// icon picker asks for one image with `filter: .images`).
///
/// `PhotosPicker` cannot mix videos with stills without dropping movies, so
/// both present `PHPickerViewController` from the composer root. Keyboard
/// dismissal can remove the attach menu, so the presenter must not live on
/// the plus button.
enum PhotoLibraryPicker {
    static func makeConfiguration(
        selectionLimit: Int = 10,
        filter: PHPickerFilter = .any(of: [.images, .videos])
    ) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = filter
        configuration.selectionLimit = selectionLimit
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }
}
