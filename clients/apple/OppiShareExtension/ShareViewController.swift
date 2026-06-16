import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        view.backgroundColor = .systemBackground
        processSharedItems()
    }

    private func processSharedItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(cancelled: true)
            return
        }

        let payloadId = UUID().uuidString
        let destinationDirectory = ShareQuickSessionPayload.payloadDirectoryURL(id: payloadId)
        do {
            if let destinationDirectory {
                try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }
        } catch {
            finish(cancelled: true)
            return
        }

        var textParts: [String] = []
        var files: [ShareQuickSessionPayload.SharedFile] = []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let value: String?
                    if let url = item as? URL {
                        value = url.absoluteString
                    } else if let string = item as? String {
                        value = string
                    } else {
                        value = nil
                    }
                    if let value, !value.isEmpty {
                        lock.lock()
                        textParts.append(value)
                        lock.unlock()
                    }
                }
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let value: String?
                    if let string = item as? String {
                        value = string
                    } else if let data = item as? Data {
                        value = String(data: data, encoding: .utf8)
                    } else {
                        value = nil
                    }
                    if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                        lock.lock()
                        textParts.append(trimmed)
                        lock.unlock()
                    }
                }
                continue
            }

            guard let destinationDirectory else { continue }
            let typeIdentifier = preferredFileTypeIdentifier(for: provider)
            guard let typeIdentifier else { continue }

            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, _ in
                defer { group.leave() }
                guard let temporaryURL else { return }

                let originalName = provider.suggestedName.map { suggestedName in
                    suggestedName.contains(".") ? suggestedName : suggestedName + Self.defaultExtension(for: typeIdentifier)
                } ?? temporaryURL.lastPathComponent
                let safeName = Self.safeFileName(originalName)
                let uniqueName = "\(UUID().uuidString)-\(safeName)"
                let destinationURL = destinationDirectory.appendingPathComponent(uniqueName, isDirectory: false)

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
                    let mimeType = UTType(typeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
                    let relativePath = "\(payloadId)/\(uniqueName)"
                    let file = ShareQuickSessionPayload.SharedFile(
                        name: safeName,
                        relativePath: relativePath,
                        mimeType: mimeType
                    )
                    lock.lock()
                    files.append(file)
                    lock.unlock()
                } catch {
                    return
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let combinedText = textParts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let payload = ShareQuickSessionPayload(
                id: payloadId,
                text: combinedText.isEmpty ? nil : combinedText,
                files: files,
                createdAt: Date()
            )

            do {
                try ShareQuickSessionPayload.store(payload)
                self.openHostApp(payloadId: payloadId)
            } catch {
                self.finish(cancelled: true)
            }
        }
    }

    private func openHostApp(payloadId: String) {
        guard var components = URLComponents(string: "oppi://quick-session-share") else {
            finish(cancelled: true)
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: payloadId)]
        guard let url = components.url else {
            finish(cancelled: true)
            return
        }

        extensionContext?.open(url) { [weak self] _ in
            self?.finish(cancelled: false)
        }
    }

    private func finish(cancelled: Bool) {
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(
                domain: "dev.chenda.Oppi.ShareExtension",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not share to Oppi"]
            ))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:").union(.newlines)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared Item" : trimmed
    }

    private static func defaultExtension(for typeIdentifier: String) -> String {
        guard let preferred = UTType(typeIdentifier)?.preferredFilenameExtension else { return "" }
        return ".\(preferred)"
    }

    private func preferredFileTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferredTypes: [UTType] = [.image, .movie, .pdf, .data, .content, .item]
        for type in preferredTypes where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            return type.identifier
        }
        return provider.registeredTypeIdentifiers.first
    }
}
