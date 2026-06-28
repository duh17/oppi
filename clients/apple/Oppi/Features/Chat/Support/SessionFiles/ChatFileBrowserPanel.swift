import SwiftUI

/// Top-level tab for the chat-attached file browser.
///
/// Stored per session so review work keeps returning to the user's last mode.
enum ChatFileBrowserPanelTab: String, CaseIterable, Identifiable, Sendable {
    case changed
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changed: return "Changed"
        case .all: return "All"
        }
    }

    var systemImageName: String {
        switch self {
        case .changed: return "doc.badge.clock"
        case .all: return "folder"
        }
    }
}

/// UserDefaults-backed selected-tab store for chat file panels.
struct ChatFileBrowserPanelTabStore {
    static var shared: ChatFileBrowserPanelTabStore { ChatFileBrowserPanelTabStore() }

    private let defaults: UserDefaults
    private let key = "\(AppIdentifiers.subsystem).chatFileBrowser.selectedTabsBySession"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func tab(for sessionId: String) -> ChatFileBrowserPanelTab {
        guard let sessionId = normalizedSessionId(sessionId) else { return .changed }
        let rawValue = storedTabs()[sessionId]
        return rawValue.flatMap(ChatFileBrowserPanelTab.init(rawValue:)) ?? .changed
    }

    func setTab(_ tab: ChatFileBrowserPanelTab, for sessionId: String) {
        guard let sessionId = normalizedSessionId(sessionId) else { return }
        var tabs = storedTabs()
        tabs[sessionId] = tab.rawValue
        defaults.set(tabs, forKey: key)
    }

    private func storedTabs() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func normalizedSessionId(_ sessionId: String) -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ChatFileBrowserPanelLayoutStyle: Equatable {
    case sideRail
    case bottomPanel
}

enum ChatFileBrowserPanelLayout {
    static func style(for size: CGSize) -> ChatFileBrowserPanelLayoutStyle {
        size.width >= 700 ? .sideRail : .bottomPanel
    }

    static func sideRailWidth(for size: CGSize) -> CGFloat {
        min(max(size.width * 0.34, 320), 460)
    }

    static func bottomPanelHeight(for size: CGSize) -> CGFloat {
        min(max(size.height * 0.38, 260), 460)
    }
}

/// Reusable chat file surface that can live in a side rail, bottom split, or sheet.
struct ChatFileBrowserPanel: View {
    let sessionId: String
    let workspaceId: String?
    let changedFiles: [String]
    @Binding var selectedTab: ChatFileBrowserPanelTab
    var fileDetailReviewCommentScope: ReviewCommentSelectionScope?

    @State private var changedSearchText = ""

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider().overlay(Color.themeComment.opacity(0.18))

            content
                .id(selectedTab)
        }
        .background(Color.themeBg)
        .onAppear {
            ClientLog.info("FileBrowser", "Chat file panel appeared", metadata: [
                "sessionId": sessionId,
                "workspaceId": workspaceId ?? "none",
                "selectedTab": selectedTab.rawValue,
                "changedFileCount": String(changedFiles.count),
            ])
        }
        .onDisappear {
            ClientLog.info("FileBrowser", "Chat file panel disappeared", metadata: [
                "sessionId": sessionId,
                "workspaceId": workspaceId ?? "none",
                "selectedTab": selectedTab.rawValue,
            ])
        }
        .onChange(of: selectedTab) { _, newValue in
            ClientLog.info("FileBrowser", "Chat file panel tab changed", metadata: [
                "sessionId": sessionId,
                "workspaceId": workspaceId ?? "none",
                "selectedTab": newValue.rawValue,
            ])
        }
    }

    private var subtitle: String {
        switch selectedTab {
        case .changed:
            let count = changedFiles.count
            if count == 1 { return "1 file changed in this session" }
            return "\(count) files changed in this session"
        case .all:
            return "Workspace file browser"
        }
    }

    private var tabPicker: some View {
        Picker("File browser mode", selection: $selectedTab) {
            ForEach(ChatFileBrowserPanelTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .changed:
            VStack(spacing: 0) {
                changedFileSearchField
                SessionFilesListView(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    changedFiles: changedFiles,
                    searchText: changedSearchText,
                    fileDetailReviewCommentScope: fileDetailReviewCommentScope
                )
            }
            .background(Color.themeBgDark)
        case .all:
            if let workspaceId {
                FileBrowserView(
                    workspaceId: workspaceId,
                    initialPath: "",
                    layoutMode: .compactOnly,
                    contentChromeMode: .treePane
                )
            } else {
                ContentUnavailableView(
                    "No Workspace",
                    systemImage: "folder.badge.questionmark",
                    description: Text("This session is not attached to a workspace.")
                )
                .background(Color.themeBgDark)
            }
        }
    }

    private var changedFileSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.themeComment)

            TextField("Search changed files", text: $changedSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body)
                .foregroundStyle(.themeFg)

            if !changedSearchText.isEmpty {
                Button {
                    changedSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.themeComment)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear changed-file search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .background(Color.themeBgHighlight.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.themeBg)
    }
}
