#if DEBUG
import SwiftUI
import UIKit

// MARK: - Chat Input Attachment Preview

struct ChatInputAttachmentContainmentPreview: View {
    @State private var text = "let’s remove this full screen text but keep the double tap to full screen also"
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = [Self.previewAttachment()]
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .followUp

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("Composer attachment containment")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("The pending image and typed text should both live inside one composer capsule.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ChatInputBar(
                text: $text,
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $attachments,
                pendingRepoPointers: $repoPointers,
                isBusy: false,
                busyStreamingBehavior: $busyBehavior,
                isSending: false,
                sendProgressText: nil,
                isStopping: false,
                showForceStop: false,
                isForceStopInFlight: false,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: {},
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: 0,
                appliesOuterPadding: false,
                alwaysShowActionRow: true
            ) {
                HStack(spacing: 6) {
                    Text("gpt-5.5")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                    Text("max")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themePurple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }

    private static func previewAttachment() -> PendingAttachment {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 112)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 18, y: 18, width: 76, height: 76))
            UIColor.white.setFill()
            context.fill(CGRect(x: 30, y: 48, width: 52, height: 16))
        }
        let data = image.pngData() ?? Data()
        return PendingAttachment(
            id: "preview-image",
            source: .image,
            displayName: "Preview image",
            thumbnail: image,
            imageAttachment: ImageAttachment(data: data.base64EncodedString(), mimeType: "image/png"),
            localFileData: nil,
            localMimeType: nil
        )
    }
}


// MARK: - Quick Session Dictation Composer Preview

struct QuickSessionDictationComposerPreview: View {
    var title: String = "Streaming dictation composer"
    var subtitle: String = "The blue volatile suffix should advance without the caret jumping backward."
    var transcriptSteps: [(String, Int)] = Self.defaultTranscriptSteps
    var initialDelay: Duration = .seconds(2)
    var stepDelay: Duration = .milliseconds(600)

    @State private var text = ""
    @State private var volatileSuffixLength = 0
    @State private var focusRequestID = 0
    @State private var keyboardLanguage: String?
    @State private var streamStep = 0
    @State private var immediateCaretSteps: Set<Int> = []
    @State private var deferredCaretSteps: Set<Int> = []

    private static let defaultTranscriptSteps = [
        ("So right now, each", 8),
        ("So right now, each of our git push", 12),
        ("So right now, each of our git push is taking quite long to finish,", 15),
        ("So right now, each of our git push is taking quite long to finish, and it actually busts our", 22),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.themeCyan)
                        .frame(width: ComposerInputMetrics.controlDiameter, height: ComposerInputMetrics.controlDiameter)
                        .background(Color.themeBgHighlight.opacity(0.72), in: Circle())

                    PastableTextView(
                        text: $text,
                        placeholder: "",
                        font: .preferredFont(forTextStyle: .body),
                        textColor: UIColor(Color.themeFg),
                        tintColor: UIColor(Color.themeBlue),
                        volatileSuffixLength: volatileSuffixLength,
                        correctionRanges: [],
                        maxLines: ComposerInputMetrics.inlineMaxLines,
                        autocorrectionEnabled: true,
                        onPasteImages: { _ in },
                        onCommandEnter: nil,
                        onAlternateEnter: nil,
                        onOverflowChange: nil,
                        onLineCountChange: nil,
                        onFocusChange: nil,
                        onDictationStateChange: nil,
                        focusRequestID: focusRequestID,
                        blurRequestID: 0,
                        dictationRequestID: 0,
                        suppressKeyboard: true,
                        allowKeyboardRestoreOnTap: false,
                        onKeyboardRestoreRequest: nil,
                        accessibilityIdentifier: "dictation.preview.input",
                        keyboardLanguage: $keyboardLanguage,
                        selectionProbeForTesting: recordSelectionProbe
                    )
                    .frame(maxWidth: .infinity)

                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.themeBg)
                        .frame(width: ComposerInputMetrics.controlDiameter, height: ComposerInputMetrics.controlDiameter)
                        .background(Color.themeBlue, in: Circle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .frame(width: ComposerInputMetrics.controlDiameter, height: ComposerInputMetrics.controlDiameter)
                        .background(Color.themeBgHighlight.opacity(0.72), in: Capsule())
                    Text("🍕 oppi")
                    Spacer()
                    Text("gpt-5.6-sol")
                    Text("high")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeFg)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.clear, lineWidth: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Dictation composer")
                    .accessibilityIdentifier("dictation.preview.composer")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("step \(streamStep)")
                    .accessibilityIdentifier("dictation.preview.step")
                Text("\(verifiedCaretStepCount)/\(transcriptSteps.count) caret steps passed")
                    .accessibilityIdentifier("dictation.preview.caretProbe")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.themeComment)
            .padding(8)
        }
        .overlay(alignment: .topLeading) {
            Text("Ready")
                .font(.caption2)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityIdentifier("screenshot.ready")
        }
        .task {
            try? await Task.sleep(for: initialDelay)
            focusRequestID &+= 1

            for (index, step) in transcriptSteps.enumerated() {
                text = step.0
                volatileSuffixLength = step.1
                streamStep = index + 1
                try? await Task.sleep(for: stepDelay)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var verifiedCaretStepCount: Int {
        immediateCaretSteps.intersection(deferredCaretSteps).count
    }

    private func recordSelectionProbe(
        phase: PastableUITextView.SelectionProbePhase,
        selection: NSRange,
        storageLength: Int
    ) {
        guard let index = transcriptSteps.firstIndex(where: {
            ($0.0 as NSString).length == storageLength
        }) else { return }
        let step = index + 1
        guard selection == NSRange(location: storageLength, length: 0) else { return }

        // The immediate callback occurs during UIViewRepresentable update.
        // Publish the probe result on the next turn instead of mutating SwiftUI
        // state from inside that update transaction.
        DispatchQueue.main.async {
            switch phase {
            case .immediate:
                immediateCaretSteps.insert(step)
            case .deferred:
                deferredCaretSteps.insert(step)
            }
        }
    }
}
#endif
