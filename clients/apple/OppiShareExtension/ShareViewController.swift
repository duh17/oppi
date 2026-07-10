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
                files: snapshot.files,
                createdAt: Date()
            )

            do {
                try ShareQuickSessionPayload.store(payload)
                self.finishOrRequestHostAppOpen(payloadId: payloadId)
            } catch {
                self.finish(cancelled: true)
            }
        }
    }

    private func finishOrRequestHostAppOpen(payloadId: String) {
        let extensionPointIdentifier = ExtensionContextOpenSupport.extensionPointIdentifier()
        guard ExtensionContextOpenSupport.supportsOpeningContainingAppOnIOS(
            extensionPointIdentifier: extensionPointIdentifier
        ) else {
            showSavedMessage()
            return
        }

        guard var components = URLComponents(string: "oppi://quick-session-share") else {
            showSavedMessage()
            return
        }
        components.queryItems = [URLQueryItem(name: "id", value: payloadId)]
        guard let url = components.url, let extensionContext else {
            showSavedMessage()
            return
        }

        extensionContext.open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self else { return }
                if opened {
                    self.finish(cancelled: false)
                } else {
                    self.showSavedMessage()
                }
            }
        }
    }

    private func showSavedMessage() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let imageView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        imageView.tintColor = .systemGreen
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false

        let titleLabel = UILabel()
        titleLabel.text = "Saved to Oppi"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits.insert(.header)

        let messageLabel = UILabel()
        messageLabel.text = "Open Oppi to continue in Quick Session."
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let doneButton = UIButton(type: .system)
        doneButton.configuration = .filled()
        doneButton.configuration?.title = "Done"
        doneButton.addTarget(self, action: #selector(finishSavedShare), for: .touchUpInside)
        doneButton.accessibilityIdentifier = "share.saved.done"

        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)

        let scrollContentView = UIView()
        scrollContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContentView)
        scrollContentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            scrollContentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            imageView.heightAnchor.constraint(equalToConstant: 52),
            doneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: scrollContentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: scrollContentView.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: scrollContentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollContentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scrollContentView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: scrollContentView.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    @objc private func finishSavedShare() {
        finish(cancelled: false)
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
