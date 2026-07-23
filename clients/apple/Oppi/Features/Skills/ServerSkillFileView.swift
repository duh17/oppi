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
                if summary.editable {
                    ReviewableControlMarkdownView(
                        fileContent: content,
                        domain: .skills,
                        targetId: target.resourceId,
                        targetName: summary.name,
                        sourceLabel: "\(summary.name) / \(target.path)",
                        sourcePath: target.path
                    )
                } else {
                    EmbeddedFileViewerView(content: .fromText(content, filePath: target.path))
                        .ignoresSafeArea(edges: .top)
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
        .background(Color.themeBg)
        .navigationTitle(content == nil ? fileName : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(content == nil ? .automatic : .hidden, for: .navigationBar)
        .task(id: target) { await load() }
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
