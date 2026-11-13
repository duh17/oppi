import UIKit
import UniformTypeIdentifiers

/// What the window's pane host (`PaneHostController+Drop`) hands a chat when
/// something is dropped on it: a file or folder of this chat's workspace
/// becomes a file reference in the message; files and photos from outside
/// the app (Files, Photos) become attachments, through the same intake as
/// the attach menu.
extension ChatViewController {
    /// Whether `entry` is a file or folder this chat can reference: one in
    /// its own workspace on its own server.
    func canReference(_ entry: PaneStackEntry) -> Bool {
        guard entry.serverId == resolvedServerId, let workspaceId = session?.workspaceId else { return false }
        switch entry.route {
        case .file(.workspace(let id, _), _, _), .files(let id, _): return id == workspaceId
        default: return false
        }
    }

    /// The composer's frame in `view`'s coordinates, while it shows.
    func composerDropArea(in view: UIView) -> CGRect? {
        let bar = composer.bar
        guard bar.isViewLoaded, bar.view.window != nil, !bar.view.isHidden else { return nil }
        return bar.view.convert(bar.view.bounds, to: view)
    }

    /// Adds `entry` to the message as a file reference.
    func reference(_ entry: PaneStackEntry) {
        switch entry.route {
        case .file(_, let path, _):
            composer.insertFileSuggestion(FileSuggestion(path: path, isDirectory: false))
        case .files(_, let path):
            composer.insertFileSuggestion(FileSuggestion(path: (path ?? "") + "/", isDirectory: true))
        default:
            return
        }
    }

    /// Attaches dropped items from outside the app: photos and videos as the
    /// Photos picker attaches them, any other file as Choose File does.
    func attachDropped(_ providers: [NSItemProvider]) {
        let media = providers.filter { PhotoLibraryMediaImporter.kind(for: $0) != nil }
        let files = providers.filter { PhotoLibraryMediaImporter.kind(for: $0) == nil }
        let gate = composerMediaImportGate?.epoch ?? 0
        let failed: (String) -> Void = { [weak self] message in
            self?.errorAlerts.show(title: String(localized: "Couldn't Attach"), message: message)
        }
        if !media.isEmpty {
            composer.importPhotoProviders(media, capturedGate: gate, capturedLocal: 0, currentLocal: { 0 }, onFailure: failed)
        }
        guard !files.isEmpty else { return }
        Task { [weak self] in
            var urls: [URL] = []
            for provider in files {
                if let url = await Self.copyDroppedFile(provider) { urls.append(url) }
            }
            guard let self else { return }
            if urls.count < files.count {
                failed(String(localized: "Some items could not be read."))
            }
            guard !urls.isEmpty else { return }
            self.composer.loadSelectedFiles(.success(urls), capturedGate: gate, capturedLocal: 0, currentLocal: { 0 }, onFailure: failed)
        }
    }

    /// A copy of the dropped file in a folder of its own under the temporary
    /// directory, named as the source named it; the provider's own file is
    /// gone once its callback returns.
    private static func copyDroppedFile(_ provider: NSItemProvider) async -> URL? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dropped-\(UUID().uuidString)", isDirectory: true)
                let copy = folder.appendingPathComponent(suggestedName.map { name in
                    url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)") ? name : "\(name).\(url.pathExtension)"
                } ?? url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
