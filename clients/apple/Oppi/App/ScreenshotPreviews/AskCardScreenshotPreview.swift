#if DEBUG
import SwiftUI

// MARK: - Ask Card Long Composer Preview

struct AskCardLongComposerPreview: View {
    @State private var text = "Delete the CLI for Oppi sessions. We will use the Oppi CLI, and if we want to start Pi in Herdr, we can have a dedicated Herdr skill. I no longer use cmux or tmux, so we can clean those up completely. Keep the visible launch path separate and remove the old session lifecycle commands."
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = []
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .steer
    @State private var voiceInputManager = VoiceInputManager()
    @State private var focusRequestID = 0

    private static let request = AskRequest(
        id: "preview-long-composer",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "cleanup-scope",
                question: "The session launcher still supports visible Herdr, cmux, and tmux launches. How far should the cleanup go?",
                options: [
                    AskOption(
                        value: "preserve-visible",
                        label: "Delete the CLI, preserve visible launch",
                        description: "Move Herdr launching behind the dedicated launch tool."
                    ),
                    AskOption(
                        value: "launch-only",
                        label: "Keep a launch-only helper",
                        description: "Remove lifecycle commands but keep a private launcher."
                    ),
                    AskOption(
                        value: "remove-runtimes",
                        label: "Delete CLI and visible runtimes",
                        description: "Keep only Oppi-owned session creation."
                    ),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Long custom ask response")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("The answer should scroll inside the composer instead of crossing its bottom edge.")
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
                isBusy: true,
                busyStreamingBehavior: $busyBehavior,
                isSending: false,
                sendProgressText: nil,
                isStopping: false,
                voiceInputManager: voiceInputManager,
                showForceStop: false,
                isForceStopInFlight: false,
                askRequest: Self.request,
                onAskSubmit: { _, _, complete in complete(.completed) },
                onAskIgnoreAll: { _, complete in complete(.completed) },
                slashCommands: [],
                fileSuggestions: [],
                onFileSuggestionQuery: nil,
                onSend: {},
                onStop: {},
                onForceStop: {},
                onExpand: {},
                externalFocusRequestID: focusRequestID,
                appliesOuterPadding: true,
                alwaysShowActionRow: true
            ) {
                Spacer(minLength: 0)

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
        .task {
            try? await Task.sleep(for: .milliseconds(550))
            focusRequestID &+= 1
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}


// MARK: - Ask Card Preview

private enum AskCardPreviewFixture {
    static let request: AskRequest = {
        let permissionRequest = ExtensionUIRequest(
            id: "preview-permission-gate",
            sessionId: "preview-session",
            method: "select",
            title: """
            Git push

            Pushing writes to a remote repository.

            ### Command

            ```bash
            git push origin main
            ```

            Allow this tool call?

              Allow once: Run this tool call now
              Deny: Block the tool call
            """,
            options: ["Allow once", "Deny"]
        )

        return permissionRequest.inlineAskRequest ?? AskRequest(
            id: "preview-permission-gate",
            sessionId: "preview-session",
            questions: [
                AskQuestion(
                    id: ExtensionUIRequest.inlineQuestionId,
                    question: "Git push",
                    options: [
                        AskOption(value: "Allow once", label: "Allow once", description: "Run this tool call now"),
                        AskOption(value: "Deny", label: "Deny", description: "Block the tool call"),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionSelect
        )
    }()

    static let oppiCommandApprovalRequest: AskRequest = {
        let longPrompt = """
        Review the complete implementation and tests before changing any files.

        Treat Markdown such as **bold text** and command-looking content such as `rm -rf /not-executed` as prompt text only.

        """ + (1...28).map { "Inspection detail line \($0): preserve this complete approval body." }.joined(separator: "\n") + """


        END OF COMPLETE PROMPT — report any rebuild requirements.
        """
        let request = ExtensionUIRequest(
            id: "preview-oppi-command-approval",
            sessionId: "preview-session",
            method: "confirm",
            title: "Approve Oppi command",
            message: """
            Create or modify Oppi state with session create.

            ## Command

            ```text
            oppi session create
            ```

            ## Workspace

            ```text
            zs1JP9sA
            ```

            ## Arguments

            ```text
            --model gpt-5.5
            ```

            ## Prompt

            ````text
            \(longPrompt)
            ````
            """
        )
        return request.inlineAskRequest ?? AskCardPreviewFixture.request
    }()

    static let multiSelectLongOptionsRequest = AskRequest(
        id: "preview-multi-select-long-options",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "sun_light_nav",
                question: "Sun, light, navigation, comms — select what is ready.",
                options: [
                    AskOption(
                        value: "offline_maps_gpx",
                        label: "Offline maps/GPX loaded on phone/GPS with route, waypoints, and alternate descent cached",
                        description: "CalTopo or Gaia route opens in airplane mode; phone/GPS battery plan tested so this last description line fills the option row width."
                    ),
                    AskOption(
                        value: "weather_window",
                        label: "Weather window confirmed",
                        description: "Clear forecast."
                    ),
                    AskOption(
                        value: "inreach_radio_power",
                        label: "inReach/radios/battery bank tested with messages, charging cables, and team channel confirmed"
                    ),
                    AskOption(
                        value: "headlamp_backup",
                        label: "Headlamp + spare batteries/backup lamp in top pocket, not buried in the pack"
                    ),
                ],
                multiSelect: true
            ),
            AskQuestion(
                id: "food_water",
                question: "Food and water — select what is ready.",
                options: [
                    AskOption(value: "water_capacity", label: "4–5 L water capacity"),
                    AskOption(value: "electrolytes", label: "Electrolytes / salt plan"),
                ],
                multiSelect: true
            ),
        ],
        allowCustom: true,
        timeout: nil
    )

    static let customAnswerRequest = AskRequest(
        id: "preview-expanded-custom",
        sessionId: "preview-session",
        questions: [
            AskQuestion(
                id: "guide-scope",
                question: "How should the session-link guide and invite handling change?",
                options: [
                    AskOption(
                        value: "full",
                        label: "Sol's full C",
                        description: "Guide split + accept only session links + stop invite fallthrough"
                    ),
                    AskOption(
                        value: "guide-invite",
                        label: "Guide + invite fix",
                        description: "Clarify syntax and stop the toast; do not accept the hybrid"
                    ),
                    AskOption(
                        value: "guide-only",
                        label: "Guide only",
                        description: "Make the file vs session split unmistakable; leave runtime as-is"
                    ),
                    AskOption(
                        value: "handling-only",
                        label: "Handling only",
                        description: "Accept the hybrid and fix invite fallthrough; leave the guide"
                    ),
                    AskOption(
                        value: "docs-only",
                        label: "Docs only",
                        description: "Leave runtime and invite handling alone"
                    ),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil
    )
}


struct AskCardPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var lastAction = "Waiting for answer"

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    WorkingSpinnerView(tintColor: .themeComment.opacity(0.8), style: .brailleDots)
                        .frame(width: 14, height: 14)
                    Text("working…")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.themeComment.opacity(0.7))
                }
                .padding(.horizontal, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    AskCard(
                        request: AskCardPreviewFixture.request,
                        currentPage: $currentPage,
                        answers: $answers,
                        onSubmit: { submittedAnswers, complete in
                            lastAction = AskResponseEncoder.encode(submittedAnswers)
                            complete(.completed)
                        },
                        onIgnoreAll: { complete in
                            lastAction = "Ignored"
                            complete(.completed)
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "mic")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))

                        Text("Type answer…")
                            .font(.title2)
                            .foregroundStyle(.themeComment)

                        Spacer()

                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    HStack {
                        Text(lastAction)
                            .font(.caption)
                            .foregroundStyle(.themeComment.opacity(0.75))
                            .lineLimit(1)

                        Spacer()

                        Label("gpt-5.5", systemImage: "sparkle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themeBgHighlight, in: Capsule())

                        Text("max")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeFg)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.themeBgHighlight, in: Capsule())
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }
                .background(Color.themeBg.opacity(0.96), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct AskCardMultiSelectLongOptionsPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var lastAction = "Waiting for answer"

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    WorkingSpinnerView(tintColor: .themeComment.opacity(0.8), style: .brailleDots)
                        .frame(width: 14, height: 14)
                    Text("working…")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.themeComment.opacity(0.7))
                }
                .padding(.horizontal, 18)

                Spacer()

                VStack(alignment: .leading, spacing: 0) {
                    AskCard(
                        request: AskCardPreviewFixture.multiSelectLongOptionsRequest,
                        currentPage: $currentPage,
                        answers: $answers,
                        onSubmit: { submittedAnswers, complete in
                            lastAction = AskResponseEncoder.encode(submittedAnswers)
                            complete(.completed)
                        },
                        onIgnoreAll: { complete in
                            lastAction = "Ignored"
                            complete(.completed)
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    HStack(alignment: .center, spacing: 14) {
                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "mic")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))

                        Text("Select options or type…")
                            .font(.title2)
                            .foregroundStyle(.themeComment)

                        Spacer()

                        Circle()
                            .fill(Color.themeBgHighlight)
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.themeFg)
                            )
                            .frame(width: 58, height: 58)
                            .overlay(Circle().stroke(Color.themeComment.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    Text(lastAction)
                        .font(.caption)
                        .foregroundStyle(.themeComment.opacity(0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
                }
                .background(Color.themeBg.opacity(0.96), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.themeComment.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 24)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct AskCardExpandedSheetPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var isExpanded = true
    @State private var expandedSheetDetent: PresentationDetent = .large

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Ask card")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Expanded sheet preview")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
            }
        }
        .sheet(isPresented: $isExpanded) {
            AskCardExpanded(
                request: AskCardPreviewFixture.oppiCommandApprovalRequest,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                onSubmit: { _ in },
                onIgnoreAll: {}
            )
            .presentationDetents([.medium, .large], selection: $expandedSheetDetent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .onAppear { isExpanded = true }
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct AskCardExpandedCustomPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var isExpanded = true
    @State private var expandedSheetDetent: PresentationDetent = .medium
    @State private var voiceInputManager = VoiceInputManager()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Ask card")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Expanded custom answer preview")
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
            }
        }
        .sheet(isPresented: $isExpanded) {
            AskCardExpanded(
                request: AskCardPreviewFixture.customAnswerRequest,
                currentPage: $currentPage,
                answers: $answers,
                isExpanded: $isExpanded,
                voiceInputManager: voiceInputManager,
                sheetDetent: $expandedSheetDetent,
                onSubmit: { _ in },
                onIgnoreAll: {}
            )
            .presentationDetents([.medium, .large], selection: $expandedSheetDetent)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .onAppear { isExpanded = true }
        .accessibilityIdentifier("screenshot.ready")
    }
}


struct OppiCommandApprovalInlinePreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]
    @State private var lastAction = "Waiting"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 12) {
                Spacer()

                AskCard(
                    request: AskCardPreviewFixture.oppiCommandApprovalRequest,
                    currentPage: $currentPage,
                    answers: $answers,
                    onSubmit: { submitted, complete in
                        if submitted[ExtensionUIRequest.inlineQuestionId]
                            == .single(ExtensionUIRequest.confirmValue) {
                            lastAction = "Confirmed"
                        } else {
                            lastAction = "Cancelled"
                        }
                        complete(.completed)
                    },
                    onIgnoreAll: { complete in
                        lastAction = "Ignored"
                        complete(.completed)
                    }
                )

                Text(lastAction)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("ask.preview.lastAction")
            }
            .padding(16)
        }
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
