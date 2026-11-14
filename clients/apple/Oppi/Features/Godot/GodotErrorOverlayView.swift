import UIKit

/// The newest error the game's own code raised, over the bottom of the game
/// (design §8): the message, the script file and line, and the backtrace
/// when there is one. File and line are context for the agent beside the
/// game; nothing opens an editor. Dismiss hides it until the next error.
///
/// The card is dark material whatever the theme, since it sits over the
/// game's own pixels. Its pane caps its height; the text scrolls inside, so
/// no line limit hides part of a long backtrace. Touch and hold copies it.
final class GodotErrorOverlayView: UIView, UIContextMenuInteractionDelegate {
    var onDismiss: (() -> Void)?

    private let message = UILabel()
    private let location = UILabel()
    private let backtrace = UILabel()
    private let scroll = UIScrollView()
    private let dismiss = UIButton(type: .system)
    private(set) var shown: GodotEngineLog?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityIdentifier = "godot.error"
        shouldGroupAccessibilityChildren = true

        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        message.font = .scaled(.callout, .semibold)
        message.textColor = .white
        message.numberOfLines = 0
        message.accessibilityIdentifier = "godot.error.message"
        location.font = .scaledMonospaced(.footnote)
        location.textColor = UIColor(white: 0.85, alpha: 1)
        location.numberOfLines = 0
        location.lineBreakMode = .byCharWrapping
        location.accessibilityIdentifier = "godot.error.location"
        backtrace.font = .scaledMonospaced(.caption2)
        backtrace.textColor = UIColor(white: 0.75, alpha: 1)
        backtrace.numberOfLines = 0
        for label in [message, location, backtrace] {
            label.adjustsFontForContentSizeCategory = true
            // Whole lines always: the card's cap makes the text scroll, never shrink.
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        var button = UIButton.Configuration.plain()
        button.image = UIImage(systemName: "xmark.circle.fill")
        button.baseForegroundColor = UIColor(white: 0.85, alpha: 1)
        dismiss.configuration = button
        dismiss.accessibilityLabel = String(localized: "Dismiss Error")
        dismiss.accessibilityIdentifier = "godot.error.dismiss"
        dismiss.addAction(UIAction { [weak self] _ in self?.onDismiss?() }, for: .primaryActionTriggered)

        let text = UIStackView(arrangedSubviews: [message, location, backtrace])
        text.axis = .vertical
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(text)
        scroll.indicatorStyle = .white
        scroll.alwaysBounceVertical = false
        for view in [scroll, dismiss] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // As tall as the text, until the pane's cap (a required constraint
        // the pane adds) makes it scroll.
        let fit = scroll.heightAnchor.constraint(equalTo: scroll.contentLayoutGuide.heightAnchor)
        fit.priority = .defaultHigh - 1
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -2),
            fit,
            text.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            text.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            dismiss.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            dismiss.widthAnchor.constraint(equalToConstant: 44),
            dismiss.heightAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Copy")) { [weak self] _ in
                self?.copy()
                return true
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ entry: GodotEngineLog) {
        guard entry != shown else { return }
        shown = entry
        message.text = entry.message
        location.text = entry.location.map { "\($0.file):\($0.line)" }
        location.isHidden = location.text == nil
        let trace = entry.backtrace.trimmingCharacters(in: .whitespacesAndNewlines)
        backtrace.text = trace
        backtrace.isHidden = trace.isEmpty
        scroll.contentOffset = .zero
    }

    /// The error as text: message, file and line, backtrace.
    private var copyText: String {
        [message.text, location.text, backtrace.text]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func copy() {
        UIPasteboard.general.string = copyText
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in self?.copy() },
            ])
        })
    }
}
