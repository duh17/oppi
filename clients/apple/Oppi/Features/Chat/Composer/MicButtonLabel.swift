import SwiftUI

/// Mic button label with three states:
/// - **Idle:** mic icon on neutral background
/// - **Recording:** language label with audio-reactive border
/// - **Processing:** spinner
struct MicButtonLabel: View {
    enum EngineBadge: Equatable, Sendable {
        case auto
        case onDevice
        case remote
    }

    let isRecording: Bool
    let isProcessing: Bool
    let audioLevel: Float
    let languageLabel: String?
    let accentColor: Color
    let engineBadge: EngineBadge
    let diameter: CGFloat

    private var indicatorColor: Color {
        if !isRecording && !isProcessing {
            return .themeComment
        }

        switch engineBadge {
        case .auto:
            return .themeComment
        case .onDevice:
            return accentColor
        case .remote:
            return .themeCyan
        }
    }

    var body: some View {
        let level = CGFloat(min(max(audioLevel, 0), 1))

        ZStack {
            Circle().fill(Color.themeBgHighlight)

            if isRecording {
                let strokeWidth = 1.5 + level * 2.0
                Circle()
                    .stroke(indicatorColor, lineWidth: strokeWidth)
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            } else {
                Circle()
                    .stroke(indicatorColor.opacity(engineBadge == .auto ? 0.35 : 0.6), lineWidth: 1)
            }

            if isProcessing {
                ProgressView()
                    .controlSize(.mini)
            } else if isRecording {
                Text(languageLabel ?? "??")
                    .font(.system(size: diameter * 0.4, weight: .bold))
                    .foregroundStyle(indicatorColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            } else {
                Image(systemName: "mic")
                    .font(.system(size: diameter * 0.47, weight: .bold))
                    .foregroundStyle(indicatorColor.opacity(engineBadge == .auto ? 0.75 : 1))
            }

        }
        .frame(width: diameter, height: diameter)
    }
}
