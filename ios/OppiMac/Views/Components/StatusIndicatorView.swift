import SwiftUI

/// Animated status indicator for a session.
///
/// - busy / starting: cycles through symbols every 150 ms (orange)
/// - ready: pulsing green circle
/// - error: static red dot
/// - default (stopped / idle): static gray dot
struct StatusIndicatorView: View {

    let status: String

    @State private var symbolIndex = 0
    @State private var isPulsing = false

    private let busySymbols = ["·", "✦", "✳", "∗", "✻", "✽"]

    var body: some View {
        Group {
            switch status {
            case "busy", "starting":
                Text(busySymbols[symbolIndex])
                    .foregroundStyle(.orange)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 12, height: 12)
                    .task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(150))
                            symbolIndex = (symbolIndex + 1) % busySymbols.count
                        }
                    }

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
