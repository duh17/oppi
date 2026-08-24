import SwiftUI

/// Builds the same full-screen file viewer used by session-touched file preview.
enum SessionFileFullScreenContentBuilder {
    static func content(
        text: String,
        filePath: String,
        workspaceID: String?,
        serverBaseURL: URL?,
        workspaceHostMount: String?,
        workspaceRuntime: WorkspaceRuntime?,
        fetchSessionFileData: ((String) async throws -> Data)?,
        makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider? = nil,
        sessionID: String
    ) -> FullScreenCodeContent {
        guard let workspaceID,
              let serverBaseURL,
              let fetchSessionFileData else {
            return .fromText(text, filePath: filePath)
        }

        return .fromText(
            text,
            filePath: filePath,
            workspaceContext: .init(
                workspaceID: workspaceID,
                serverBaseURL: serverBaseURL,
                fetchWorkspaceFile: { _, path in
                    try await fetchSessionFileData(path)
                },
                sessionID: sessionID,
                fetchSessionFile: nil,
                makeMarkdownVideoSource: makeMarkdownVideoSource
            )
        )
    }
}

/// Displays content of a file reported by the session.
///
/// Loads workspace files and reported external paths via the session raw API, then renders using
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
    @State private var makeMarkdownVideoSource: MarkdownVideoMediaSourceProvider?

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

    private var currentWorkspace: Workspace? {
        if let activeServerId = workspaceStore.activeServerId,
           let workspace = workspaceStore.workspacesByServer[activeServerId]?
           .first(where: { $0.id == workspaceId }) {
            return workspace
        }
        return workspaceStore.workspaces.first(where: { $0.id == workspaceId })
    }

    private var currentWorkspaceHostMount: String? {
        currentWorkspace?.hostMount
    }

    private var currentWorkspaceRuntime: WorkspaceRuntime? {
        currentWorkspace?.runtime
    }

    private func fullScreenContent(text: String) -> FullScreenCodeContent {
        SessionFileFullScreenContentBuilder.content(
            text: text,
            filePath: currentFilePath,
            workspaceID: workspaceId,
            serverBaseURL: loadedServerBaseURL,
            workspaceHostMount: currentWorkspaceHostMount,
            workspaceRuntime: currentWorkspaceRuntime,
            fetchSessionFileData: fetchSessionFileData,
            makeMarkdownVideoSource: makeMarkdownVideoSource,
            sessionID: sessionId
        )
    }

    var body: some View {
        fileContent
            .filePushTransition(id: currentFilePath, direction: fileTransitionDirection)
            .background(.themeBgDark)
            .horizontalBackSwipeGesture(isEnabled: parentOwnsBackSwipe) { dismiss() }
            .overlay(alignment: .bottom) {
                fileNavigatorControls
                    .padding(.bottom, FullScreenFloatingControlChrome.bottomPadding)
            }
        .navigationTitle(
            isUsingFileViewer
                ? ""
                : SessionTouchedFileLoadRoute.navigationTitle(
                    path: currentFilePath,
                    fileName: currentFileName,
                    workspaceRuntime: currentWorkspaceRuntime
                )
        )
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
        let workspaceHostMount = currentWorkspaceHostMount
        let workspaceRuntime = currentWorkspaceRuntime
        fetchSessionFileData = { [api, workspaceId, sessionId, workspaceRuntime, workspaceHostMount] path in
            switch SessionTouchedFileLoadRoute.resolve(
                path: path,
                workspaceRuntime: workspaceRuntime,
                hostMount: workspaceHostMount
            ) {
            case let .hostFile(hostPath):
                return try await api.browseHostFile(path: hostPath)
            case let .sessionRaw(rawPath):
                return try await api.getSessionFileData(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    path: rawPath
                )
            }
        }
        makeMarkdownVideoSource = { [api, workspaceId, sessionId, workspaceRuntime, workspaceHostMount] embed in
            let route = SessionTouchedFileLoadRoute.resolve(
                path: embed.filePath,
                workspaceRuntime: workspaceRuntime,
                hostMount: workspaceHostMount
            )
            let pathExtension = (route.requestPath as NSString).pathExtension
            switch route {
            case .hostFile(let hostPath):
                return try await api.makeHostFileMediaSource(
                    path: hostPath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: pathExtension),
                    sourceFileExtension: pathExtension
                )
            case .sessionRaw(let rawPath):
                return try await api.makeSessionFileMediaSource(
                    workspaceId: workspaceId,
                    sessionId: sessionId,
                    path: rawPath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: pathExtension),
                    sourceFileExtension: pathExtension
                )
            }
        }
        let requestedPath = currentFilePath
        let route = SessionTouchedFileLoadRoute.resolve(
            path: requestedPath,
            workspaceRuntime: workspaceRuntime,
            hostMount: workspaceHostMount
        )
        phase = .loading
        do {
            let data = try await {
                switch route {
                case let .hostFile(hostPath):
                    return try await api.browseHostFile(path: hostPath)
                case let .sessionRaw(rawPath):
                    return try await api.browseSessionTouchedFile(
                        workspaceId: workspaceId,
                        sessionId: sessionId,
                        path: rawPath
                    )
                }
            }()
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
