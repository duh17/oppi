import SwiftUI

/// Displays content of a session-touched file that may live outside the workspace.
///
/// Loads file content via the session raw API and renders using
/// `FileContentView` — the same renderer used by the file browser.
/// HTML files default to rendered preview via `HTMLFileView` in document mode.
struct SessionTouchedFileContentView: View {
    let workspaceId: String
    let sessionId: String
    let filePath: String
    let fileName: String
    var navigationContext: FileBrowserNavigationContext?

    @Environment(\.apiClient) private var apiClient
    @Environment(\.dismiss) private var dismiss
    @Environment(WorkspaceStore.self) private var workspaceStore
    @State private var activeSelection: FileBrowserSelection?
    @State private var fileTransitionDirection: FileBrowserNavigationDirection = .next
    @State private var phase: Phase = .loading
    @State private var loadedServerBaseURL: URL?
    @State private var fetchSessionFileData: ((String) async throws -> Data)?

    /// Whether the UIKit file viewer is active (text content loaded).
    private var isUsingFileViewer: Bool {
        if case .text = phase { return true }
        return false
    }

    private var currentSelection: FileBrowserSelection {
        activeSelection ?? FileBrowserSelection(path: filePath, name: fileName, size: nil)
    }

    private var currentFilePath: String { currentSelection.path }
    private var currentFileName: String { currentSelection.name }

    private var parentOwnsBackSwipe: Bool {
        switch phase {
        case .text:
            return false
        case .loading, .error, .image, .binary:
            return true
        }
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
        let activePath = currentFilePath
        guard let serverBaseURL = loadedServerBaseURL,
              let fetchSessionFileData,
              let sourcePath = activePath.workspaceRelativePath(hostMount: currentWorkspaceHostMount) else {
            return .fromText(text, filePath: activePath)
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
        fileContent
            .filePushTransition(id: currentFilePath, direction: fileTransitionDirection)
            .background(Color.themeBgDark)
            .horizontalBackSwipeGesture(isEnabled: parentOwnsBackSwipe) { dismiss() }
            .overlay(alignment: .bottom) {
                fileNavigatorControls
                    .padding(.bottom, FullScreenFloatingControlChrome.bottomPadding)
            }
        .navigationTitle(isUsingFileViewer ? "" : currentFileName)
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
        .task(id: currentFilePath) { await loadContent() }
        .onChange(of: filePath) { _, _ in
            activeSelection = nil
            phase = .loading
        }
    }

    @ViewBuilder
    private var fileContent: some View {
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
                content: fullScreenContent(text: content),
                backSwipeAction: { dismiss() }
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

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        switch phase {
        case .text(let text):
            return .fromText(text, filePath: currentFilePath)
        case .image(let data):
            return .imageData(data, filename: currentFileName)
        default:
            return nil
        }
    }

    // MARK: - Image

    @ViewBuilder
    private func imageView(_ data: Data) -> some View {
        ScrollView {
            DataImagePreviewView(
                data: data,
                mimeType: MediaMimeType.imageMimeType(forPathExtension: (currentFilePath as NSString).pathExtension),
                maxPixelSize: 2_400,
                heightMode: .unrestricted
            )
            .padding()
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
        let requestedPath = currentFilePath
        phase = .loading
        do {
            let data = try await api.browseSessionTouchedFile(
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: requestedPath
            )
            guard isCurrentFile(requestedPath) else { return }

            let ext = (requestedPath as NSString).pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tif", "tiff"]

            if imageExts.contains(ext) {
                phase = .image(data)
            } else if let text = String(data: data, encoding: .utf8) {
                phase = .text(text)
            } else {
                phase = .binary
            }
        } catch {
            guard isCurrentFile(requestedPath) else { return }
            phase = .error(error.localizedDescription)
        }
    }

    // MARK: - File Navigation

    private func isCurrentFile(_ requestedPath: String) -> Bool {
        !Task.isCancelled && currentFilePath == requestedPath
    }

    private var fileNavigatorControls: some View {
        AdjacentFileNavigatorControls(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil,
            onPrevious: { navigateToAdjacentFile(.previous) },
            onNext: { navigateToAdjacentFile(.next) }
        )
    }

    private func adjacentSelection(_ direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        navigationContext?.selection(adjacentTo: currentFilePath, direction: direction)
    }

    private func navigateToAdjacentFile(_ direction: FileBrowserNavigationDirection) {
        guard let nextSelection = adjacentSelection(direction) else { return }
        fileTransitionDirection = direction
        withAnimation(.easeInOut(duration: 0.22)) {
            activeSelection = nextSelection
            phase = .loading
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
