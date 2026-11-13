import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The bottom bar's Attach menu: the composer's pickers (Photo Library, Camera,
/// Choose File, Canvas, `ComposerAttachmentPickers`) and its importers, with the
/// terminal as where the picks go. Each pick is handed to `deliver` at once; the
/// screen saves it on the host and types its path, as it does for a pasted image.
@MainActor
final class SSHTerminalAttachPicker: NSObject, PHPickerViewControllerDelegate,
    UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    /// The screen the pickers present from.
    weak var presenter: UIViewController?
    /// Where Photo Library and Files copies are kept until they are sent.
    var draftStore: () -> ComposerDraftStore? = { nil }
    /// The picks, in the order chosen.
    var deliver: ([PendingAttachment]) -> Void = { _ in }
    /// A pick that could not be read.
    var failed: (String) -> Void = { _ in }
    /// A picker is about to cover the terminal, and has closed again (picked
    /// or cancelled), so the screen can put its keyboard away and back.
    var willPresent: () -> Void = {}
    var closed: () -> Void = {}

    func menu() -> UIMenu {
        ComposerAttachmentPickers.menu(identifierPrefix: "sshTerminal.attach") { [weak self] item in
            guard let self else { return }
            switch item {
            case .photoLibrary: present(ComposerAttachmentPickers.photoLibrary(delegate: self))
            case .camera: present(ComposerAttachmentPickers.camera(delegate: self))
            case .chooseFile: presentFileImporter()
            case .canvas: presentCanvas()
            }
        }
    }

    private func present(_ controller: UIViewController) {
        willPresent()
        presenter?.present(controller, animated: true)
    }

    /// Dismisses `picker`, then tells the screen it closed.
    private func close(_ picker: UIViewController) {
        picker.dismiss(animated: true) { [weak self] in self?.closed() }
    }

    private func presentFileImporter() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker)
    }

    private func presentCanvas() {
        // The canvas dismisses itself once its drawing is accepted.
        let controller = PaperMarkupCanvasHostController.makeNavigationController(
            background: .blank,
            onAddToChat: { [weak self] attachment, _ in
                self?.deliver([attachment])
                self?.closed()
                return self != nil
            },
            onCancel: { [weak self] in self?.closed() }
        )
        controller.modalPresentationStyle = .overFullScreen
        present(controller)
    }

    /// The importers commit into a draft; here the draft is always empty and
    /// whatever they commit goes straight on.
    private var none: () -> [PendingAttachment] { { [] } }
    private var send: ([PendingAttachment]) -> Void { { [weak self] in self?.deliver($0) } }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        close(picker)
        guard !results.isEmpty else { return }
        ComposerShared.importPhotoLibraryProviders(
            results.map(\.itemProvider),
            getAttachments: none,
            setAttachments: send,
            store: draftStore(),
            shouldAccept: { true },
            onFailure: { [weak self] in self?.failed($0) }
        )
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        close(picker)
        guard let image = info[.originalImage] as? UIImage else { return }
        ComposerShared.addCapturedImage(image, getAttachments: none, setAttachments: send, shouldAccept: { true })
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        close(picker)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        closed()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        closed()
        ComposerShared.loadSelectedFiles(
            .success(urls),
            getAttachments: none,
            setAttachments: send,
            store: draftStore(),
            shouldAccept: { true },
            onFailure: { [weak self] in self?.failed($0) }
        )
    }

    /// An attachment's bytes and the file extension the host copy carries.
    static func fileContents(_ attachment: PendingAttachment) async throws -> (Data, String) {
        let mimeType = attachment.imageAttachment?.mimeType ?? attachment.localMimeType
        let named = (attachment.displayName as NSString).pathExtension
        let ext = named.isEmpty
            ? mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ""
            : named
        if let data = attachment.composerDraftData { return (data, ext) }
        if let url = attachment.localFileURL {
            let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
            return (data, ext)
        }
        throw SSHTerminalUpload.Failure.rejected("\(attachment.displayName) has no local data to send.")
    }
}
