import SwiftUI
import UIKit

struct TerminalMirrorIndicatorPresentation: Equatable {
    let accessibilityLabel: String
    let color: Color
    let isAnimated: Bool

    init?(session: Session?) {
        guard let session else { return nil }
        self.init(session: session)
    }

    init?(session: Session) {
        guard session.runtime == .piTui else { return nil }

        if session.mirror?.status == "connected" {
            accessibilityLabel = "pi-tui live"
            color = .themeGreen
            isAnimated = true
        } else {
            accessibilityLabel = "pi-tui offline"
            color = .themeComment
            isAnimated = false
        }
    }
}

/// The pi-tui mirror mark: a terminal glyph, green and breathing while the
/// mirror is live (unless Reduce Motion is on), gray while it is offline.
/// Session rows and the chat title draw it.
final class TerminalMirrorIndicatorUIView: UIImageView {
    static let size = CGSize(width: 18, height: 16)

    private var isAnimated = false

    init() {
        super.init(frame: .zero)
        contentMode = .right
        isAccessibilityElement = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ presentation: TerminalMirrorIndicatorPresentation) {
        image = .scaledSymbol("terminal.fill", style: .caption2, weight: .semibold)
        tintColor = UIColor(presentation.color)
        accessibilityLabel = presentation.accessibilityLabel
        isAnimated = presentation.isAnimated
        updateBreathing()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBreathing()
    }

    /// A running breath keeps going across reapplies, so frequent updates do not restart it.
    private func updateBreathing() {
        let breathes = isAnimated && !UIAccessibility.isReduceMotionEnabled && window != nil
        if breathes, layer.animation(forKey: "breathing") != nil { return }
        layer.removeAnimation(forKey: "breathing")
        guard breathes else {
            alpha = 0.88
            return
        }
        alpha = 0.90
        let breathing = CABasicAnimation(keyPath: "opacity")
        breathing.fromValue = 0.90
        breathing.toValue = 0.98
        breathing.duration = 2.4
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathing, forKey: "breathing")
    }
}
