#if DEBUG
import SwiftUI

/// Isolated preview of the five Metal orb styles at production sizes.
///
/// Dictation levels are synthetic. They are not microphone capture.
struct MetalOrbScreenshotPreview: View {
    private let themeID: ThemeID
    @State private var voiceHeld = false

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Metal activity and dictation orbs")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text("Working rows stay 20 pt. Dictation stays 44/32 pt. Levels are synthetic, not a microphone. Orbs keep moving at quiet.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

                Text("Working indicators · 20 pt")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 18) {
                    workingTile(.working)
                    workingTile(.searching)
                    workingTile(.solving)
                }

                Text("Dictation · Composing / Breathing")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 12) {
                    Button("Quiet") { voiceHeld = false }
                        .accessibilityIdentifier("preview.dictation.level.quiet")
                    Button("Voice") { voiceHeld = true }
                        .accessibilityIdentifier("preview.dictation.level.voice")
                }
                .buttonStyle(.bordered)
                Text(voiceHeld ? "Synthetic modest-speech envelope (preview only)" : "Synthetic quiet")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !voiceHeld)) { context in
                    let level = previewVoiceLevel(at: context.date)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            dictationTile(.composing, diameter: 44, level: level, caption: "Composing 44")
                            dictationTile(.breathing, diameter: 44, level: level, caption: "Breathing 44")
                        }
                        HStack(spacing: 16) {
                            dictationTile(.composing, diameter: 32, level: level, caption: "Composing 32")
                            dictationTile(.breathing, diameter: 32, level: level, caption: "Breathing 32")
                            dictationTile(.ring, diameter: 44, level: level, caption: "Ring")
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 400, alignment: .leading)
        }
        .background(Color.themeBg.ignoresSafeArea())
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .onAppear { ThemeRuntimeState.setThemeID(themeID) }
        .accessibilityIdentifier("screenshot.ready")
    }

    private func previewVoiceLevel(at date: Date) -> Float {
        guard voiceHeld else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate * 2.2
        return Float(0.16 + 0.22 * (0.5 + 0.5 * sin(phase)))
    }

    private func workingTile(_ style: SpinnerStyle) -> some View {
        VStack(spacing: 8) {
            WorkingSpinnerView(tintColor: .themeFg, style: style, side: 20)
                .frame(width: 20, height: 20)
            Text(style.displayName)
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
        .frame(width: 72)
        .accessibilityIdentifier("preview.working.\(style.rawValue)")
    }

    private func dictationTile(
        _ style: DictationIndicatorStyle,
        diameter: CGFloat,
        level: Float,
        caption: String
    ) -> some View {
        VStack(spacing: 8) {
            MicButtonLabel(
                isRecording: true,
                isProcessing: false,
                audioLevel: level,
                languageLabel: "EN",
                accentColor: .themeBlue,
                engineBadge: .onDevice,
                diameter: diameter,
                dictationStyle: style
            )
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.themeComment)
                .multilineTextAlignment(.center)
        }
        .frame(width: max(72, diameter + 12))
        .accessibilityIdentifier("preview.dictation.\(style.rawValue).\(Int(diameter))")
    }
}
#endif
