import UIKit
import SwiftUI

final class NativeExpandedReadMediaView: UIView {
    private let rootStack = UIStackView()
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
            let hint = UILabel()
            hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            hint.textColor = UIColor(palette.comment)
            hint.numberOfLines = 0
            hint.text = imageAttachmentHint(count: parsed.images.count)
            rootStack.addArrangedSubview(makeCardView(contentView: hint, palette: palette))
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

    private func imageAttachmentHint(count: Int) -> String {
        if count == 1 {
            return "1 image attachment available in collapsed preview. Tap image to open full screen."
        }
        return "\(count) image attachments available in collapsed preview. Tap image to open full screen."
    }

    private func clearRows() {
        for view in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(view)
            view.removeFromSuperview()
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
