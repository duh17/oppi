import SwiftUI

/// Displays the content of a workspace file in browse mode.
///
/// For text files: renders source with monospace font and line numbers.
/// For images: renders inline.
/// For unsupported/large files: shows metadata only.
struct FileBrowserContentView: View {
    let workspaceId: String
    let filePath: String
    let fileName: String

    @Environment(\.apiClient) private var apiClient
    @State private var content: FileContentPhase = .loading

    private var fileExtension: String {
        fileName.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(fileExtension)
    }

    private var isHTML: Bool {
        ["html", "htm"].contains(fileExtension)
    }

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                ContentUnavailableView(
                    "Unable to Load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .text(let text):
                sourceCodeView(text)
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
        .toolbar {
            if isHTML {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        HTMLPreviewView(
                            workspaceId: workspaceId,
                            filePath: filePath,
                            fileName: fileName
                        )
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                }
            }
        }
        .task { await loadContent() }
    }

    // MARK: - Source Code View

    @ViewBuilder
    private func sourceCodeView(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let gutterWidth = max(String(lines.count).count, 3)

        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { lineNum, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text(String(lineNum + 1))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: CGFloat(gutterWidth) * 9, alignment: .trailing)
                            .padding(.trailing, 8)

                        Text(line.isEmpty ? " " : line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Image View

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
            content = .error("Not connected")
            return
        }
        do {
            let data = try await api.browseWorkspaceFile(workspaceId: workspaceId, path: filePath)

            if isImage {
                content = .image(data)
                return
            }

            if let text = String(data: data, encoding: .utf8) {
                content = .text(text)
            } else {
                content = .binary
            }
        } catch {
            content = .error(error.localizedDescription)
        }
    }
}

// MARK: - Phase

private enum FileContentPhase: Equatable {
    case loading
    case error(String)
    case text(String)
    case image(Data)
    case binary

    static func == (lhs: FileContentPhase, rhs: FileContentPhase) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): true
        case (.error(let a), .error(let b)): a == b
        case (.text(let a), .text(let b)): a == b
        case (.image(let a), .image(let b)): a == b
        case (.binary, .binary): true
        default: false
        }
    }
}
