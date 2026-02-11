import SwiftUI
import UIKit

/// Native UIKit assistant row used by the chat timeline migration.
///
/// This renderer is optimized for plain-text assistant content. Rich markdown
/// content is routed through the existing SwiftUI markdown renderer for parity.
struct AssistantTimelineRowConfiguration: UIContentConfiguration {
    let text: String
    let isStreaming: Bool
    let canFork: Bool
    let onFork: (() -> Void)?
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        AssistantTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> AssistantTimelineRowConfiguration {
        self
    }
}

final class AssistantTimelineRowContentView: UIView, UIContentView {
    private let iconLabel = UILabel()
    private let messageTextView = UITextView()
    private let cursorView = UIView()

    private static let customLinkRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(?:pi|oppi)://[^\s<>\"'`]+"#,
        options: []
    )
    private static let trailingLinkDelimiters: Set<Character> = ["`", "'", "\"", "’", "”"]
    private static let trailingEncodedLinkDelimiters = ["%60", "%27", "%22"]

    private var currentConfiguration: AssistantTimelineRowConfiguration

    init(configuration: AssistantTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? AssistantTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        iconLabel.textColor = UIColor(Color.tokyoPurple)
        iconLabel.text = "π"
        iconLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconLabel.isUserInteractionEnabled = true

        messageTextView.translatesAutoresizingMaskIntoConstraints = false
        messageTextView.isEditable = false
        messageTextView.isSelectable = true
        messageTextView.isScrollEnabled = false
        messageTextView.backgroundColor = .clear
        messageTextView.textContainerInset = .zero
        messageTextView.textContainer.lineFragmentPadding = 0
        messageTextView.textColor = UIColor(Color.tokyoFg)
        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.adjustsFontForContentSizeCategory = true
        messageTextView.dataDetectorTypes = [.link]
        messageTextView.delegate = self

        cursorView.translatesAutoresizingMaskIntoConstraints = false
        cursorView.backgroundColor = UIColor(Color.tokyoPurple)
        cursorView.layer.cornerRadius = 1

        addSubview(iconLabel)
        addSubview(messageTextView)
        addSubview(cursorView)
        iconLabel.addInteraction(UIContextMenuInteraction(delegate: self))

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconLabel.topAnchor.constraint(equalTo: topAnchor),

            messageTextView.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            messageTextView.topAnchor.constraint(equalTo: topAnchor),
            messageTextView.trailingAnchor.constraint(equalTo: trailingAnchor),

            cursorView.leadingAnchor.constraint(equalTo: messageTextView.leadingAnchor),
            cursorView.topAnchor.constraint(equalTo: messageTextView.bottomAnchor, constant: 4),
            cursorView.widthAnchor.constraint(equalToConstant: 8),
            cursorView.heightAnchor.constraint(equalToConstant: 14),
            cursorView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func apply(configuration: AssistantTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        iconLabel.textColor = UIColor(palette.purple)
        messageTextView.textColor = UIColor(palette.fg)
        messageTextView.tintColor = UIColor(palette.blue)
        messageTextView.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        cursorView.backgroundColor = UIColor(palette.purple)

        messageTextView.attributedText = linkedText(
            for: configuration.text,
            baseColor: UIColor(palette.fg)
        )

        if configuration.isStreaming {
            cursorView.isHidden = false
            startCursorAnimationIfNeeded()
        } else {
            cursorView.isHidden = true
            cursorView.layer.removeAnimation(forKey: "opacityPulse")
        }
    }

    private func linkedText(for text: String, baseColor: UIColor) -> NSAttributedString {
        let font = messageTextView.font ?? .preferredFont(forTextStyle: .body)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: baseColor,
            ]
        )

        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else {
            return attributed
        }

        let nsText = text as NSString

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            detector.enumerateMatches(in: text, options: [], range: fullRange) { [weak self] match, _, _ in
                guard
                    let self,
                    let match,
                    let normalized = self.normalizedLink(in: nsText, range: match.range)
                else {
                    return
                }
                attributed.addAttribute(.link, value: normalized.url, range: normalized.range)
            }
        }

        if let customLinkRegex = Self.customLinkRegex {
            for match in customLinkRegex.matches(in: text, options: [], range: fullRange) {
                guard let normalized = normalizedLink(in: nsText, range: match.range) else {
                    continue
                }
                attributed.addAttribute(.link, value: normalized.url, range: normalized.range)
            }
        }

        return attributed
    }

    private func normalizedLink(in nsText: NSString, range: NSRange) -> (url: URL, range: NSRange)? {
        guard range.location != NSNotFound, range.length > 0 else {
            return nil
        }

        var adjustedLength = range.length
        while adjustedLength > 0 {
            let lastCharacterRange = NSRange(location: range.location + adjustedLength - 1, length: 1)
            let character = nsText.substring(with: lastCharacterRange)
            if Self.shouldTrimTrailingLinkCharacter(character) {
                adjustedLength -= 1
                continue
            }
            break
        }

        guard adjustedLength > 0 else {
            return nil
        }

        let adjustedRange = NSRange(location: range.location, length: adjustedLength)
        let rawURL = nsText.substring(with: adjustedRange)
        let normalizedURLString = Self.normalizedURLString(rawURL)
        guard let url = URL(string: normalizedURLString) else {
            return nil
        }

        let rawLength = (rawURL as NSString).length
        let normalizedLength = (normalizedURLString as NSString).length
        let rangeLength = max(0, adjustedRange.length - max(0, rawLength - normalizedLength))
        let finalRange = NSRange(location: adjustedRange.location, length: rangeLength)

        return (url: url, range: finalRange)
    }

    private static func shouldTrimTrailingLinkCharacter(_ character: String) -> Bool {
        guard character.count == 1, let scalar = character.first else {
            return false
        }
        return trailingLinkDelimiters.contains(scalar)
    }

    private static func normalizedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        while !value.isEmpty {
            if let suffix = trailingEncodedLinkDelimiters.first(where: { value.lowercased().hasSuffix($0) }) {
                value = String(value.dropLast(suffix.count))
                continue
            }

            guard let last = value.last, trailingLinkDelimiters.contains(last) else {
                break
            }

            value.removeLast()
        }

        return value
    }

    private static func normalizedInteractionURL(_ url: URL) -> URL {
        let normalized = normalizedURLString(url.absoluteString)
        return URL(string: normalized) ?? url
    }

    private func startCursorAnimationIfNeeded() {
        guard cursorView.layer.animation(forKey: "opacityPulse") == nil else { return }

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 0.4
        pulse.duration = 1.4
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        cursorView.layer.add(pulse, forKey: "opacityPulse")
    }

    private func copyToPasteboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        UIPasteboard.general.string = trimmed
        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.82)
    }

}

extension AssistantTimelineRowContentView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        let normalizedURL = Self.normalizedInteractionURL(url)

        guard let scheme = normalizedURL.scheme?.lowercased() else {
            return true
        }

        if scheme == "pi" || scheme == "oppi" {
            NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            return false
        }

        return true
    }
}

extension AssistantTimelineRowContentView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let text = currentConfiguration.text
        let hasCopyText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasForkAction = currentConfiguration.canFork && currentConfiguration.onFork != nil

        guard hasCopyText || hasForkAction else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            var actions: [UIMenuElement] = []

            if hasCopyText {
                actions.append(
                    UIAction(title: "Copy Full Response", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                        self?.copyToPasteboard(text)
                    }
                )

                actions.append(
                    UIAction(title: "Copy Full Response as Markdown", image: UIImage(systemName: "text.document")) { [weak self] _ in
                        self?.copyToPasteboard(text)
                    }
                )
            }

            if hasForkAction, let onFork = self.currentConfiguration.onFork {
                actions.append(
                    UIAction(title: "Fork from here", image: UIImage(systemName: "arrow.triangle.branch")) { _ in
                        onFork()
                    }
                )
            }

            return UIMenu(title: "", children: actions)
        }
    }
}

