import SwiftUI

/// Expandable bar showing workspace git status.
///
/// Pinned at the top of the chat view. Collapsed shows branch + dirty count + repo-wide +/-.
/// Expanded shows the full file list with per-file line stats.
struct WorkspaceContextBar: View {
    let gitStatus: GitStatus?
    let isLoading: Bool
    let appliesOuterHorizontalPadding: Bool

    @State private var isExpanded = false

    init(
        gitStatus: GitStatus?,
        isLoading: Bool,
        appliesOuterHorizontalPadding: Bool = true
    ) {
        self.gitStatus = gitStatus
        self.isLoading = isLoading
        self.appliesOuterHorizontalPadding = appliesOuterHorizontalPadding
    }

    // MARK: - Computed

    private var hasContent: Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        return !gitStatus.isClean
    }

    private var dirtyColor: Color {
        guard let count = gitStatus?.uncommittedCount else { return .themeComment }
        if count == 0 { return .themeDiffAdded }
        if count <= 5 { return .themeFg }
        if count <= 15 { return .themeOrange }
        return .themeDiffRemoved
    }

    // MARK: - Body

    var body: some View {
        if isLoading && gitStatus == nil {
            // First load — show nothing (avoid layout jump)
            EmptyView()
        } else if hasContent {
            VStack(spacing: 0) {
                collapsedBar
                if isExpanded {
                    ScrollView {
                        expandedPanel
                    }
                    .frame(maxHeight: 300)
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, appliesOuterHorizontalPadding ? 16 : 0)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
    }

    // MARK: - Collapsed

    private var collapsedBar: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                // Branch
                if let branch = gitStatus?.branch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.branch")
                            .font(.caption2.weight(.semibold))
                        Text(branch)
                            .font(.caption.monospaced().weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.themeCyan)
                }

                // Dirty count
                if let gitStatus, gitStatus.uncommittedCount > 0 {
                    Text("\(gitStatus.uncommittedCount) changed")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(dirtyColor)
                }

                // Repo-wide +/- from git diff HEAD
                if let gitStatus, gitStatus.addedLines > 0 || gitStatus.removedLines > 0 {
                    HStack(spacing: 4) {
                        if gitStatus.addedLines > 0 {
                            Text("+\(gitStatus.addedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffAdded)
                        }
                        if gitStatus.removedLines > 0 {
                            Text("-\(gitStatus.removedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeDiffRemoved)
                        }
                    }
                }

                Spacer(minLength: 0)

                // Ahead/behind
                if let ahead = gitStatus?.ahead, let behind = gitStatus?.behind {
                    if ahead > 0 || behind > 0 {
                        HStack(spacing: 4) {
                            if ahead > 0 {
                                Text("\u{2191}\(ahead)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.themeDiffAdded)
                            }
                            if behind > 0 {
                                Text("\u{2193}\(behind)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.themeOrange)
                            }
                        }
                    }
                }

                // Expand chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.themeComment)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.themeComment.opacity(0.2))

            // File list with per-file +/-
            if let gitStatus, !gitStatus.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(gitStatus.files) { file in
                        HStack(spacing: 6) {
                            Text(file.status)
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(statusColor(for: file.status))
                                .frame(width: 22, alignment: .leading)

                            Text(file.path.shortenedPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 4)

                            // Per-file +/- from git diff HEAD --numstat
                            if let added = file.addedLines, added > 0 {
                                Text("+\(added)")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffAdded)
                            }
                            if let removed = file.removedLines, removed > 0 {
                                Text("-\(removed)")
                                    .font(.caption2.monospaced().bold())
                                    .foregroundStyle(.themeDiffRemoved)
                            }
                        }
                    }

                    if gitStatus.totalFiles > gitStatus.files.count {
                        Text("... and \(gitStatus.totalFiles - gitStatus.files.count) more")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // Commit info + stash
            if let gitStatus, gitStatus.isGitRepo {
                Divider().overlay(Color.themeComment.opacity(0.15))

                HStack(spacing: 8) {
                    if let sha = gitStatus.headSha {
                        Text(sha)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeComment)
                    }
                    if let msg = gitStatus.lastCommitMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.themeFgDim)
                            .lineLimit(1)
                    }
                    if gitStatus.stashCount > 0 {
                        Spacer(minLength: 0)
                        Text("\(gitStatus.stashCount) stash")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themePurple)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Helpers

    private func statusColor(for status: String) -> Color {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "M": return .themeOrange
        case "A": return .themeDiffAdded
        case "D": return .themeDiffRemoved
        case "R", "C": return .themeCyan
        case "??": return .themeComment
        case "UU", "AA", "DD": return .themeDiffRemoved
        default: return .themeFg
        }
    }
}
