import SwiftUI

/// Displays content of a session-touched file that may live outside the workspace.
///
/// Loads file content via the session touched-file API and renders using
/// `FileContentView` — the same renderer used by the file browser.
/// HTML files default to rendered preview via `HTMLFileView` in document mode.
struct SessionTouchedFileContentView: View {
    let workspaceId: String
    let sessionId: String
    let filePath: String
    let fileName: String

    @Environment(\.apiClient) private var apiClient
    @Environment(WorkspaceStore.self) private var workspaceStore
    @State private var phase: Phase = .loading
    @State private var loadedServerBaseURL: URL?
    @State private var fetchSessionFileData: ((String) async throws -> Data)?

    /// Whether the UIKit file viewer is active (text content loaded).
    private var isUsingFileViewer: Bool {
        if case .text = phase { return true }
        return false
    }

    private var currentWorkspaceHostMount: String? {
        if let activeServerId = workspaceStore.activeServerId,
           let workspace = workspaceStore.workspacesByServer[activeServerId]?
           .first(where: { $0.id == workspaceId }) {
            return workspace.hostMount
        }

        return workspaceStore.workspaces.first(where: { $0.id == workspaceId })?.hostMount
    }

    private func fullScreenContent(text: String) -> FullScreenCodeContent {
        guard let serverBaseURL = loadedServerBaseURL,
              let fetchSessionFileData,
              let sourcePath = filePath.workspaceRelativePath(hostMount: currentWorkspaceHostMount) else {
            return .fromText(text, filePath: filePath)
        }

        return .fromText(
            text,
            filePath: sourcePath,
            workspaceContext: .init(
                workspaceID: workspaceId,
                serverBaseURL: serverBaseURL,
                fetchWorkspaceFile: { _, path in
                    try await fetchSessionFileData(path)
                }
            )
        )
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .text(let content):
                EmbeddedFileViewerView(
                    content: fullScreenContent(text: content)
                )
                .ignoresSafeArea(edges: .top)
            case .image(let data):
                imageView(data)
            case .binary:
                ContentUnavailableView(
                    "Binary File",
                    systemImage: "doc.fill",
                    description: Text("This file type cannot be displayed as text.")
                )
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle(isUsingFileViewer ? "" : fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isUsingFileViewer ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !isUsingFileViewer {
                ToolbarItem(placement: .topBarTrailing) {
                    if let shareable = shareableContent() {
                        FileShareButton(content: shareable, style: .icon)
                    }
                }
            }
        }
        .task { await loadContent() }
    }

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        switch phase {
        case .text(let text):
            return .fromText(text, filePath: filePath)
        case .image(let data):
            return .imageData(data, filename: fileName)
        default:
            return nil
        }
    }

    // MARK: - Image

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        if let uiImage = UIImage(data: data) {
            ScrollView {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
        } else {
            ContentUnavailableView(
                "Invalid Image",
                systemImage: "photo.badge.exclamationmark",
                description: Text("Could not decode image data.")
            )
        }
    }

    // MARK: - Loading

    private func loadContent() async {
        guard let api = apiClient else {
            phase = .error("Not connected")
            return
        }
        loadedServerBaseURL = api.baseURL
        fetchSessionFileData = { [api, workspaceId, sessionId] path in
            try await api.getSessionFileData(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: path
            )
        }
        do {
            let data = try await api.browseSessionTouchedFile(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: filePath
            )

            let ext = (filePath as NSString).pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff"]

            if imageExts.contains(ext) {
                phase = .image(data)
            } else if let text = String(data: data, encoding: .utf8) {
                phase = .text(text)
            } else {
                phase = .binary
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - Phase

    private enum Phase {
        case loading
        case error(String)
        case text(String)
        case image(Data)
        case binary
    }
}
