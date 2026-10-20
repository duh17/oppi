import UIKit

/// A child conversation's live tail under the parent's tool row that names it: what a subagent
/// is writing or running right now, read-only. The row exists only while the child is busy.
struct ChildTailTimelineRowConfiguration: UIContentConfiguration {
    let tail: ConversationChildTail

    func makeContentView() -> any UIView & UIContentView {
        ChildTailTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ChildTailTimelineRowContentView: UIView, UIContentView {
    private let rail = UIView()
    private let stack = UIStackView()
    private var labels: [UILabel] = []
    private var currentConfiguration: ChildTailTimelineRowConfiguration

    init(configuration: ChildTailTimelineRowConfiguration) {
        currentConfiguration = configuration
        super.init(frame: .zero)
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        addSubview(rail)
        addSubview(stack)
        NSLayoutConstraint.activate([
            // Indented under the tool row's icon, like a nested block.
            rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: stack.topAnchor),
            rail.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let configuration = newValue as? ChildTailTimelineRowConfiguration else { return }
            apply(configuration)
        }
    }

    private func apply(_ configuration: ChildTailTimelineRowConfiguration) {
        currentConfiguration = configuration
        let palette = ThemeRuntimeState.currentPalette()
        rail.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.45)
        let lines = configuration.tail.lines
        // Reserved lines keep their height while empty, so the row does not resize per frame.
        let shown = max(lines.count, configuration.tail.reservedLines)
        while labels.count < shown {
            let label = UILabel()
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            labels.append(label)
            stack.addArrangedSubview(label)
        }
        for (index, label) in labels.enumerated() {
            guard index < shown else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            guard index < lines.count else {
                label.text = " "
                label.font = Self.font(.text)
                label.alpha = 0
                continue
            }
            let line = lines[index]
            label.alpha = 1
            label.text = line.text
            label.font = Self.font(line.kind)
            label.textColor = UIColor(line.kind == .text || line.kind == .tool ? palette.fgDim : palette.comment)
        }
        accessibilityIdentifier = "chat.timeline.childTail.\(configuration.tail.reference.conversationId)"
        accessibilityLabel = String(localized: "Subagent live")
        accessibilityValue = lines.map(\.text).joined(separator: "\n")
    }

    private static func font(_ kind: ConversationChildTail.Line.Kind) -> UIFont {
        switch kind {
        case .output:
            AppFont.mono
        case .tool:
            UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        case .thinking, .status:
            UIFont.preferredFont(forTextStyle: .caption1).italicized
        case .text:
            UIFont.preferredFont(forTextStyle: .caption1)
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }

    var italicized: UIFont {
        fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}
