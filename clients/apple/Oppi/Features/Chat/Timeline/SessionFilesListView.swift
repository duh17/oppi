import SwiftUI

/// Displays the list of files touched (written/edited) by a session.
///
/// Each row shows the file icon, filename, parent path, and a language/type badge.
/// When `searchText` is non-empty, filters using `FuzzyMatch` and highlights
/// matched characters in filename and parent path.
///
/// Tapping a row navigates to the appropriate detail view:
/// - In-workspace files with git changes → diff + current view
/// - All other files → content view with HTML preview support
struct SessionFilesListView: View {
    let sessionId: String
    let workspaceId: String?
    let changedFiles: [String]
    var searchText: String = ""

    @Environment(GitStatusStore.self) private var gitStatusStore

    /// Files from git status, keyed by path for fast lookup.
    private var gitFilesByPath: [String: GitFileStatus] {
        guard let files = gitStatusStore.gitStatus?.files else { return [:] }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
    }

    /// Filtered + sorted files. When searching, uses FuzzyMatch for scoring.
    private var displayFiles: [(path: String, positions: [Int])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return changedFiles.map { ($0, []) }
        }
        return FuzzyMatch.search(query: query, candidates: changedFiles, limit: 100)
            .map { ($0.path, $0.positions) }
    }

    var body: some View {
        let files = displayFiles
        if changedFiles.isEmpty {
            ContentUnavailableView(
                "No Files",
                systemImage: "doc.text",
                description: Text("This session hasn't created or edited any files yet.")
            )
            .background(Color.themeBgDark)
        } else if files.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .background(Color.themeBgDark)
        } else {
            List {
                ForEach(files, id: \.path) { file in
                    fileRow(path: file.path, matchPositions: file.positions)
                }
            }
            .listStyle(.plain)
            .background(Color.themeBgDark)
        }
    }

    // MARK: - File Row

    @ViewBuilder
    private func fileRow(path: String, matchPositions: [Int] = []) -> some View {
        let icon = FileIcon.forPath(path)
        let fileName = path.lastPathComponentForDisplay
        let parentPath = path.parentPathForDisplay
        let fileType = FileType.detect(from: path)
        let gitFile = gitFilesByPath[path]
        let (filePositions, parentPositions) = Self.splitPositions(matchPositions, in: path)

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
                        if filePositions.isEmpty {
                            Text(fileName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                        } else {
                            Text(Self.highlighted(
                                fileName,
                                positions: filePositions,
                                baseColor: .themeFg,
                                baseFont: .subheadline.weight(.medium)
                            ))
                            .lineLimit(1)
                        }

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
                        let display = parentPath.shortenedPath
                        if parentPositions.isEmpty {
                            Text(display)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(Self.highlighted(
                                display,
                                positions: parentPositions,
                                baseColor: .themeComment,
                                baseFont: .caption2
                            ))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        }
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

    // MARK: - Fuzzy Match Helpers

    /// Split full-path match positions into filename and parent portions.
    /// Positions are unicode scalar indices into the original path.
    private static func splitPositions(
        _ positions: [Int], in path: String
    ) -> (filename: [Int], parent: [Int]) {
        guard !positions.isEmpty else { return ([], []) }
        let scalars = Array(path.unicodeScalars)
        // Find the last '/' to determine the boundary
        var lastSlash = -1
        for (i, s) in scalars.enumerated() where s == "/" {
            lastSlash = i
        }
        guard lastSlash >= 0 else {
            // No directory separator — all positions belong to filename
            return (positions, [])
        }
        let filenameStart = lastSlash + 1
        var filenamePositions: [Int] = []
        var parentPositions: [Int] = []
        for pos in positions {
            if pos >= filenameStart {
                filenamePositions.append(pos - filenameStart)
            } else if pos < lastSlash {
                parentPositions.append(pos)
            }
            // pos == lastSlash (the '/' itself) is dropped — not shown in either part
        }
        return (filenamePositions, parentPositions)
    }

    /// Build an AttributedString with matched positions highlighted in yellow.
    private static func highlighted(
        _ text: String,
        positions: [Int],
        baseColor: Color,
        baseFont: Font
    ) -> AttributedString {
        let scalars = Array(text.unicodeScalars)
        let matchSet = Set(positions)
        var result = AttributedString()

        var i = 0
        while i < scalars.count {
            if matchSet.contains(i) {
                var end = i
                while end + 1 < scalars.count, matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = .themeYellow
                seg.font = baseFont.bold()
                result.append(seg)
                i = end + 1
            } else {
                var end = i
                while end + 1 < scalars.count, !matchSet.contains(end + 1) { end += 1 }
                var seg = AttributedString(String(String.UnicodeScalarView(scalars[i...end])))
                seg.foregroundColor = baseColor
                seg.font = baseFont
                result.append(seg)
                i = end + 1
            }
        }
        return result
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
        case .latex: return .themeGreen
        case .orgMode: return .themeCyan
        case .mermaid: return .themePurple
        case .graphviz: return .themeOrange
        default: return .themeComment
        }
    }
}
