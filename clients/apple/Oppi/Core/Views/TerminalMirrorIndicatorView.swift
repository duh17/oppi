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

struct TerminalMirrorIndicatorView: View {
    let presentation: TerminalMirrorIndicatorPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var shouldAnimate: Bool {
        presentation.isAnimated && !reduceMotion
    }

    private var iconOpacity: Double {
        guard shouldAnimate else { return 0.88 }
        return breathing ? 0.98 : 0.90
    }

    var body: some View {
        Image(systemName: "terminal.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(presentation.color)
            .opacity(iconOpacity)
            .frame(width: 18, height: 16, alignment: .trailing)
            .accessibilityLabel(presentation.accessibilityLabel)
            .onAppear(perform: updateBreathing)
            .onChange(of: shouldAnimate) { _, _ in
                updateBreathing()
            }
    }

    private func updateBreathing() {
        guard shouldAnimate else {
            breathing = false
            return
        }

        breathing = false
        withAnimation(ThemeMotion.animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), reduceMotion: reduceMotion)) {
            breathing = true
        }
    }
}

/// `TerminalMirrorIndicatorView` in UIKit: the pi-tui glyph, breathing while
/// the mirror is live unless Reduce Motion is on. Session rows draw it.
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
        image = UIImage(
            systemName: "terminal.fill",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption2)
                .applying(UIImage.SymbolConfiguration(weight: .semibold))
        )
        tintColor = UIColor(presentation.color)
        accessibilityLabel = presentation.accessibilityLabel
        isAnimated = presentation.isAnimated
        updateBreathing()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBreathing()
    }

    private func updateBreathing() {
        layer.removeAnimation(forKey: "breathing")
        guard isAnimated, !UIAccessibility.isReduceMotionEnabled, window != nil else {
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
