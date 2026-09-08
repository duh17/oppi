#if DEBUG
import SwiftUI
import UIKit

struct ReviewCommentStripScreenshotPreview: View {
    var isExpanded: Bool
    var comments: [ReviewComment] = fixtureComments

    @State private var text = ""
    @State private var textBeforeRecording: String?
    @State private var attachments: [PendingAttachment] = []
    @State private var repoPointers: [PendingFileReference] = []
    @State private var busyBehavior: StreamingBehavior = .followUp

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.themeBg
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text(isExpanded ? "Expanded review-comment stash" : "Collapsed review-comment pill")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Staged comments sit in the above-composer strip. The composer capsule stays a message field.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                ExtensionSurfacePanel(
                    surface: ExtensionSurfaceState(),
                    placement: .aboveEditor,
                    showsLeadingStripContent: true,
                    leadingStripContent: {
                        ReviewCommentStripPill(
                            count: comments.count,
                            isExpanded: isExpanded,
                            onToggle: {},
                            onOpenFullScreen: {}
                        )
                    }
                )

                if isExpanded {
                    ReviewCommentStashDrawer(
                        comments: comments,
                        focusedCommentId: nil,
                        onEdit: { _ in },
                        onDelete: { _ in }
                    )
                }

                ChatInputBar(
                    text: $text,
                    textBeforeRecording: $textBeforeRecording,
                    pendingAttachments: $attachments,
                    pendingRepoPointers: $repoPointers,
                    isBusy: false,
                    busyStreamingBehavior: $busyBehavior,
                    isSending: false,
                    pendingReviewCommentCount: comments.count,
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
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .environment(\.theme, ThemeID.dark.appTheme)
        .environment(\.themeID, .dark)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    static let fixtureComments = [
        ReviewComment(
            id: "review-comment-preview-1",
            workspaceId: "workspace-1",
            sessionId: "session-1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Name the owner of this fallback before merging.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .file,
                label: nil,
                path: "clients/apple/Oppi/Features/Chat/ChatView.swift",
                side: nil,
                startLine: 910,
                endLine: 918,
                selectedText: "showsLeadingStripContent: showsNowPlayingPill",
                languageHint: "swift",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 1,
            updatedAt: 1,
            sentAt: nil
        ),
        ReviewComment(
            id: "review-comment-preview-2",
            workspaceId: "workspace-1",
            sessionId: "session-1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Keep send-with-comments, but move this chrome out of the capsule.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .file,
                label: nil,
                path: "clients/apple/Oppi/Features/Review/ChatView.swift",
                side: nil,
                startLine: 40,
                endLine: 48,
                selectedText: "The composer should stay a message field.",
                languageHint: "swift",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 2,
            updatedAt: 2,
            sentAt: nil
        ),
        ReviewComment(
            id: "review-comment-preview-3",
            workspaceId: "workspace-1",
            sessionId: "session-1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "Keep package identity when src folders collide.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .file,
                label: nil,
                path: "packages/app/src/Foo.swift",
                side: nil,
                startLine: 12,
                endLine: 12,
                selectedText: nil,
                languageHint: "swift",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 3,
            updatedAt: 3,
            sentAt: nil
        ),
        ReviewComment(
            id: "review-comment-preview-4",
            workspaceId: "workspace-1",
            sessionId: "session-1",
            turnId: nil,
            author: .human,
            status: .staged,
            severity: nil,
            body: "This is the server copy, not the app copy.",
            attachments: nil,
            reference: ReviewCommentReference(
                source: .file,
                label: nil,
                path: "packages/server/src/Foo.swift",
                side: nil,
                startLine: 40,
                endLine: 48,
                selectedText: nil,
                languageHint: "swift",
                toolCallId: nil,
                timelineItemId: nil,
                url: nil
            ),
            createdAt: 4,
            updatedAt: 4,
            sentAt: nil
        ),
    ]
}
#endif
