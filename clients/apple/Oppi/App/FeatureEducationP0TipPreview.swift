#if DEBUG
import SwiftUI
import UIKit

private enum FeatureEducationP0TipPreviewCase: String, CaseIterable {
    case toolDetails = "tool-details"
    case outputShortcuts = "output-shortcuts"
    case changedFiles = "changed-files"
    case prompt = "prompt"
    case busySend = "busy-send"
    case reviewSelection = "review-selection"

    static var current: Self {
        let raw = ProcessInfo.processInfo.environment["FEATURE_TIP_PREVIEW_CASE"] ?? Self.toolDetails.rawValue
        return Self(rawValue: raw) ?? .toolDetails
    }

    var expectedTitle: String {
        switch self {
        case .toolDetails: "Open tool details"
        case .outputShortcuts: "Use output shortcuts"
        case .changedFiles: "Review changed files"
        case .prompt: "Answer prompts here"
        case .busySend: "Choose how to send"
        case .reviewSelection: "Comment from code"
        }
    }

    var caption: String {
        switch self {
        case .toolDetails:
            "Collapsed native tool row"
        case .outputShortcuts:
            "Expanded native tool output"
        case .changedFiles:
            "Session changed-files bar"
        case .prompt:
            "Inline ask card"
        case .busySend:
            "Busy composer send mode"
        case .reviewSelection:
            "Review-capable selectable text"
        }
    }
}

struct FeatureEducationP0TipPreview: View {
    @State private var connection = ServerConnection()
    private let previewCase = FeatureEducationP0TipPreviewCase.current

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                header

                switch previewCase {
                case .toolDetails:
                    toolRow(isExpanded: false)
                case .outputShortcuts:
                    toolRow(isExpanded: true)
                case .changedFiles:
                    changedFilesBar
                case .prompt:
                    promptCard
                case .busySend:
                    busyComposer
                case .reviewSelection:
                    reviewSelectionText
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("P0 tip")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(connection.sessionStore)
        .environment(connection.askRequestStore)
        .environment(\.apiClient, connection.apiClient)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(previewCase.expectedTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("feature-tip-p0.expected-title")

            Text(previewCase.caption)
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolRow(isExpanded: Bool) -> some View {
        FeatureEducationToolRowRepresentable(configuration: Self.toolConfiguration(isExpanded: isExpanded), width: 360)
            .frame(width: 360)
            .accessibilityIdentifier(isExpanded ? "feature-tip-p0.output-shortcuts.surface" : "feature-tip-p0.tool-details.surface")
    }

    private var changedFilesBar: some View {
        WorkspaceContextBar(
            gitStatus: Self.gitStatus,
            isLoading: false,
            appliesOuterHorizontalPadding: false,
            workspaceId: "feature-tip-workspace",
            showCleanWorkspace: false
        )
        .accessibilityIdentifier("feature-tip-p0.changed-files.surface")
    }

    private var promptCard: some View {
        FeatureEducationPromptCardPreview()
            .accessibilityIdentifier("feature-tip-p0.prompt.surface")
    }

    private var busyComposer: some View {
        FeatureEducationBusyComposerPreview()
            .accessibilityIdentifier("feature-tip-p0.busy-send.surface")
    }

    private var reviewSelectionText: some View {
        FeatureEducationReviewSelectionRepresentable()
            .frame(minHeight: 220)
            .accessibilityIdentifier("feature-tip-p0.review-selection.surface")
    }

    private static func toolConfiguration(isExpanded: Bool) -> ToolTimelineRowConfiguration {
        ToolTimelineRowConfiguration(
            itemID: isExpanded ? "feature-tip-output-shortcuts" : "feature-tip-tool-details",
            title: "bash printf feature-tip-fixture",
            preview: isExpanded ? nil : "feature-tip-output line 1\nfeature-tip-output line 2",
            expandedContent: .bash(
                command: "printf 'feature-tip-output\\n'",
                output: "feature-tip-output line 1\nfeature-tip-output line 2\nfeature-tip-output line 3",
                unwrapped: false
            ),
            copyCommandText: "printf 'feature-tip-output\\n'",
            copyOutputText: "feature-tip-output line 1\nfeature-tip-output line 2\nfeature-tip-output line 3",
            languageBadge: "bash",
            trailing: "done",
            titleLineBreakMode: .byTruncatingTail,
            toolNamePrefix: "bash",
            toolNameColor: .systemGreen,
            editAdded: nil,
            editRemoved: nil,
            collapsedImageBase64: nil,
            collapsedImageMimeType: nil,
            isExpanded: isExpanded,
            isDone: true,
            isError: false,
            startedAt: nil,
            elapsedSeconds: 1,
            segmentAttributedTitle: nil,
            segmentAttributedTrailing: nil
        )
    }

    private static let gitStatus = GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: "7b42c0d",
        ahead: 0,
        behind: 0,
        dirtyCount: 2,
        untrackedCount: 0,
        stagedCount: 0,
        files: [
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/ChatView.swift", addedLines: 12, removedLines: 3),
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift", addedLines: 8, removedLines: 2),
        ],
        totalFiles: 2,
        addedLines: 20,
        removedLines: 5,
        stashCount: 0,
        lastCommitMessage: "Wire feature tips",
        lastCommitDate: nil,
        recentCommits: []
    )
}

private struct FeatureEducationPromptCardPreview: View {
    @State private var currentPage = 0
    @State private var answers: [String: AskAnswer] = [:]

    private static let request = AskRequest(
        id: "feature-tip-prompt",
        sessionId: "feature-tip-session",
        questions: [
            AskQuestion(
                id: "approval",
                question: "Approve the fixture action?",
                options: [
                    AskOption(value: "yes", label: "Yes", description: "Continue the current session"),
                    AskOption(value: "no", label: "No", description: "Block this action"),
                ],
                multiSelect: false
            ),
        ],
        allowCustom: true,
        timeout: nil
    )

    var body: some View {
        AskCard(
            request: Self.request,
            currentPage: $currentPage,
            answers: $answers,
            onSubmit: { _ in },
            onIgnoreAll: {}
        )
        .padding(12)
        .background(Color.themeBgHighlight, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct FeatureEducationBusyComposerPreview: View {
    @State private var text = "Guide the current turn"
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = []
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .steer

    var body: some View {
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
            EmptyView()
        }
    }
}

private struct FeatureEducationReviewSelectionRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> FullScreenReviewCommentTextView {
        let textView = FullScreenReviewCommentTextView(frame: .zero, textContainer: nil)
        textView.isEditable = false
        textView.isSelectable = true
        textView.text = "Select a line in this review-capable text view to stage a review comment for your next message.\n\nThe actual app wires this to diffs, code, tool output, and full-screen readers."
        textView.font = AppFont.monoMedium
        textView.textColor = UIColor(Color.themeFg)
        textView.backgroundColor = UIColor(Color.themeBgHighlight)
        textView.layer.cornerRadius = 14
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        textView.configureReviewCommentSelection(
            router: ReviewCommentSelectionRouter(dispatch: { _ in }),
            sourceContext: ReviewCommentSourceContext(
                sessionId: "feature-tip-session",
                surface: .fullScreenCode,
                sourceLabel: "FeatureTip.swift",
                filePath: "FeatureTip.swift"
            )
        )
        return textView
    }

    func updateUIView(_ uiView: FullScreenReviewCommentTextView, context: Context) {}
}

private struct FeatureEducationToolRowRepresentable: UIViewRepresentable {
    let configuration: ToolTimelineRowConfiguration
    let width: CGFloat

    func makeUIView(context: Context) -> FeatureEducationToolRowHostView {
        FeatureEducationToolRowHostView(configuration: configuration, width: width)
    }

    func updateUIView(_ uiView: FeatureEducationToolRowHostView, context: Context) {
        uiView.update(configuration: configuration, width: width)
    }
}

private final class FeatureEducationToolRowHostView: UIView {
    private let contentView: ToolTimelineRowContentView
    private var widthConstraint: NSLayoutConstraint?
    private var targetWidth: CGFloat

    init(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        contentView = ToolTimelineRowContentView(configuration: configuration)
        targetWidth = width
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: width)
        self.widthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(configuration: ToolTimelineRowConfiguration, width: CGFloat) {
        targetWidth = width
        widthConstraint?.constant = width
        contentView.configuration = configuration
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        return contentView.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
#endif
