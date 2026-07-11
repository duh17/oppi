import UIKit
import UniformTypeIdentifiers

/// Item-provider callbacks may arrive concurrently. All mutable state is
/// protected by `lock`, which is why this reference can cross callback threads.
private final class SharePayloadAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var textParts: [String] = []
    private var files: [ShareQuickSessionPayload.SharedFile] = []

    func appendText(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        textParts.append(value)
    }

    func appendFile(_ file: ShareQuickSessionPayload.SharedFile) {
        lock.lock()
        defer { lock.unlock() }
        files.append(file)
    }

    func snapshot() -> (textParts: [String], files: [ShareQuickSessionPayload.SharedFile]) {
        lock.lock()
        defer { lock.unlock() }
        return (textParts, files)
    }
}

final class ShareViewController: UIViewController {
    private var didStart = false
    private var composerController: ShareQuickSessionComposerViewController?

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

        let accumulator = SharePayloadAccumulator()
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()

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
                        accumulator.appendText(value)
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
                        accumulator.appendText(trimmed)
                    }
                }
                continue
            }

            guard let destinationDirectory else { continue }
            let typeIdentifier = preferredFileTypeIdentifier(for: provider)
            guard let typeIdentifier else { continue }

            let suggestedName = provider.suggestedName
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { temporaryURL, _ in
                defer { group.leave() }
                guard let temporaryURL else { return }

                let originalName = suggestedName.map { name in
                    name.contains(".") ? name : name + Self.defaultExtension(for: typeIdentifier)
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
                    accumulator.appendFile(file)
                } catch {
                    return
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let snapshot = accumulator.snapshot()
            let combinedText = snapshot.textParts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let payload = ShareQuickSessionPayload(
                id: payloadId,
                text: combinedText.isEmpty ? nil : combinedText,
                files: snapshot.files
            )

            guard payload.text != nil || !payload.files.isEmpty else {
                ShareQuickSessionPayload.removePayloadFiles(id: payloadId)
                self.finish(cancelled: true)
                return
            }
            self.presentComposer(payload)
        }
    }

    private func presentComposer(_ payload: ShareQuickSessionPayload) {
        let composer = ShareQuickSessionComposerViewController(payload: payload) { [weak self] cancelled in
            self?.finish(cancelled: cancelled)
        }
        composerController = composer
        addChild(composer)
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composer.view)
        NSLayoutConstraint.activate([
            composer.view.topAnchor.constraint(equalTo: view.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        composer.didMove(toParent: self)
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

    nonisolated private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:").union(.newlines)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared Item" : trimmed
    }

    nonisolated private static func defaultExtension(for typeIdentifier: String) -> String {
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
