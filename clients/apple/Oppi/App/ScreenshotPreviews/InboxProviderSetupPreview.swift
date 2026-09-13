#if DEBUG
import Foundation
import SwiftUI

// MARK: - Inbox Provider Setup Preview

/// All Sessions chrome for the first-login provider-setup card.
///
/// Uses the production list-section wrapper and `SessionRow` so screenshot
/// acceptance cannot drift from inbox insets. Does not instantiate the full
/// inbox stores.
struct InboxProviderSetupPreview: View {
    @Environment(\.theme) private var theme

    let showsSessions: Bool
    @State private var searchText = ""
    @State private var composeBarColumnWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            List {
                ProviderSetupPromptListSection {
                    ProviderSetupPromptCard(
                        message: "Connect a model provider before starting a session on Preview Server.",
                        openAccessibilityIdentifier: "workspace.providerSetup.open"
                    ) {}
                }

                if showsSessions {
                    Section {
                        SessionRow(
                            presentation: SessionRowPresentationBuilder.make(
                                session: Self.previewSession,
                                workspaceContext: "oppi"
                            )
                        )
                        .listRowBackground(theme.bg.primary)
                    }
                }
            }
            .listStyle(.plain)
            .themedListSurface()
            .navigationTitle("All Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search sessions"
            )
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SessionInboxCompactComposeBar(
                        showsDictation: true,
                        columnWidth: composeBarColumnWidth,
                        onStart: {},
                        onDictate: {}
                    )
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    SessionInboxFolderToolbarButton(
                        isEnabled: false,
                        accessibilityLabel: "Open server files",
                        onOpen: {}
                    )
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { composeBarColumnWidth = $0 }
        .accessibilityIdentifier(
            ProcessInfo.processInfo.environment["SCREENSHOT_READY_ID"] ?? "screenshot.ready"
        )
    }

    private static let previewSession = Session(
        id: "preview-session",
        workspaceId: "preview-workspace",
        workspaceName: "oppi",
        name: "Review provider setup card",
        status: .ready,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastActivity: Date(timeIntervalSince1970: 1_700_000_100),
        model: "gpt-5.5",
        messageCount: 4,
        tokens: TokenUsage(input: 1_000, output: 500),
        cost: 0.12
    )
}
#endif
