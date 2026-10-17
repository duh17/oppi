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

/// How a Skill file opens. Every file is read from its host path, the same
/// direct read as any other host file.
enum ServerSkillFilePresentation: Equatable {
    /// Readable, with Edit in Oppi Session.
    case editable(hostPath: String)
    case readOnly(hostPath: String)
    /// No host path to read.
    case unavailable(reason: String)

    static func resolve(
        editable: Bool,
        resourcePath: String?,
        selectedFilePath: String
    ) -> Self {
        guard let resourcePath else {
            return .unavailable(reason: "The server did not provide this Skill’s source path.")
        }
        guard let location = hostLocation(
            resourcePath: resourcePath,
            selectedFilePath: selectedFilePath
        ) else {
            return .unavailable(reason: "This file does not have a valid Skill-relative path.")
        }
        return editable && location.isSkillSource
            ? .editable(hostPath: location.path)
            : .readOnly(hostPath: location.path)
    }

    /// `isSkillSource` is false for a file beside a top-level Markdown Skill:
    /// that Skill is the one file, so revising it never edits its neighbors.
    private static func hostLocation(
        resourcePath: String,
        selectedFilePath: String
    ) -> (path: String, isSkillSource: Bool)? {
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
        var isSkillSource = true
        if resourceFileName == "SKILL.md" {
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
        } else if canonicalResourcePath.hasSuffix(".md") {
            skillDirectory = (canonicalResourcePath as NSString).deletingLastPathComponent
            isSkillSource = selectedFilePath == resourceFileName
        } else {
            skillDirectory = canonicalResourcePath
        }
        let path = ((skillDirectory as NSString).appendingPathComponent(selectedFilePath) as NSString)
            .standardizingPath
        return (path, isSkillSource)
    }
}

/// One Skill file in the shared file reader. The Skill's page or the
/// catalog already holds its summary, so opening a file is one host read;
/// the server rebuilds its Skill catalog only when neither has it.
struct ServerSkillFileView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerResourceStore.self) private var store
    let target: ServerSkillFileNavTarget

    @State private var fetchedSummary: ServerSkillSummary?
    @State private var error: String?

    private var summary: ServerSkillSummary? {
        fetchedSummary
            ?? store.skillDetail(id: target.resourceId, serverId: target.serverId)?.summary
            ?? store.skills(forServer: target.serverId).first { $0.id == target.resourceId }
    }

    private var fileName: String {
        target.path.split(separator: "/").last.map(String.init) ?? target.path
    }

    var body: some View {
        Group {
            if let summary {
                switch ServerSkillFilePresentation.resolve(
                    editable: summary.editable,
                    resourcePath: summary.path,
                    selectedFilePath: target.path
                ) {
                case .editable(let hostPath):
                    ReviewableControlMarkdownView(
                        hostFilePath: hostPath,
                        serverId: target.serverId,
                        title: target.path,
                        domain: .skills,
                        targetId: target.resourceId,
                        targetName: summary.name,
                        sourceLabel: "\(summary.name) / \(target.path)",
                        editFlow: .guidedRevision
                    )
                case .readOnly(let hostPath):
                    FileBrowserContentView(
                        workspaceId: "",
                        serverId: target.serverId,
                        filePath: hostPath,
                        fileName: fileName,
                        title: target.path,
                        source: .hostFile
                    )
                case .unavailable(let reason):
                    unavailable(reason)
                }
            } else if let error {
                unavailable(error)
            } else {
                ProgressView("Loading file…")
                    .navigationTitle(fileName)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .background(.themeBg)
        .task(id: target) {
            guard summary == nil else { return }
            await loadSummary()
        }
    }

    private func unavailable(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("File Unavailable", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(reason)
        } actions: {
            Button("Retry") { Task { await loadSummary() } }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadSummary() async {
        error = nil
        guard let apiClient else {
            error = "Not connected"
            return
        }
        do {
            let detail = try await apiClient.getServerSkill(id: target.resourceId)
            guard !Task.isCancelled else { return }
            store.rememberSkillDetail(detail, serverId: target.serverId)
            fetchedSummary = detail.summary
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
