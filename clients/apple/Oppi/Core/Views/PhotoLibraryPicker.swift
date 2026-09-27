import PhotosUI
import SwiftUI
import UIKit

/// UIKit photo library picker wrapped for SwiftUI.
///
/// `PhotosPicker` cannot mix videos with stills without dropping movies, so
/// both stable composers present `PHPickerViewController` from the composer
/// root. Keyboard dismissal can remove the attach menu, so this presenter
/// must not live on the plus button.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 10
    let onPick: ([NSItemProvider]) -> Void
    let onCancel: () -> Void

    static func makeConfiguration(selectionLimit: Int = 10) -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = selectionLimit
        configuration.preferredAssetRepresentationMode = .current
        return configuration
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: Self.makeConfiguration(selectionLimit: selectionLimit))
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: PHPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([NSItemProvider]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([NSItemProvider]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func picker(_: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if results.isEmpty {
                onCancel()
                return
            }
            onPick(results.map(\.itemProvider))
        }
    }
}
