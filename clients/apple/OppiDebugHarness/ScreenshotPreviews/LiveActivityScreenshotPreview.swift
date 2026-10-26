#if DEBUG
import SwiftUI

// MARK: - Live Activity Preview

/// An approximation of the counts-only card for screenshots; the widget extension draws
/// the real one from the same `LiveActivityPresentation`.
struct LiveActivityPreviewScreen: View {
    let title: String
    let state: OppiActivityAttributes.ContentState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.08, green: 0.09, blue: 0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Compact preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    LiveActivityPiMark(state: state, size: 18)
                    Spacer()
                    HStack(spacing: 6) {
                        if state.running > 0 || state.needsYou == 0 {
                            LiveActivityPixelNumber(value: state.running, color: LiveActivityPresentation.runningColor)
                        }
                        if state.needsYou > 0 {
                            LiveActivityPixelNumber(value: state.needsYou, color: LiveActivityPresentation.needsYouColor)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(width: 200)
                .background(Capsule().fill(Color.black))

                Text("Lock Screen preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    LiveActivityPiMark(state: state, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Oppi").font(.subheadline.bold())
                        Text(LiveActivityPresentation.summary(state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7.5) {
                        if state.running > 0 {
                            LiveActivityPixelNumber(value: state.running, color: LiveActivityPresentation.runningColor, cellPitch: 3)
                        }
                        if state.needsYou > 0 {
                            LiveActivityPixelNumber(value: state.needsYou, color: LiveActivityPresentation.needsYouColor, cellPitch: 3)
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
