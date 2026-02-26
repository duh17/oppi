import SwiftUI

/// Mic button label with three states:
/// - **Idle:** mic icon on neutral background
/// - **Recording:** language label with audio-reactive border
/// - **Processing:** spinner
struct MicButtonLabel: View {
    let isRecording: Bool
    let isProcessing: Bool
    let audioLevel: Float
    let languageLabel: String?
    let accentColor: Color
    let diameter: CGFloat

    var body: some View {
        let level = CGFloat(min(max(audioLevel, 0), 1))

        ZStack {
            // Background — same neutral fill always, no color change
            Circle().fill(Color.themeBgHighlight)

            // Border — breathes stroke width with audio when recording
            if isRecording {
                let strokeWidth = 1.5 + level * 2.0 // 1.5 → 3.5pt
                Circle()
                    .stroke(accentColor, lineWidth: strokeWidth)
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            } else {
                Circle()
                    .stroke(Color.themeComment.opacity(0.35), lineWidth: 1)
            }

            // Center content
            if isProcessing {
                ProgressView()
                    .controlSize(.mini)
            } else if isRecording {
                Text(languageLabel ?? "??")
                    .font(.system(size: diameter * 0.4, weight: .bold))
                    .foregroundStyle(accentColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Image(systemName: "mic")
                    .font(.system(size: diameter * 0.47, weight: .bold))
                    .foregroundStyle(.themeComment)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
