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
                alwaysShowActionRow: true,
                actionRow: .previewModelThinking
            )
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

// MARK: - Live Voice Composer Preview

/// A Live Voice call in the chat input bar, with a synthetic meter standing in for the
/// call's audio taps. `live-voice-composer` walks a whole call (draft set aside, connect,
/// listen, talk, reply, mute, end with the draft back); the suffixed screens hold one step.
/// `SCREENSHOT_DICTATION_STYLE` (`ring`, `breathing`, `composing`) picks the indicator.
struct LiveVoiceComposerPreview: View {
    enum Step: String, CaseIterable {
        case draft, connecting, listening, talking, speaking, muted, restored
    }

    let pinned: Step?

    @State private var draft = ChatComposerDraftController(initialText: "Draft from before the call")
    @State private var step: Step = .draft
    @State private var transcript = ""
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = []
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .steer
    private let meter = LiveVoiceAudioMeter()

    private static let spoken = "check whether the server tests pass on main"

    init(pinned: Step?) {
        self.pinned = pinned
        if let style = ProcessInfo.processInfo.environment["SCREENSHOT_DICTATION_STYLE"] {
            ScreenshotVolatileDefaults.apply([AppPreferenceStore.Appearance.dictationIndicatorStyleKey: style])
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Text("Live Voice in the composer")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Step: \(step.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("liveVoice.preview.step")
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ChatInputBar(
                text: Binding(
                    get: { draft.text },
                    set: { draft.updateVisibleText($0, for: .message) }
                ),
                textBeforeRecording: $textBeforeRecording,
                pendingAttachments: $attachments,
                pendingRepoPointers: $repoPointers,
                isBusy: false,
                busyStreamingBehavior: $busyBehavior,
                isSending: false,
                sendProgressText: nil,
                isStopping: false,
                liveVoiceCall: call,
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
                actionRow: .previewModelThinking
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
        .task { await run() }
    }

    private var call: ComposerLiveVoiceCall? {
        switch step {
        case .draft, .restored:
            return nil
        case .connecting, .listening, .talking, .speaking, .muted:
            return ComposerLiveVoiceCall(
                isLive: true,
                isConnecting: step == .connecting,
                isMuted: step == .muted,
                isSpeaking: step == .speaking,
                status: status,
                transcript: step == .talking ? transcript : "",
                meter: meter,
                onToggleMute: {},
                onEnd: {}
            )
        }
    }

    private var status: String {
        switch step {
        case .connecting: "Connecting"
        case .speaking: "Speaking"
        case .muted: "Muted"
        default: "Listening"
        }
    }

    private func enter(_ next: Step) {
        let wasInCall = call != nil
        step = next
        let inCall = call != nil
        if inCall, !wasInCall { draft.setAsideMessage() }
        if !inCall, wasInCall { draft.restoreSetAsideMessage() }
    }

    private func run() async {
        let feed = Task { await feedMeter() }
        defer { feed.cancel() }
        if let pinned {
            if pinned == .restored { enter(.listening) }
            if pinned == .talking { transcript = Self.spoken }
            enter(pinned)
            try? await Task.sleep(for: .seconds(3_600))
            return
        }
        let script: [(Step, Duration)] = [
            (.draft, .seconds(2)), (.connecting, .seconds(1.5)), (.listening, .seconds(2)),
            (.talking, .zero), (.speaking, .seconds(4)), (.muted, .seconds(2.5)), (.restored, .seconds(3)),
        ]
        for (next, hold) in script {
            enter(next)
            if next == .talking {
                let words = Self.spoken.split(separator: " ")
                for count in 1...words.count {
                    transcript = words.prefix(count).joined(separator: " ")
                    try? await Task.sleep(for: .milliseconds(350))
                }
                try? await Task.sleep(for: .seconds(1))
                transcript = ""
            }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
        }
    }

    /// Speech-like levels at the tap's cadence: the mic while the user talks, the reply's
    /// voice while the agent speaks, room quiet otherwise.
    private func feedMeter() async {
        let start = Date()
        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            let syllable = Float(abs(sin(t * 7.3)) * (0.55 + 0.45 * abs(sin(t * 1.7))))
            var voice = VoiceSpectrumFrame(level: 0.15 + 0.7 * syllable, flux: 6 * syllable)
            for band in 0..<5 {
                voice.bands[band] = Float(0.2 + 0.8 * abs(sin(t * (3.1 + Double(band) * 1.9) + Double(band))))
                    * syllable
            }
            meter.publishMic(step == .talking ? voice : .zero)
            meter.publishPlayback(step == .speaking ? voice : .zero)
            try? await Task.sleep(for: .milliseconds(21))
        }
    }
}
#endif
