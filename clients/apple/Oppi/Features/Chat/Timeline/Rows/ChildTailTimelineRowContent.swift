import UIKit

/// The live tail of a child conversation the parent is waiting on, under the running tool row
/// that names it: what a subagent is writing or running right now. The row exists only while
/// the child is busy; tapping it opens the child's session.
struct ChildTailTimelineRowConfiguration: UIContentConfiguration {
    let tail: ConversationChildTail
    var onOpen: (() -> Void)?

    init(tail: ConversationChildTail, onOpen: (() -> Void)? = nil) {
        self.tail = tail
        self.onOpen = onOpen
    }

    func makeContentView() -> any UIView & UIContentView {
        ChildTailTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

final class ChildTailTimelineRowContentView: UIView, UIContentView {
    private let rail = UIView()
    private let lines = ChildTailLinesView()
    private var currentConfiguration: ChildTailTimelineRowConfiguration

    init(configuration: ChildTailTimelineRowConfiguration) {
        currentConfiguration = configuration
        super.init(frame: .zero)
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        addSubview(lines)
        NSLayoutConstraint.activate([
            // Indented under the tool row's icon, like a nested block.
            rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: lines.topAnchor),
            rail.bottomAnchor.constraint(equalTo: lines.bottomAnchor),
            lines.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 8),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        isAccessibilityElement = true
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
        // Reserved lines keep their height while empty, so the row does not resize per frame.
        lines.apply(configuration.tail.lines, reserving: configuration.tail.reservedLines, palette: palette)
        accessibilityIdentifier = "chat.timeline.childTail.\(configuration.tail.reference.conversationId)"
        accessibilityLabel = String(localized: "Subagent live")
        accessibilityValue = configuration.tail.lines.map(\.text).joined(separator: "\n")
        accessibilityTraits = configuration.onOpen == nil ? [.staticText, .updatesFrequently] : [.button, .updatesFrequently]
        accessibilityHint = configuration.onOpen == nil ? nil : String(localized: "Opens the subagent's session")
    }

    @objc private func handleTap() {
        currentConfiguration.onOpen?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onOpen = currentConfiguration.onOpen else { return false }
        onOpen()
        return true
    }
}

/// A child's live tail lines, one label each: the timeline's child tail row and an extension
/// drawer row that links to the child's session draw them the same way.
final class ChildTailLinesView: UIStackView {
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 2
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// `reserving` keeps room for that many lines while fewer are shown.
    func apply(_ lines: [ConversationChildTail.Line], reserving: Int = 0, palette: ThemePalette) {
        let shown = max(lines.count, reserving)
        while labels.count < shown {
            let label = UILabel()
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            labels.append(label)
            addArrangedSubview(label)
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
