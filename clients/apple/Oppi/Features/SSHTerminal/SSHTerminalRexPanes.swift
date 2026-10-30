import UIKit

/// The sideways swipe that moves a Rex terminal to the previous or next pane
/// of its session. A pan, not `UISwipeGestureRecognizer`, so a diagonal scroll
/// of the history cannot change pane: it must start mostly sideways and end
/// far enough, or fast enough, along the same axis.
enum SSHTerminalPaneSwipe {
    /// The back swipe owns the screen's left edge.
    static let edgeInset: CGFloat = 24
    static let minimumTravel: CGFloat = 56
    static let flickTravel: CGFloat = 24
    static let flickVelocity: CGFloat = 600
    /// How much farther a swipe goes along an axis than across it.
    static let dominance: CGFloat = 2

    /// Whether a pan that starts with `velocity` is a sideways swipe.
    static func begins(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * dominance
    }

    /// The pane step a finished pan asks for: +1 (next) for a swipe to the
    /// left, -1 (previous) for a swipe to the right, nil for anything that
    /// was not a clear sideways swipe.
    static func step(translation: CGPoint, velocity: CGPoint) -> Int? {
        guard abs(translation.x) > abs(translation.y) * dominance else { return nil }
        let far = abs(translation.x) >= minimumTravel
        let flicked = abs(translation.x) >= flickTravel && abs(velocity.x) >= flickVelocity
        guard far || flicked else { return nil }
        return translation.x < 0 ? 1 : -1
    }
}

/// The pane strip: one terminal glyph per pane of the Rex session, in strip
/// order, the shown one filled and tinted. A pill of its own above the bottom
/// bar's row, since that row is full. Scrolls sideways when the panes outgrow
/// the screen. Each glyph is a button that shows its pane.
final class SSHTerminalRexStripPill: SSHTerminalGlassPill {
    private let scroll = UIScrollView()
    private let items = UIStackView()
    private var buttons: [SSHTerminalPillButton] = []
    private var revealed: String?
    private(set) var panes: [RexSessionState.Pane] = []
    /// Asks to show a pane: the same request a swipe or a minimap cell makes.
    var select: (String) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.contentInsetAdjustmentBehavior = .never
        items.axis = .horizontal
        items.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(items)
        stack.addArrangedSubview(scroll)
        // As wide as its glyphs, unless the screen has less room (the owner
        // caps the pill's width); then it scrolls.
        let natural = scroll.widthAnchor.constraint(equalTo: items.widthAnchor)
        natural.priority = .defaultHigh
        NSLayoutConstraint.activate([
            items.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            items.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            items.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            items.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            items.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            natural,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The glyph for pane `index`.
    func button(at index: Int) -> SSHTerminalPillButton? { buttons.indices.contains(index) ? buttons[index] : nil }

    func apply(state: RexSessionState, tint: UIColor, selectedTint: UIColor) {
        if state.panes != panes {
            panes = state.panes
            buttons.forEach { $0.removeFromSuperview() }
            buttons = state.panes.enumerated().map { index, pane in
                let button = SSHTerminalPillButton(
                    systemName: "terminal", label: pane.name,
                    identifier: "sshTerminal.rexPanes.\(index)"
                )
                button.addAction(UIAction { [weak self] _ in self?.select(pane.blockID) }, for: .touchUpInside)
                items.addArrangedSubview(button)
                return button
            }
            revealed = nil
        }
        for (button, pane) in zip(buttons, state.panes) {
            let isShown = pane.blockID == state.shown
            button.apply(tint: isShown ? selectedTint : tint)
            button.setSymbol(isShown ? "terminal.fill" : "terminal")
            button.accessibilityTraits = isShown ? [.button, .selected] : .button
        }
        // A strip that scrolls keeps the shown glyph in view.
        if revealed != state.shown, let index = state.panes.firstIndex(where: { $0.blockID == state.shown }) {
            revealed = state.shown
            scroll.layoutIfNeeded()
            scroll.scrollRectToVisible(buttons[index].frame, animated: false)
        }
    }
}

/// The layout minimap, at the grid's top right: the shown pane's window as
/// one rounded cell per pane at its place in the layout, the shown one in the
/// accent color, the others gray. A cell is a button that shows its pane.
/// Drawn for a window with more than one pane.
final class SSHTerminalRexMinimapView: UIView {
    static let size = CGSize(width: 76, height: 48)
    private static let padding: CGFloat = 4
    private static let gap: CGFloat = 1.5

    private let backdrop = UIView()
    private var cells: [(cell: RexSessionLayout.Cell, button: UIButton)] = []
    /// Asks to show a pane: the same request a swipe or a strip glyph makes.
    var select: (String) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = 8
        backdrop.layer.cornerCurve = .continuous
        backdrop.isUserInteractionEnabled = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        accessibilityContainerType = .semanticGroup
        accessibilityLabel = "Pane layout"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The cell button for pane `blockID`.
    func button(for blockID: String) -> UIButton? { cells.first { $0.cell.blockID == blockID }?.button }

    func apply(state: RexSessionState, shownTint: UIColor, otherTint: UIColor, backdropColor: UIColor) {
        if state.minimap != cells.map(\.cell) {
            cells.forEach { $0.button.removeFromSuperview() }
            cells = state.minimap.enumerated().map { index, cell in
                let button = UIButton(type: .custom)
                button.layer.cornerRadius = 3
                button.layer.cornerCurve = .continuous
                button.accessibilityIdentifier = "sshTerminal.rexMinimap.\(index)"
                button.addAction(UIAction { [weak self] _ in self?.select(cell.blockID) }, for: .touchUpInside)
                addSubview(button)
                return (cell, button)
            }
            setNeedsLayout()
        }
        backdrop.backgroundColor = backdropColor
        for (cell, button) in cells {
            let isShown = cell.blockID == state.shown
            button.backgroundColor = isShown ? shownTint : otherTint
            button.accessibilityLabel = state.panes.first { $0.blockID == cell.blockID }?.name ?? "Terminal"
            button.accessibilityTraits = isShown ? [.button, .selected] : .button
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        for (cell, button) in cells {
            button.frame = CGRect(
                x: area.minX + cell.rect.minX * area.width,
                y: area.minY + cell.rect.minY * area.height,
                width: cell.rect.width * area.width,
                height: cell.rect.height * area.height
            ).insetBy(dx: Self.gap, dy: Self.gap)
        }
    }
}
