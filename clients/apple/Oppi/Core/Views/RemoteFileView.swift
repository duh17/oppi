import SwiftUI
import OSLog
import UniformTypeIdentifiers

// periphery:ignore
private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "RemoteFileView")

/// Fetches and displays a file from the session's working directory.
///
/// Triggered when the user taps a file path in a tool call header.
/// Reuses `FileContentView` for rendering — same syntax highlighting,
/// markdown, JSON, images as inline tool output.
// periphery:ignore
struct RemoteFileView: View {
    let workspaceId: String
    let sessionId: String
    let path: String

    @Environment(\.apiClient) private var apiClient
    @Environment(SessionStore.self) private var sessionStore
    @Environment(WorkspaceStore.self) private var workspaceStore
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var imageData: Data?
    @State private var downloadedMediaURL: URL?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadedServerBaseURL: URL?
    @State private var fetchSessionFileData: ((String) async throws -> Data)?
    @State private var resolvedWorkspaceId: String?

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    private var piRouter: SelectedTextPiActionRouter {
        navigation.makeQuickSessionPiRouter()
    }

    private var pathExtension: String {
        (path as NSString).pathExtension.lowercased()
    }

    private var pathType: UTType? {
        guard !pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: pathExtension)
    }

    private var isImagePath: Bool {
        if let pathType {
            return pathType.conforms(to: .image)
        }
        return pathExtension == "svg"
    }

    private var isVideoPath: Bool {
        if let pathType {
            return pathType.conforms(to: .movie) || pathType.conforms(to: .video)
        }
        return MediaMimeType.videoMimeType(forPathExtension: pathExtension) != nil
    }

    private var isAudioPath: Bool {
        if let pathType {
            return pathType.conforms(to: .audio)
        }
        return MediaMimeType.audioMimeType(forPathExtension: pathExtension) != nil
    }

    private var currentWorkspaceHostMount: String? {
        let targetWorkspaceId = resolvedWorkspaceId ?? (workspaceId.isEmpty ? nil : workspaceId)
        guard let targetWorkspaceId else { return nil }

        if let activeServerId = workspaceStore.activeServerId,
           let workspace = workspaceStore.workspacesByServer[activeServerId]?
           .first(where: { $0.id == targetWorkspaceId }) {
            return workspace.hostMount
        }

        return workspaceStore.workspaces.first(where: { $0.id == targetWorkspaceId })?.hostMount
    }

    private func fullScreenContent(text: String) -> FullScreenCodeContent {
        guard let resolvedWorkspaceId,
              let serverBaseURL = loadedServerBaseURL,
              let fetchSessionFileData,
              let sourcePath = path.workspaceRelativePath(hostMount: currentWorkspaceHostMount) else {
            return .fromText(text, filePath: path)
        }

        return .fromText(
            text,
            filePath: sourcePath,
            workspaceContext: .init(
                workspaceID: resolvedWorkspaceId,
                serverBaseURL: serverBaseURL,
                fetchWorkspaceFile: { _, filePath in
                    try await fetchSessionFileData(filePath)
                }
            )
        )
    }

    var body: some View {
        Group {
            if let content {
                // Text content: use the canonical full-screen viewer (same as timeline).
                // The VC has its own nav controller with dismiss, copy, share, toggle.
                FullScreenCodeView(
                    content: fullScreenContent(text: content),
                    selectedTextPiRouter: piRouter
                )
            } else if let imageData, isImagePath {
                NavigationStack {
                    ScrollView {
                        DataImagePreviewView(
                            data: imageData,
                            mimeType: MediaMimeType.imageMimeType(forPathExtension: pathExtension),
                            maxPixelSize: 2_400,
                            maxHeight: nil
                        )
                        .padding()
                    }
                    .background(Color.themeBg)
                    .navigationTitle(filename)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            } else if let downloadedMediaURL, isVideoPath {
                NavigationStack {
                    FileURLVideoPlayerView(
                        fileURL: downloadedMediaURL,
                        height: 260,
                        autoplay: false,
                        loops: false,
                        cleanupOnDisappear: false
                    )
                    .padding()
                    .background(Color.themeBg)
                    .navigationTitle(filename)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            } else if let downloadedMediaURL, isAudioPath {
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 40))
                            .foregroundStyle(.themeComment)

                        Text(filename)
                            .font(.headline)
                            .foregroundStyle(.themeFg)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        FileURLAudioPlayerView(
                            fileURL: downloadedMediaURL,
                            height: 120,
                            autoplay: false,
                            cleanupOnDisappear: false
                        )
                    }
                    .padding()
                    .background(Color.themeBg)
                    .navigationTitle(filename)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            } else {
                NavigationStack {
                    Group {
                        if isLoading {
                            ProgressView("Loading \(filename)…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title)
                                    .foregroundStyle(.themeRed)
                                Text(errorMessage)
                                    .font(.subheadline)
                                    .foregroundStyle(.themeComment)
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .background(Color.themeBg)
                    .navigationTitle(filename)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
            }
        }
        .task {
            await loadFile()
        }
        .onDisappear {
            cleanupDownloadedMediaFile()
        }
    }

    private func cleanupDownloadedMediaFile() {
        guard let downloadedMediaURL else { return }
        try? FileManager.default.removeItem(at: downloadedMediaURL)
    }

    private func loadFile() async {
        guard let api = apiClient else {
            errorMessage = "Not connected to server"
            isLoading = false
            return
        }

        let resolvedWorkspaceId: String
        if !workspaceId.isEmpty {
            resolvedWorkspaceId = workspaceId
        } else if let cachedWorkspaceId = sessionStore.workspaceId(for: sessionId),
                  !cachedWorkspaceId.isEmpty {
            resolvedWorkspaceId = cachedWorkspaceId
        } else {
            errorMessage = "Missing workspace context for this session"
            isLoading = false
            return
        }

        loadedServerBaseURL = api.baseURL
        fetchSessionFileData = { [api, resolvedWorkspaceId, sessionId] filePath in
            try await api.getSessionFileData(
                workspaceId: resolvedWorkspaceId,
                sessionId: sessionId,
                path: filePath
            )
        }
        self.resolvedWorkspaceId = resolvedWorkspaceId

        do {
            if isImagePath {
                let data = try await api.getSessionFileData(
                    workspaceId: resolvedWorkspaceId,
                    sessionId: sessionId,
                    path: path
                )
                self.imageData = data
            } else if isVideoPath || isAudioPath {
                let fileURL = try await api.downloadSessionFileToTemporaryURL(
                    workspaceId: resolvedWorkspaceId,
                    sessionId: sessionId,
                    path: path
                )
                self.downloadedMediaURL = fileURL
            } else {
                let text = try await api.getSessionFile(
                    workspaceId: resolvedWorkspaceId,
                    sessionId: sessionId,
                    path: path
                )
                self.content = text
            }
        } catch {
            logger.error("Failed to load file \(path): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}
