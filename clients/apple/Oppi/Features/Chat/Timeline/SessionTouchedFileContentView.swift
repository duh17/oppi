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
    @State private var phase: Phase = .loading

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
                FileContentView(
                    content: content,
                    filePath: filePath,
                    presentation: .document
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadContent() }
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
