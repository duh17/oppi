import SwiftUI

/// Animated status indicator for a session.
///
/// - busy / starting: Game of Life animation (orange)
/// - ready: pulsing green circle
/// - error: static red dot
/// - default (stopped / idle): static gray dot
struct StatusIndicatorView: View {

    let status: String

    @State private var isPulsing = false

    var body: some View {
        Group {
            switch status {
            case "busy", "starting":
                GameOfLifeRepresentable(gridSize: 5, color: .orange)
                    .frame(width: 14, height: 14)

            case "ready":
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isPulsing ? 1.35 : 1.0)
                    .opacity(isPulsing ? 0.55 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }

            case "error":
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

            default:
                Circle()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
    }
}
