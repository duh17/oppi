import SwiftUI
import os.log

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "SkillFile")

/// Displays the content of a single file from a skill directory.
///
/// Navigated to from the file tree in ``SkillDetailView``.
/// Text files are rendered as syntax-highlighted code or markdown.
struct SkillFileView: View {
    let skillName: String
    let filePath: String

    @Environment(\.apiClient) private var apiClient
    @State private var content: String?
    @State private var isLoading = true
    @State private var error: String?

    private var fileName: String {
        filePath.components(separatedBy: "/").last ?? filePath
    }

    /// Whether the UIKit file viewer is active (text content loaded).
    private var isUsingFileViewer: Bool {
        content != nil
    }

    var body: some View {
        Group {
            if let content {
                EmbeddedFileViewerView(
                    content: .fromText(content, filePath: filePath)
                )
                .ignoresSafeArea(edges: .top)
            } else if isLoading {
                ProgressView("Loading…")
                    .padding(.top, 80)
            } else if let error {
                ContentUnavailableView(
                    "Failed to load",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .background(Color.themeBg)
        .navigationTitle(isUsingFileViewer ? "" : fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(isUsingFileViewer ? .hidden : .automatic, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard let api = apiClient else {
            error = "Not connected"
            isLoading = false
            return
        }

        do {
            content = try await api.getSkillFile(name: skillName, path: filePath)
            logger.debug("Loaded skill file: \(skillName)/\(filePath)")
        } catch {
            logger.error("Failed to load \(skillName)/\(filePath): \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
