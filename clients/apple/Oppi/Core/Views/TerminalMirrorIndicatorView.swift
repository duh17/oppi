import SwiftUI

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
