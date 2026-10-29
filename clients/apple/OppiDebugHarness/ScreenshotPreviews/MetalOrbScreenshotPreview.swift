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
                Text("Working rows stay 20 pt. Dictation stays 44/32 pt. Levels are synthetic, not a microphone. Dictation orbs stay still at quiet.")
                    .font(.footnote)
                    .foregroundStyle(.themeComment)

                Text("Working indicators · 20 pt")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                HStack(spacing: 18) {
                    workingTile(.working)
                    workingTile(.searching)
                    workingTile(.solving)
                    workingTile(.gameOfLife)
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
            PreviewSpinner(tintColor: .themeFg, style: style, side: 20)
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
            PreviewDictationDisc(
                voiceSpectrum: VoiceSpectrumFrame(
                    level: level,
                    bands: SIMD8(level * 2, level, 0, 0, level * 0.5, 0, 0, 0)
                ),
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

/// A listening on-device dictation disc in one indicator style, so the tiles show
/// every style side by side. The app's `MicButtonChromeView` follows the Settings
/// choice instead.
private struct PreviewDictationDisc: View {
    let voiceSpectrum: VoiceSpectrumFrame
    let diameter: CGFloat
    let dictationStyle: DictationIndicatorStyle

    var body: some View {
        let level = CGFloat(min(max(voiceSpectrum.level, 0), 1))
        ZStack {
            if let orbStyle = dictationStyle.orbStyle {
                OrbView(
                    style: orbStyle,
                    sizeClass: .dictation(side: Double(diameter)),
                    tint: .themeBlue,
                    voiceSpectrum: voiceSpectrum,
                    isActive: true
                )
            } else {
                Circle().fill(Color.themeBgHighlight)
                Circle()
                    .stroke(Color.themeBlue, lineWidth: 1.5 + level * 2.0)
                    .animation(.easeOut(duration: 0.1), value: voiceSpectrum.level)
                Text("EN")
                    .font(.system(size: diameter * 0.4, weight: .bold))
                    .foregroundStyle(Color.themeBlue)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}

/// One spinner style at a fixed size, so the tiles show every style side by
/// side. The app's `WorkingSpinnerUIView` follows the Settings choice instead.
private struct PreviewSpinner: View {
    let tintColor: Color
    let style: SpinnerStyle
    let side: CGFloat

    var body: some View {
        switch style {
        case .working, .searching, .solving:
            if let orbStyle = style.orbStyle {
                OrbView(style: orbStyle, sizeClass: .working(side: Double(side)), tint: tintColor)
            }
        case .brailleDots:
            BrailleSpinner(tintColor: tintColor)
        case .gameOfLife:
            GameOfLifeSpinner(tintColor: tintColor)
        }
    }

    private struct GameOfLifeSpinner: UIViewRepresentable {
        let tintColor: Color

        func makeUIView(context: Context) -> GameOfLifeUIView {
            let view = GameOfLifeUIView(gridSize: 6)
            view.tintUIColor = UIColor(tintColor)
            return view
        }

        func updateUIView(_ uiView: GameOfLifeUIView, context: Context) {
            uiView.tintUIColor = UIColor(tintColor)
        }
    }

    private struct BrailleSpinner: UIViewRepresentable {
        let tintColor: Color

        func makeUIView(context: Context) -> BrailleSpinnerUIView {
            let view = BrailleSpinnerUIView()
            view.tintUIColor = UIColor(tintColor)
            return view
        }

        func updateUIView(_ uiView: BrailleSpinnerUIView, context: Context) {
            uiView.tintUIColor = UIColor(tintColor)
        }
    }
}
#endif
