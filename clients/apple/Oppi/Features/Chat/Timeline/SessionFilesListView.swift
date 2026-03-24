import SwiftUI

/// Displays the list of files touched (written/edited) by a session.
///
/// Each row shows the file icon, filename, parent path, and a language/type badge.
/// Tapping a row navigates to the appropriate detail view:
/// - In-workspace files with git changes → diff + current view
/// - All other files → content view with HTML preview support
struct SessionFilesListView: View {
    let sessionId: String
    let workspaceId: String?
    let changedFiles: [String]

    @Environment(GitStatusStore.self) private var gitStatusStore

    /// Files from git status, keyed by path for fast lookup.
    private var gitFilesByPath: [String: GitFileStatus] {
        guard let files = gitStatusStore.gitStatus?.files else { return [:] }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    }

    var body: some View {
        if changedFiles.isEmpty {
            ContentUnavailableView(
                "No Files",
                systemImage: "doc.text",
                description: Text("This session hasn't created or edited any files yet.")
            )
            .background(Color.themeBgDark)
        } else {
            List {
                ForEach(changedFiles, id: \.self) { path in
                    fileRow(path: path)
                }
            }
            .listStyle(.plain)
            .background(Color.themeBgDark)
        }
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(path: String) -> some View {
        let icon = FileIcon.forPath(path)
        let fileName = path.lastPathComponentForDisplay
        let parentPath = path.parentPathForDisplay
        let fileType = FileType.detect(from: path)
        let gitFile = gitFilesByPath[path]

        NavigationLink {
            destination(for: path, gitFile: gitFile)
        } label: {
            HStack(spacing: 10) {
                // File icon
                Image(systemName: icon.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(icon.color)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(icon.color.opacity(0.1))
                    )

                // File name + parent path
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(fileName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeFg)
                            .lineLimit(1)

                        // Language / type badge
                        Text(fileType.displayLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badgeColor(for: fileType))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                badgeColor(for: fileType).opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }

                    if let parentPath {
                        Text(parentPath.shortenedPath)
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                // Git status indicator (if tracked and changed)
                if let gitFile {
                    HStack(spacing: 4) {
                        if let added = gitFile.addedLines, added > 0 {
                            Text("+\(added)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if let removed = gitFile.removedLines, removed > 0 {
                            Text("-\(removed)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Navigation Destination

    @ViewBuilder
    private func destination(for path: String, gitFile: GitFileStatus?) -> some View {
        if let workspaceId, let gitFile {
            // In-workspace file with git changes — show diff + current
            WorkspaceReviewFileDetailView(
                workspaceId: workspaceId,
                selectedSessionId: sessionId,
                file: gitFile.toReviewFile()
            )
        } else if let workspaceId, !isAbsolutePath(path) {
            // In-workspace file without git changes — show current content via file browser
            FileBrowserContentView(
                workspaceId: workspaceId,
                filePath: path,
                fileName: path.lastPathComponentForDisplay
            )
        } else if let workspaceId {
            // External file (absolute path) — load via session-touched-file API
            SessionTouchedFileContentView(
                workspaceId: workspaceId,
                sessionId: sessionId,
                filePath: path,
                fileName: path.lastPathComponentForDisplay
            )
        } else {
            ContentUnavailableView(
                "Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("No workspace context to load file.")
            )
        }
    }

    // MARK: - Helpers

    private func isAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~")
    }

    private func badgeColor(for fileType: FileType) -> Color {
        switch fileType {
        case .html: return .themeOrange
        case .markdown: return .themeBlue
        case .json: return .themeYellow
        case .code(let lang):
            switch lang {
            case .swift: return .themeOrange
            case .typescript: return .themeBlue
            case .javascript: return .themeYellow
            case .python: return .themeCyan
            case .go: return .themeCyan
            case .rust: return .themeOrange
            case .ruby: return .themeRed
            case .shell: return .themeGreen
            default: return .themeFgDim
            }
        case .image: return .themePurple
        default: return .themeComment
        }
    }
}
