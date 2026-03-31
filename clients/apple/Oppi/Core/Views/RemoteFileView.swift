import SwiftUI
import OSLog

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

    private var isImagePath: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp"].contains(ext)
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
            } else if let imageData, let uiImage = UIImage(data: imageData) {
                NavigationStack {
                    ScrollView {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
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
