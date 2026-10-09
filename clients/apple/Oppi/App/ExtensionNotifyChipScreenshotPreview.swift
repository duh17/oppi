#if DEBUG
import SwiftUI

/// Isolated composer chrome for the extension notify strip pill.
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
                Text("Extension notify sits on the above-composer strip as a glassy pill. Tap expands a drawer under the row.")
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
                    showsTrailingStripContent: true,
                    trailingStripContent: {
                        ExtensionNotifyChip(
                            state: chipState,
                            onToggleExpanded: {}
                        )
                    }
                )

                if chipState.isExpanded {
                    ExtensionNotifyDrawer(
                        state: chipState,
                        onCollapse: {},
                        onDismiss: {},
                        onOpenURL: { _ in false }
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
                        message: "See https://example.com/one and https://example.org/two for the retry notes after both links. The helper kept both URLs in one status line so the expanded card can open each separately.",
                        notifyType: "info",
                        extensionDisplayName: "Web Search"
                    ),
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4")!,
                        message: "Provider returned 502 while fetching the long status payload; the helper is still retrying the same query and will keep the previous ranking window until the next successful page.",
                        notifyType: "error",
                        extensionDisplayName: "Web Search"
                    ),
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5")!,
                        message: "Indexed 128 documents and queued another pass because the ranking window is still open for this session. Extra rows exist so the expanded list has to scroll inside the capped card.",
                        notifyType: "info",
                        extensionDisplayName: "Web Search"
                    ),
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA6")!,
                        message: "Rate limit approaching. Backing off for a few seconds before the next search_web call so the provider can recover, then the helper will resume the same query without opening a sheet.",
                        notifyType: "warning",
                        extensionDisplayName: "Web Search"
                    ),
                    ExtensionNotifyChipStore.Entry(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA7")!,
                        message: "search_web: SearXNG is reachable, but the previous page took long enough that this fifth entry should sit below the fold in the expanded card and only appear after a scroll.",
                        notifyType: "info",
                        extensionDisplayName: "Web Search"
                    ),
                ],
                isExpanded: true
            )
        }
    }
}
#endif
