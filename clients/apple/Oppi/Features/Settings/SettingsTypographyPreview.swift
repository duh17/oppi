import UIKit

/// Text settings' live preview: a code sample and an assistant message, set in
/// the fonts the app draws with (`AppFont`), so the preview is what chat shows
/// and cannot drift from it. `AppFont` is rebuilt by every Text setting before
/// the page redraws, so `refresh()` reads the new fonts.
@MainActor
final class SettingsTypographyPreviewView: UIView {
    private let codeCaption = UILabel()
    private let codeSample = UILabel()
    private let messageCaption = UILabel()
    private let messageSample = UILabel()
    private let codeCard = UIView()
    private let messageCard = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        codeCaption.text = String(localized: "Code and tool output")
        codeSample.text = "let files = try await workspace.changedFiles()\nprint(files.count)"
        messageCaption.text = String(localized: "Assistant message")
        messageSample.text = String(localized: "I found the settings path and kept the global preference device-local.")
        for caption in [codeCaption, messageCaption] {
            caption.font = .preferredFont(forTextStyle: .caption1)
            caption.adjustsFontForContentSizeCategory = true
            caption.numberOfLines = 0
        }
        for sample in [codeSample, messageSample] {
            sample.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [
            Self.card(codeCard, caption: codeCaption, sample: codeSample),
            Self.card(messageCard, caption: messageCaption, sample: messageSample),
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // One element: the cards are samples, not controls.
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Text preview")
        accessibilityValue = [codeCaption.text, codeSample.text, messageCaption.text, messageSample.text]
            .compactMap { $0 }
            .joined(separator: ". ")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private static func card(_ card: UIView, caption: UILabel, sample: UILabel) -> UIView {
        let stack = UIStackView(arrangedSubviews: [caption, sample])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    /// Draws the samples in the current fonts and theme.
    func refresh() {
        let palette = ThemeRuntimeState.currentPalette()
        codeCaption.textColor = UIColor(palette.comment)
        messageCaption.textColor = UIColor(palette.comment)
        codeSample.textColor = UIColor(palette.fg)
        messageSample.textColor = UIColor(palette.fg)
        codeSample.font = AppFont.monoMedium
        messageSample.font = AppFont.messageBody
        codeCard.backgroundColor = UIColor(palette.bgDark)
        messageCard.backgroundColor = UIColor(palette.bgHighlight).withAlphaComponent(0.55)
    }
}
