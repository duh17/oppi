#if DEBUG
import SwiftUI

/// Isolated composer chrome for the extension notify chip.
struct ExtensionNotifyChipScreenshotPreview: View {
    enum Mode {
        case collapsedInfo
        case collapsedError
        case expandedMultiple
    }

    var mode: Mode

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
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Extension notify sits above the composer as a muted chip, not a Notice sheet.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(spacing: 8) {
                ExtensionNotifyChip(
                    state: chipState,
                    onToggleExpanded: {},
                    onDismiss: {},
                    onOpenURL: { _ in false }
                )

                ChatInputBar(
                    text: $text,
                    textBeforeRecording: $textBeforeRecording,
                    pendingAttachments: $attachments,
                    pendingRepoPointers: $repoPointers,
                    isBusy: false,
                    busyStreamingBehavior: $busyBehavior,
                    isSending: false,
                    pendingReviewCommentCount: 0,
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
                    actionRow: {
                        EmptyView()
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .environment(\.theme, ThemeID.dark.appTheme)
        .environment(\.themeID, .dark)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var title: String {
        switch mode {
        case .collapsedInfo:
            return "Notify chip · info"
        case .collapsedError:
            return "Notify chip · error"
        case .expandedMultiple:
            return "Notify chip · expanded"
        }
    }

    private var chipState: ExtensionNotifyChipStore.SessionState {
        switch mode {
        case .collapsedInfo:
            return ExtensionNotifyChipStore.SessionState(
                entries: [
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
                        message: "search_web: SearXNG is reachable",
                        notifyType: "info",
                        extensionDisplayName: "Web Search"
                    ),
                ],
                isExpanded: false
            )
        case .collapsedError:
            return ExtensionNotifyChipStore.SessionState(
                entries: [
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!,
                        message: "Provider returned 502",
                        notifyType: "error",
                        extensionDisplayName: "Web Search"
                    ),
                ],
                isExpanded: false
            )
        case .expandedMultiple:
            return ExtensionNotifyChipStore.SessionState(
                entries: [
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!,
                        message: "Retry succeeded",
                        notifyType: "info",
                        extensionDisplayName: "Web Search"
                    ),
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4")!,
                        message: "Provider returned 502",
                        notifyType: "error",
                        extensionDisplayName: "Web Search"
                    ),
                ],
                isExpanded: true
            )
        }
    }
}
#endif
