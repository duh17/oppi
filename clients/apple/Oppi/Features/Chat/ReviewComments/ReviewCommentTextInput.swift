import SwiftUI
import UIKit

struct ReviewCommentTextInput: View {
    @Binding var text: String
    @Binding var textBeforeRecording: String?

    var placeholder = "Comment…"
    var isDisabled = false
    var voiceInputManager: VoiceInputManager?

    @State private var visualLineCount = 1
    @State private var focusRequestID = 0
    @State private var suppressKeyboard = false
    @State private var keyboardLanguage: String?

    private let actionVisualDiameter: CGFloat = 32
    private let horizontalPadding: CGFloat = 12

    private var displayText: String {
        ComposerShared.currentComposerText(
            storedText: text,
            textBeforeRecording: textBeforeRecording,
            liveTranscript: voiceInputManager?.currentTranscript
        )
    }

    private var correctionRangesForDisplay: [NSRange] {
        guard let manager = voiceInputManager,
              let prefix = textBeforeRecording else { return [] }
        let offset = (prefix as NSString).length
        return manager.currentTranscriptCorrectionRanges.map { range in
            NSRange(location: range.location + offset, length: range.length)
        }
    }

    private var allowKeyboardRestoreOnTap: Bool {
        guard let manager = voiceInputManager else { return true }
        return ChatInputBar<EmptyView>.allowKeyboardRestoreOnTap(voiceState: manager.state)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if ReleaseFeatures.voiceInputEnabled, let manager = voiceInputManager {
                inlineMicButton(manager: manager)
                    .fixedSize()
            }

            ZStack(alignment: .leading) {
                if displayText.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.themeComment)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }

                PastableTextView(
                    text: $text,
                    placeholder: "",
                    font: .preferredFont(forTextStyle: .body),
                    textColor: UIColor(Color.themeFg),
                    tintColor: UIColor(Color.themeBlue),
                    volatileSuffixLength: voiceInputManager?.currentTranscriptVolatileSuffixLength ?? 0,
                    correctionRanges: correctionRangesForDisplay,
                    maxLines: 10,
                    autocorrectionEnabled: true,
                    onPasteImages: { _ in },
                    onCommandEnter: nil,
                    onAlternateEnter: nil,
                    onOverflowChange: nil,
                    onLineCountChange: { visualLineCount = max($0, 1) },
                    onFocusChange: nil,
                    onDictationStateChange: nil,
                    focusRequestID: focusRequestID,
                    blurRequestID: 0,
                    dictationRequestID: 0,
                    suppressKeyboard: suppressKeyboard,
                    allowKeyboardRestoreOnTap: allowKeyboardRestoreOnTap,
                    onKeyboardRestoreRequest: {
                        ComposerShared.handleKeyboardRestore(
                            suppressKeyboard: $suppressKeyboard,
                            textBeforeRecording: $textBeforeRecording,
                            voiceInputManager: voiceInputManager
                        )
                    },
                    accessibilityIdentifier: "reviewComment.input",
                    keyboardLanguage: $keyboardLanguage
                )
                .disabled(isDisabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 7)
        .frame(minHeight: 46)
        .background(Color.themeBgHighlight.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
        }
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty {
                visualLineCount = 1
            }
        }
        .onChange(of: voiceInputManager?.transcriptPresentationRevision) { _, _ in
            guard let prefix = textBeforeRecording, let manager = voiceInputManager else { return }
            text = prefix + manager.currentTranscript
        }
        .onChange(of: keyboardLanguage) { _, newLanguage in
            guard ReleaseFeatures.voiceInputEnabled,
                  let manager = voiceInputManager,
                  AppPreferences.Keyboard.normalize(newLanguage) != nil else { return }
            Task {
                await manager.prewarm(
                    keyboardLanguage: newLanguage,
                    source: "review_comment_keyboard_change"
                )
            }
        }
    }

    private func inlineMicButton(manager: VoiceInputManager) -> some View {
        let isRecording = manager.isRecording
        let isPreparing = manager.isPreparing
        let isProcessing = manager.isProcessing

        return Button {
            Task { @MainActor in
                await handleMicTap(manager: manager)
            }
        } label: {
            MicButtonLabel(
                isRecording: isRecording,
                isProcessing: isPreparing || isProcessing,
                audioLevel: manager.audioLevel,
                languageLabel: manager.activeLanguageLabel,
                accentColor: .themeBlue,
                engineBadge: ComposerShared.micEngineBadge(for: manager),
                diameter: actionVisualDiameter
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isProcessing)
        .accessibilityIdentifier("reviewComment.voiceInput")
        .accessibilityLabel(ComposerShared.accessibilityLabel(isRecording: isRecording, isPreparing: isPreparing))
        .accessibilityValue(ComposerShared.voiceRouteAccessibilityValue(for: manager))
    }

    @MainActor
    private func handleMicTap(manager: VoiceInputManager) async {
        switch manager.state {
        case .recording:
            let prefix = textBeforeRecording ?? ""
            let transcript = await manager.stopRecording()
            textBeforeRecording = nil
            if !transcript.isEmpty {
                text = prefix + transcript
            }
        case .preparingModel:
            await manager.cancelRecording()
            textBeforeRecording = nil
            suppressKeyboard = false
        case .idle:
            textBeforeRecording = Self.dictationPrefix(for: text)
            suppressKeyboard = true
            focusRequestID += 1
            do {
                try await manager.startRecording(
                    keyboardLanguage: keyboardLanguage,
                    source: "review_comment_mic_tap"
                )
            } catch {
                textBeforeRecording = nil
                suppressKeyboard = false
            }
        case .processing, .error:
            break
        }
    }

    static func dictationPrefix(for base: String) -> String {
        if base.isEmpty || base.last?.isWhitespace == true {
            return base
        }
        return base + " "
    }
}
