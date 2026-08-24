import SwiftUI

struct ServerSkillFileScopedDestinationView: View {
    @Environment(ConnectionCoordinator.self) private var coordinator
    let target: ServerSkillFileNavTarget

    @State private var scopedConnection: ServerConnection?

    var body: some View {
        Group {
            if let scopedConnection {
                ServerSkillFileView(target: target)
                    .withServerScopedEnvironment(scopedConnection)
            } else {
                ProgressView("Connecting…")
            }
        }
        .task(id: target.serverId) {
            guard await coordinator.switchToServerReady(target.serverId) else { return }
            scopedConnection = coordinator.connection(for: target.serverId)
        }
    }
}

enum ServerSkillFilePresentation: Equatable {
    case editable(hostPath: String)
    case editingUnavailable(reason: String)
    case readOnly

    static func resolve(
        editable: Bool,
        resourcePath: String?,
        selectedFilePath: String
    ) -> Self {
        guard editable else { return .readOnly }
        guard let resourcePath else {
            return .editingUnavailable(
                reason: "Editing is unavailable because the server did not provide this Skill’s source path."
            )
        }
        guard let hostPath = selectedHostPath(
            resourcePath: resourcePath,
            selectedFilePath: selectedFilePath
        ) else {
            return .editingUnavailable(
                reason: "Editing is unavailable because this file does not have a valid Skill-relative path."
            )
        }
        return .editable(hostPath: hostPath)
    }

    private static func selectedHostPath(
        resourcePath: String,
        selectedFilePath: String
    ) -> String? {
        let components = selectedFilePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard resourcePath.hasPrefix("/"),
              !resourcePath.contains("\0"),
              !selectedFilePath.isEmpty,
              !selectedFilePath.contains("\0"),
              !selectedFilePath.contains("\\"),
              !selectedFilePath.hasPrefix("/"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }

        let canonicalResourcePath = (resourcePath as NSString).standardizingPath
        let resourceFileName = (canonicalResourcePath as NSString).lastPathComponent
        let skillDirectory: String
        if resourceFileName == "SKILL.md" {
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
        } else if canonicalResourcePath.hasSuffix(".md") {
            // A top-level Markdown resource represents that file only. Directory-
            // backed Skills can expose nested files through their SKILL.md root.
            guard selectedFilePath == resourceFileName else { return nil }
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
        } else {
            skillDirectory = canonicalResourcePath
        }
        return ((skillDirectory as NSString).appendingPathComponent(selectedFilePath) as NSString)
            .standardizingPath
    }
}

struct ServerSkillFileView: View {
    @Environment(\.apiClient) private var apiClient
    let target: ServerSkillFileNavTarget

    @State private var content: String?
    @State private var summary: ServerSkillSummary?
    @State private var isLoading = true
    @State private var error: String?

    private var fileName: String {
        target.path.split(separator: "/").last.map(String.init) ?? target.path
    }

    var body: some View {
        Group {
            if let content, let summary {
                switch ServerSkillFilePresentation.resolve(
                    editable: summary.editable,
                    resourcePath: summary.path,
                    selectedFilePath: target.path
                ) {
                case .editable(let hostPath):
                    ReviewableControlMarkdownView(
                        fileContent: content,
                        domain: .skills,
                        targetId: target.resourceId,
                        targetName: summary.name,
                        sourceLabel: "\(summary.name) / \(target.path)",
                        sourcePath: hostPath,
                        editFlow: .guidedRevision
                    )
                case .editingUnavailable(let reason):
                    ordinaryViewer(
                        content: content,
                        navigationActions: [
                            FullScreenViewerNavigationAction(
                                id: "edit-unavailable",
                                title: "Edit",
                                accessibilityLabel: "Edit unavailable",
                                accessibilityValue: reason,
                                isEnabled: false,
                                handler: {}
                            ),
                        ]
                    )
                    .safeAreaInset(edge: .bottom) {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.themeOrange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.themeBgHighlight)
                    }
                case .readOnly:
                    ordinaryViewer(content: content)
                }
            } else if isLoading {
                ProgressView("Loading file…")
            } else {
                ContentUnavailableView {
                    Label("File Unavailable", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(error ?? "The skill file could not be loaded.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(.themeBg)
        .navigationTitle(content == nil ? fileName : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(content == nil ? .automatic : .hidden, for: .navigationBar)
        .task(id: target) { await load() }
    }

    private func ordinaryViewer(
        content: String,
        navigationActions: [FullScreenViewerNavigationAction] = []
    ) -> some View {
        EmbeddedFileViewerView(
            content: .fromText(content, filePath: target.path),
            navigationActions: navigationActions
        )
        .ignoresSafeArea(edges: .top)
    }

    private func load() async {
        content = nil
        summary = nil
        isLoading = true
        error = nil

        guard let apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }
        do {
            async let fetchedContent = apiClient.getServerSkillFile(
                id: target.resourceId,
                path: target.path
            )
            async let fetchedDetail = apiClient.getServerSkill(id: target.resourceId)
            let (resolvedContent, resolvedDetail) = try await (fetchedContent, fetchedDetail)
            guard !Task.isCancelled else { return }
            content = resolvedContent
            summary = resolvedDetail.summary
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
