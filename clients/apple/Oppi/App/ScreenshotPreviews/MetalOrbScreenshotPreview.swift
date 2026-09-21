#if DEBUG
import SwiftUI

/// Isolated preview of the five Metal orb styles at production sizes.
///
/// Dictation levels are synthetic. They are not microphone capture.
struct MetalOrbScreenshotPreview: View {
    private let themeID: ThemeID
    @State private var syntheticLevel: Float = 0

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
                Text("Working rows stay 16 pt. Dictation stays 44/32 pt. Levels are synthetic, not a microphone.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

                Text("Working indicators · 16 pt")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 18) {
                    workingTile(.working)
                    workingTile(.searching)
                    workingTile(.solving)
                }

                Text("Dictation · 44 pt composing")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 12) {
                    Button("Quiet") { syntheticLevel = 0 }
                        .accessibilityIdentifier("preview.dictation.level.quiet")
                    Button("Voice") { syntheticLevel = 0.55 }
                        .accessibilityIdentifier("preview.dictation.level.voice")
                }
                .buttonStyle(.bordered)
                MicButtonLabel(
                    isRecording: true,
                    isProcessing: false,
                    audioLevel: syntheticLevel,
                    languageLabel: "EN",
                    accentColor: .themeBlue,
                    engineBadge: .onDevice,
                    diameter: 44,
                    dictationStyle: .composing
                )
                .accessibilityIdentifier("preview.dictation.composing.44")
                Text(syntheticLevel > 0 ? "Synthetic voice" : "Synthetic quiet")
                    .font(.caption2)
                    .foregroundStyle(.themeComment)

                Text("Dictation · 32 pt / Ring")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 16) {
                    dictationTile(.composing, diameter: 32, level: 0.2, caption: "Composing")
                    dictationTile(.breathing, diameter: 32, level: 0.2, caption: "Breathing")
                    dictationTile(.ring, diameter: 44, level: 0.4, caption: "Ring")
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

    private func workingTile(_ style: SpinnerStyle) -> some View {
        VStack(spacing: 8) {
            WorkingSpinnerView(tintColor: .themeFg, style: style, side: 16)
                .frame(width: 16, height: 16)
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
