import SwiftUI

/// Compact waveform animation for the mic button during recording.
///
/// Displays three vertical bars that pulse based on audio level input.
/// Each bar has a slightly different phase offset for a natural feel.
/// Color follows the composer's accent color (theme-controlled).
struct MicWaveformView: View {
    var audioLevel: Float
    var color: Color = .themeBlue

    private let barCount = 3
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minBarHeight: CGFloat = 4
    private let maxBarHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let phase = phaseOffset(for: index)
                let height = barHeight(phase: phase)

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: height)
            }
        }
        .animation(.linear(duration: 0.1), value: audioLevel)
    }

    /// Each bar gets a different multiplier so they don't move in lockstep.
    private func phaseOffset(for index: Int) -> Float {
        switch index {
        case 0: return 0.7
        case 1: return 1.0
        case 2: return 0.5
        default: return 1.0
        }
    }

    private func barHeight(phase: Float) -> CGFloat {
        let level = CGFloat(min(1.0, max(0.0, audioLevel * phase)))
        return minBarHeight + (maxBarHeight - minBarHeight) * level
    }
}
