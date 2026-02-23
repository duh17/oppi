import SwiftUI
import UIKit

// MARK: - Native Expanded Tool Views (UIKit Hot Path)

final class NativeExpandedTodoView: UIView {
    private let rootStack = UIStackView()
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(output: String, themeID: ThemeID) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        let palette = themeID.palette
        clearRows()

        switch NativeExpandedTodoParser.parse(output) {
        case .item(let item):
            rootStack.addArrangedSubview(makeTodoItemCard(item: item, palette: palette))

        case .list(let list):
            rootStack.addArrangedSubview(makeTodoListCard(list: list, palette: palette))

        case .text(let text):
            rootStack.addArrangedSubview(
                makePlainTextCard(
                    text: String(text.prefix(2_000)),
                    color: UIColor(palette.fg),
                    palette: palette
                )
            )
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func clearRows() {
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func makeTodoItemCard(item: NativeExpandedTodoItem, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 8

        let idLabel = UILabel()
        idLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        idLabel.textColor = UIColor(palette.cyan)
        idLabel.text = item.displayID
        topRow.addArrangedSubview(idLabel)

        if let status = item.status, !status.isEmpty {
            topRow.addArrangedSubview(makeStatusBadge(status: status, palette: palette))
        }

        topRow.addArrangedSubview(UIView())

        if let createdAt = item.createdAt, !createdAt.isEmpty {
            let createdLabel = UILabel()
            createdLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            createdLabel.textColor = UIColor(palette.comment)
            createdLabel.text = createdAt
            topRow.addArrangedSubview(createdLabel)
        }

        stack.addArrangedSubview(topRow)

        if let title = item.title, !title.isEmpty {
            let titleLabel = UILabel()
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = UIColor(palette.fg)
            titleLabel.numberOfLines = 0
            titleLabel.text = title
            stack.addArrangedSubview(titleLabel)
        }

        if !item.normalizedTags.isEmpty {
            let tagsLabel = UILabel()
            tagsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            tagsLabel.textColor = UIColor(palette.blue)
            tagsLabel.numberOfLines = 2
            let visibleTags = item.normalizedTags.prefix(10).joined(separator: ", ")
            tagsLabel.text = "tags: \(visibleTags)"
            stack.addArrangedSubview(tagsLabel)
        }

        let body = item.trimmedBody
        if !body.isEmpty {
            let bodyLabel = UILabel()
            bodyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            bodyLabel.textColor = UIColor(palette.fg)
            bodyLabel.numberOfLines = 0
            bodyLabel.text = String(body.prefix(8_000))
            stack.addArrangedSubview(bodyLabel)

            if body.count > 8_000 {
                let truncated = UILabel()
                truncated.font = .systemFont(ofSize: 10, weight: .regular)
                truncated.textColor = UIColor(palette.comment)
                truncated.text = "… body truncated"
                stack.addArrangedSubview(truncated)
            }
        }

        return container
    }

    private func makeTodoListCard(list: NativeExpandedTodoListPayload, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        for section in list.sections {
            guard !section.items.isEmpty else { continue }

            let sectionTitle = UILabel()
            sectionTitle.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            sectionTitle.textColor = UIColor(palette.comment)
            sectionTitle.text = section.title
            stack.addArrangedSubview(sectionTitle)

            for item in section.items.prefix(12) {
                let row = UILabel()
                row.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = item.listSummaryLine
                stack.addArrangedSubview(row)
            }

            if section.items.count > 12 {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(section.items.count - 12) more"
                stack.addArrangedSubview(more)
            }
        }

        if stack.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(
                makePlainTextCard(
                    text: "No todo items in output",
                    color: UIColor(palette.comment),
                    palette: palette
                )
            )
        }

        return container
    }

    private func makePlainTextCard(text: String, color: UIColor, palette: ThemePalette) -> UIView {
        let container = makeCardContainer(palette: palette)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.numberOfLines = 0
        label.text = text

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    private func makeCardContainer(palette: ThemePalette) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
        return container
    }

    private func makeStatusBadge(status: String, palette: ThemePalette) -> UIView {
        let normalized = status.lowercased()
        let tint: UIColor
        switch normalized {
        case "done", "closed":
            tint = UIColor(palette.green)
        case "in-progress", "in_progress", "inprogress":
            tint = UIColor(palette.orange)
        case "open":
            tint = UIColor(palette.blue)
        default:
            tint = UIColor(palette.comment)
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        label.textColor = tint
        label.text = status

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = tint.withAlphaComponent(0.12)
        container.layer.cornerRadius = 8
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }
}

private enum NativeExpandedTodoParsed {
    case item(NativeExpandedTodoItem)
    case list(NativeExpandedTodoListPayload)
    case text(String)
}

private struct NativeExpandedTodoItem: Decodable {
    let id: String?
    let title: String?
    let tags: [String]?
    let status: String?
    let createdAt: String?
    let body: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case tags
        case status
        case createdAt = "created_at"
        case body
    }

    var looksLikeTodo: Bool {
        id != nil || title != nil || status != nil || createdAt != nil || body != nil || !(tags ?? []).isEmpty
    }

    var displayID: String {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "TODO-unknown" : trimmed
    }

    var normalizedTags: [String] {
        tags?.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
    }

    var trimmedBody: String {
        (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var listSummaryLine: String {
        var parts: [String] = [displayID]
        if let status, !status.isEmpty {
            parts.append("[\(status)]")
        }
        if let title, !title.isEmpty {
            parts.append(title)
        }
        return parts.joined(separator: " ")
    }
}

private struct NativeExpandedTodoSection {
    let title: String
    let items: [NativeExpandedTodoItem]
}

private struct NativeExpandedTodoListPayload: Decodable {
    let assigned: [NativeExpandedTodoItem]?
    let open: [NativeExpandedTodoItem]?
    let closed: [NativeExpandedTodoItem]?

    var hasSections: Bool {
        assigned != nil || open != nil || closed != nil
    }

    var sections: [NativeExpandedTodoSection] {
        [
            NativeExpandedTodoSection(title: "Assigned", items: assigned ?? []),
            NativeExpandedTodoSection(title: "Open", items: open ?? []),
            NativeExpandedTodoSection(title: "Closed", items: closed ?? []),
        ]
    }
}

private enum NativeExpandedTodoParser {
    static func parse(_ output: String) -> NativeExpandedTodoParsed {
        guard let data = output.data(using: .utf8) else {
            return .text(output)
        }

        let decoder = JSONDecoder()

        if let list = try? decoder.decode(NativeExpandedTodoListPayload.self, from: data), list.hasSections {
            return .list(list)
        }

        if let item = try? decoder.decode(NativeExpandedTodoItem.self, from: data), item.looksLikeTodo {
            return .item(item)
        }

        return .text(output)
    }
}

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
    private var decodeTasks: [Task<Void, Never>] = []
    private var renderGeneration = 0
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        themeID: ThemeID
    ) {
        var hasher = Hasher()
        hasher.combine(output)
        hasher.combine(isError)
        hasher.combine(filePath ?? "")
        hasher.combine(startLine)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        cancelDecodeTasks()
        clearRows()

        let palette = themeID.palette
        let parsed = NativeExpandedReadMediaParser.parse(output)

        if let filePath, !filePath.isEmpty {
            let pathLabel = UILabel()
            pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            pathLabel.textColor = UIColor(palette.comment)
            pathLabel.numberOfLines = 1
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.text = filePath.shortenedPath
            rootStack.addArrangedSubview(pathLabel)
        }

        if !parsed.strippedText.isEmpty {
            let textLabel = UILabel()
            textLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textLabel.textColor = UIColor(isError ? palette.red : palette.fg)
            textLabel.numberOfLines = 0
            textLabel.text = String(parsed.strippedText.prefix(3_000))
            rootStack.addArrangedSubview(makeCardView(contentView: textLabel, palette: palette))
        }

        if !parsed.images.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Images (\(parsed.images.count))"
            rootStack.addArrangedSubview(countLabel)

            let visibleImages = parsed.images.prefix(4)
            for image in visibleImages {
                rootStack.addArrangedSubview(makeImageCard(image: image, palette: palette))
            }
            if parsed.images.count > visibleImages.count {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.images.count - visibleImages.count) more image attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if !parsed.audio.isEmpty {
            let countLabel = UILabel()
            countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = UIColor(palette.comment)
            countLabel.text = "Audio (\(parsed.audio.count))"
            rootStack.addArrangedSubview(countLabel)

            for (index, clip) in parsed.audio.prefix(6).enumerated() {
                let row = UILabel()
                row.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                row.textColor = UIColor(palette.fg)
                row.numberOfLines = 1
                row.lineBreakMode = .byTruncatingTail
                row.text = "🔊 Clip \(index + 1) • \(clip.mimeType ?? "audio/unknown")"
                rootStack.addArrangedSubview(makeCardView(contentView: row, palette: palette))
            }
            if parsed.audio.count > 6 {
                let more = UILabel()
                more.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                more.textColor = UIColor(palette.comment)
                more.text = "+\(parsed.audio.count - 6) more audio attachment(s)"
                rootStack.addArrangedSubview(more)
            }
        }

        if parsed.strippedText.isEmpty && parsed.images.isEmpty && parsed.audio.isEmpty {
            let empty = UILabel()
            empty.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            empty.textColor = UIColor(palette.comment)
            empty.numberOfLines = 0
            empty.text = "No readable media output"
            rootStack.addArrangedSubview(makeCardView(contentView: empty, palette: palette))
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.spacing = 8

        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeCardView(contentView: UIView, palette: ThemePalette) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor(palette.bgDark)
        container.layer.cornerRadius = 8
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            contentView.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        return container
    }

    private func makeImageCard(image: ImageExtractor.ExtractedImage, palette: ThemePalette) -> UIView {
        let card = TappableImageCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.cornerRadius = 8
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor

        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 180),
        ])

        card.configure(placeholderColor: UIColor(palette.comment))

        let generation = renderGeneration
        let base64 = image.base64
        let task = Task { [weak self] in
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDecodeCache.decode(base64: base64, maxPixelSize: 1600)
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.renderGeneration == generation else {
                return
            }

            card.setDecodedImage(decoded)
        }

        decodeTasks.append(task)
        return card
    }

    private func clearRows() {
        renderGeneration += 1
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func cancelDecodeTasks() {
        for task in decodeTasks {
            task.cancel()
        }
        decodeTasks.removeAll(keepingCapacity: false)
    }
}

/// Interactive image card with tap-to-fullscreen and context menu (Copy/Save/Share).
///
/// Used by `NativeExpandedReadMediaView` for expanded image cards and designed
/// to be self-contained — handles its own gestures and modal presentation.
private final class TappableImageCard: UIView, UIContextMenuInteractionDelegate {
    private let cardImageView = UIImageView()
    private let placeholderLabel = UILabel()
    private(set) var decodedImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(placeholderColor: UIColor) {
        cardImageView.translatesAutoresizingMaskIntoConstraints = false
        cardImageView.contentMode = .scaleAspectFit
        cardImageView.clipsToBounds = true
        addSubview(cardImageView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.text = "Decoding image…"
        addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            cardImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cardImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cardImageView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            cardImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            placeholderLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @MainActor
    func setDecodedImage(_ image: UIImage?) {
        decodedImage = image
        if let image {
            cardImageView.image = image
            placeholderLabel.isHidden = true
        } else {
            placeholderLabel.text = "Image preview unavailable"
            placeholderLabel.isHidden = false
        }
    }

    @objc private func handleTap() {
        guard let image = decodedImage else { return }
        presentFullScreenImage(image)
    }

    private func presentFullScreenImage(_ image: UIImage) {
        guard let presenter = nearestViewController() else { return }
        let controller = FullScreenImageViewController(image: image)
        // Use .overFullScreen — see ToolTimelineRowContentView.showFullScreenContent() comment.
        controller.modalPresentationStyle = .overFullScreen
        presenter.present(controller, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let image = decodedImage else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: "", children: [
                UIAction(
                    title: "View Full Screen",
                    image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")
                ) { _ in
                    self?.presentFullScreenImage(image)
                },
                UIAction(
                    title: "Copy Image",
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.image = image
                },
                UIAction(
                    title: "Save to Photos",
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { _ in
                    PhotoLibrarySaver.save(image)
                },
            ])
        }
    }
}

private struct NativeExpandedReadMediaParsed {
    let strippedText: String
    let images: [ImageExtractor.ExtractedImage]
    let audio: [AudioExtractor.ExtractedAudio]
}

private enum NativeExpandedReadMediaParser {
    static func parse(_ output: String) -> NativeExpandedReadMediaParsed {
        let images = ImageExtractor.extract(from: output)
        let audio = AudioExtractor.extract(from: output)

        let strippedText: String
        if images.isEmpty && audio.isEmpty {
            strippedText = output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            var text = output
            let ranges = (images.map(\.range) + audio.map(\.range))
                .sorted { $0.lowerBound > $1.lowerBound }
            for range in ranges {
                text.removeSubrange(range)
            }
            strippedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return NativeExpandedReadMediaParsed(
            strippedText: strippedText,
            images: images,
            audio: audio
        )
    }
}
