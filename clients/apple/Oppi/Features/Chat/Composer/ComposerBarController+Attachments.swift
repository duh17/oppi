import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Attaching media: the menu, the pickers, the canvas, and their delegates.
extension ComposerBarController {
    func attachmentMenu() -> UIMenu {
        ComposerAttachmentPickers.menu(identifierPrefix: "chat.attach") { [weak self] item in
            switch item {
            case .photoLibrary: self?.presentPhotoLibrary()
            case .camera: self?.presentCamera()
            case .chooseFile: self?.presentFileImporter()
            case .canvas: self?.presentCanvas()
            }
        }
    }

    private func presentPhotoLibrary() {
        present(ComposerAttachmentPickers.photoLibrary(delegate: self), animated: true)
    }

    private func presentCamera() {
        present(ComposerAttachmentPickers.camera(delegate: self), animated: true)
    }

    func presentCanvas() {
        let background = canvasBackgroundImage.map { PaperMarkupCanvasSession.Background.image($0) } ?? .blank
        let replacing = canvasReplacingAttachmentID
        let controller = PaperMarkupCanvasHostController(
            background: background,
            onAddToChat: { [weak self] attachment, recognizedText in
                guard let self else { return false }
                let accepted = self.host?.applyCanvas(
                    attachment: attachment,
                    recognizedText: recognizedText,
                    replacingAttachmentID: replacing
                ) ?? false
                if accepted {
                    self.dismiss(animated: true)
                    self.canvasBackgroundImage = nil
                    self.canvasReplacingAttachmentID = nil
                    self.applyChrome()
                }
                return accepted
            },
            onCancel: { [weak self] in
                self?.dismiss(animated: true)
                self?.canvasBackgroundImage = nil
                self?.canvasReplacingAttachmentID = nil
            }
        )
        controller.modalPresentationStyle = .overFullScreen
        present(controller, animated: true)
    }

    private func presentFileImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        let capturedLocal = localMediaImportEpoch
        host?.importPhotoProviders(
            results.map(\.itemProvider),
            capturedGate: host?.content.mediaImportEpoch ?? 0,
            capturedLocal: capturedLocal,
            currentLocal: { [weak self] in self?.localMediaImportEpoch ?? 0 },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
        applyChrome()
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            host?.addCapturedImage(image)
            applyChrome()
        }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let capturedLocal = localMediaImportEpoch
        host?.loadSelectedFiles(
            .success(urls),
            capturedGate: host?.content.mediaImportEpoch ?? 0,
            capturedLocal: capturedLocal,
            currentLocal: { [weak self] in self?.localMediaImportEpoch ?? 0 },
            onFailure: { [weak self] message in
                self?.presentAlert(title: "Couldn't Attach", message: message)
            }
        )
        applyChrome()
    }
}
