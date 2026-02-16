import SwiftUI
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "RemoteFileView")

/// Fetches and displays a file from the session's working directory.
///
/// Triggered when the user taps a file path in a tool call header.
/// Reuses `FileContentView` for rendering — same syntax highlighting,
/// markdown, JSON, images as inline tool output.
struct RemoteFileView: View {
    let workspaceId: String
    let sessionId: String
    let path: String

    @Environment(ServerConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var imageData: Data?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    private var isImagePath: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp"].contains(ext)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading \(filename)…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundStyle(.tokyoRed)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.tokyoComment)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let imageData, let uiImage = UIImage(data: imageData) {
                    ScrollView {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                } else if let content {
                    FileContentView(content: content, filePath: path)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(Color.tokyoBg)
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if let content {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = content
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
        guard let api = connection.apiClient else {
            errorMessage = "Not connected to server"
            isLoading = false
            return
        }

        let resolvedWorkspaceId: String
        if !workspaceId.isEmpty {
            resolvedWorkspaceId = workspaceId
        } else if let cachedWorkspaceId = connection.sessionStore.workspaceId(for: sessionId),
                  !cachedWorkspaceId.isEmpty {
            resolvedWorkspaceId = cachedWorkspaceId
        } else {
            errorMessage = "Missing workspace context for this session"
            isLoading = false
            return
        }

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
