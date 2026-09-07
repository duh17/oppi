#if DEBUG
import SwiftUI

/// Parks the production Ask delay owner until the fixture releases it.
@MainActor
final class AskCardIntentRegressionSession: ObservableObject {
    @Published var pendingCount = 0
    @Published var status = "Waiting"
    @Published var askRequest: AskRequest? = AskCardIntentRegressionPreview.threeQuestionRequest
    @Published var text = ""
    @Published var textBeforeRecording: String?
    @Published var attachments: [PendingAttachment] = []
    @Published var repoPointers: [PendingFileReference] = []
    @Published var busyBehavior: StreamingBehavior = .steer

    private var continuations: [CheckedContinuation<Void, Error>] = []

    private(set) lazy var autoAdvance: AskInlineAutoAdvanceController = {
        AskInlineAutoAdvanceController(wait: { [weak self] duration in
            guard let self else { return }
            try await self.hold(duration)
        })
    }()

    var delayState: String {
        pendingCount > 0 ? "Delay pending" : "Delay idle"
    }

    private func hold(_ duration: Duration) async throws {
        _ = duration
        pendingCount += 1
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.continuations.append(continuation)
                }
            } onCancel: {
                Task { @MainActor in
                    self.failOldest()
                }
            }
        } catch {
            pendingCount = continuations.count
            throw error
        }
        pendingCount = continuations.count
    }

    func releaseAll() {
        let items = continuations
        continuations.removeAll()
        pendingCount = 0
        items.forEach { $0.resume() }
    }

    private func failOldest() {
        guard !continuations.isEmpty else {
            pendingCount = 0
            return
        }
        continuations.removeFirst().resume(throwing: CancellationError())
        pendingCount = continuations.count
    }
}

/// Lane-local Ask delayed-advance fixture. Multi-question single-select plus
/// the real composer Ignore control, with a same-id replacement button.
struct AskCardIntentRegressionPreview: View {
    @StateObject private var session = AskCardIntentRegressionSession()

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Ask intent regression")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text(session.status)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("ask.intent.status")
                Text(session.delayState)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("ask.intent.delayState")

                Button("Release delay") {
                    session.releaseAll()
                }
                .accessibilityIdentifier("ask.intent.releaseDelay")

                Button("Replace same-id content") {
                    session.askRequest = Self.replacementRequest
                    session.status = "Replaced same id"
                }
                .accessibilityIdentifier("ask.intent.replaceSameId")

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ChatInputBar(
                text: $session.text,
                textBeforeRecording: $session.textBeforeRecording,
                pendingAttachments: $session.attachments,
                pendingRepoPointers: $session.repoPointers,
                isBusy: true,
                busyStreamingBehavior: $session.busyBehavior,
                isSending: false,
                sendProgressText: nil,
                isStopping: false,
                showForceStop: false,
                isForceStopInFlight: false,
                askRequest: session.askRequest,
                onAskSubmit: { _ in
                    session.status = "Submitted"
                },
                onAskIgnoreAll: {
                    session.status = "Ignored all"
                },
                autoAdvanceController: session.autoAdvance,
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: {},
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: 0,
                appliesOuterPadding: true,
                alwaysShowActionRow: true,
                actionRow: {
                    Spacer(minLength: 0)
                }
            )
        }
        .onAppear {
            FeatureEducationTips.markPromptAnswered()
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    static let threeQuestionRequest = AskRequest(
        id: "ask-intent-regression",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "q1",
                question: "Intent question one?",
                options: [
                    AskOption(value: "alpha", label: "Alpha"),
                    AskOption(value: "bravo", label: "Bravo"),
                ],
                multiSelect: false
            ),
            AskQuestion(
                id: "q2",
                question: "Intent question two?",
                options: [
                    AskOption(value: "charlie", label: "Charlie"),
                    AskOption(value: "delta", label: "Delta"),
                ],
                multiSelect: false
            ),
            AskQuestion(
                id: "q3",
                question: "Intent question three?",
                options: [
                    AskOption(value: "echo", label: "Echo"),
                    AskOption(value: "foxtrot", label: "Foxtrot"),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: false,
        timeout: nil
    )

    static let replacementRequest = AskRequest(
        id: "ask-intent-regression",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "only",
                question: "Intent replacement only?",
                options: [
                    AskOption(value: "zulu", label: "Zulu"),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: false,
        timeout: nil
    )
}
#endif
