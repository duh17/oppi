import SwiftUI

/// Compact live-call chrome that replaces the text composer.
///
/// Mute / one center state / End. Mute stops Live Voice capture.
struct LiveVoiceBar: View {
    static var muteIdentifier: String { "chat.liveVoice.mute" }
    static var endIdentifier: String { "chat.liveVoice.end" }
    static var stateIdentifier: String { "chat.liveVoice.state" }

    static func statusText(approvalSummary: String?) -> String {
        let summary = approvalSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? "Listening" : summary
    }

    let statusText: String
    let isMuted: Bool
    let onMute: () -> Void
    let onEnd: () -> Void

    @Environment(\.themeID) private var themeID

    var body: some View {
        HStack(spacing: 16) {
            muteButton
            stateView
            endButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .id(themeID)
    }

    private var muteButton: some View {
        Button(action: onMute) {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.appActionBold)
                .foregroundStyle(.themeFg)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.themeBgHighlight))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.muteIdentifier)
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
    }

    private var stateView: some View {
        VStack(spacing: 6) {
            LiveVoiceWaveform()
                .frame(height: 22)
            Text(statusText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(Self.stateIdentifier)
        .accessibilityLabel(statusText)
    }

    private var endButton: some View {
        Button(action: onEnd) {
            Image(systemName: "phone.down.fill")
                .font(.appActionBold)
                .foregroundStyle(ThemeColorContrast.foreground(for: Color.themeRed))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.themeRed))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.endIdentifier)
        .accessibilityLabel("End")
    }
}

private struct LiveVoiceWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                bar(at: index)
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(at index: Int) -> some View {
        let opacity = reduceMotion ? 0.7 : 0.45 + Double(index % 3) * 0.15
        let height: CGFloat = reduceMotion ? 10 : CGFloat(8 + (index % 4) * 4)
        return Capsule()
            .fill(.themeBlue.opacity(opacity))
            .frame(width: 3, height: height)
    }
}
