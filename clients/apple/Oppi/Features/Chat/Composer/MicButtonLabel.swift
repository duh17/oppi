import SwiftUI

/// Mic button label with three states:
/// - **Idle:** mic icon on neutral background
/// - **Preparing / recording:** ring or Metal orb
/// - **Processing:** spinner
///
/// New orb styles show only the orb. Language and engine stay in accessibility.
struct MicButtonLabel: View {
    enum EngineBadge: Equatable, Sendable {
        case auto
        case onDevice
        case remote
    }

    let isRecording: Bool
    let isPreparing: Bool
    let isProcessing: Bool
    let audioLevel: Float
    let languageLabel: String?
    let accentColor: Color
    let engineBadge: EngineBadge
    let diameter: CGFloat
    var dictationStyle: DictationIndicatorStyle = .current

    init(
        isRecording: Bool,
        isProcessing: Bool,
        audioLevel: Float,
        languageLabel: String?,
        accentColor: Color,
        engineBadge: EngineBadge,
        diameter: CGFloat,
        dictationStyle: DictationIndicatorStyle = .current,
        isPreparing: Bool = false
    ) {
        self.isRecording = isRecording
        self.isPreparing = isPreparing
        self.isProcessing = isProcessing
        self.audioLevel = audioLevel
        self.languageLabel = languageLabel
        self.accentColor = accentColor
        self.engineBadge = engineBadge
        self.diameter = diameter
        self.dictationStyle = dictationStyle
    }

    init(
        presentation: ComposerShared.MicButtonPresentation,
        accentColor: Color,
        diameter: CGFloat,
        dictationStyle: DictationIndicatorStyle = .current
    ) {
        self.init(
            isRecording: presentation.isRecording,
            isProcessing: presentation.isProcessing,
            audioLevel: presentation.audioLevel,
            languageLabel: presentation.languageLabel,
            accentColor: accentColor,
            engineBadge: presentation.engineBadge,
            diameter: diameter,
            dictationStyle: dictationStyle,
            isPreparing: presentation.isPreparing
        )
    }

    private var listeningChrome: Bool { isRecording || isPreparing }

    private var indicatorColor: Color {
        if !listeningChrome && !isProcessing {
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

    private var showsOrb: Bool {
        listeningChrome && !isProcessing && dictationStyle.thinkingOrbStyle != nil
    }

    var body: some View {
        let level = CGFloat(min(max(isRecording ? audioLevel : 0, 0), 1))

        ZStack {
            Circle().fill(Color.themeBgHighlight)

            if showsOrb, let orbStyle = dictationStyle.thinkingOrbStyle {
                ThinkingOrbView(
                    style: orbStyle,
                    sizeClass: .dictation(side: Double(diameter)),
                    tint: indicatorColor,
                    audioLevel: isRecording ? audioLevel : 0,
                    isActive: true
                )
            } else if isRecording {
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
            } else if showsOrb {
                EmptyView()
            } else if listeningChrome {
                if engineBadge == .remote {
                    Image(systemName: "cloud")
                        .font(.system(size: diameter * 0.38, weight: .bold))
                        .foregroundStyle(indicatorColor)
                } else {
                    Text(languageLabel ?? "??")
                        .font(.system(size: diameter * 0.4, weight: .bold))
                        .foregroundStyle(indicatorColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            } else {
                Image(systemName: "mic")
                    .font(.system(size: diameter * 0.47, weight: .bold))
                    .foregroundStyle(indicatorColor.opacity(engineBadge == .auto ? 0.75 : 1))
            }

        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .contentShape(Circle())
        .accessibilityValue(spokenAccessory)
    }

    private var spokenAccessory: String {
        var parts: [String] = []
        if let languageLabel, !languageLabel.isEmpty {
            parts.append(languageLabel)
        }
        switch engineBadge {
        case .auto: break
        case .onDevice: parts.append("On-device")
        case .remote: parts.append("Server")
        }
        return parts.joined(separator: ", ")
    }
}
