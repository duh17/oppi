import SwiftUI

/// Expandable bar showing git status and session changes.
///
/// Pinned at the top of the chat view. Collapsed shows branch + dirty count.
/// Expanded shows the full file list from git and session change details.
struct WorkspaceContextBar: View {
    let gitStatus: GitStatus?
    let changeStats: SessionChangeStats?
    let isLoading: Bool

    @State private var isExpanded = false

    // MARK: - Computed

    private var hasContent: Bool {
        guard let gitStatus, gitStatus.isGitRepo else { return false }
        return !gitStatus.isClean || hasSessionChanges
    }

    private var hasSessionChanges: Bool {
        guard let changeStats else { return false }
        return changeStats.filesChanged > 0
    }

    private var dirtyColor: Color {
        guard let count = gitStatus?.uncommittedCount else { return .themeComment }
        if count == 0 { return .themeGreen }
        if count <= 5 { return .themeFg }
        if count <= 15 { return .themeOrange }
        return .themeRed
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
                    .frame(maxHeight: 240)
                }
            }
            .background(Color.themeBgHighlight.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.themeComment.opacity(0.15), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
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
                    Text("\(gitStatus.uncommittedCount) dirty")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(dirtyColor)
                }

                // Session change stats
                if let stats = changeStats, stats.filesChanged > 0 {
                    HStack(spacing: 4) {
                        if stats.addedLines > 0 {
                            Text("+\(stats.addedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeGreen)
                        }
                        if stats.removedLines > 0 {
                            Text("-\(stats.removedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeRed)
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
                                    .foregroundStyle(.themeGreen)
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

            // Git dirty files
            if let gitStatus, !gitStatus.files.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Git Status")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .padding(.bottom, 2)

                    ForEach(gitStatus.files.prefix(20)) { file in
                        HStack(spacing: 8) {
                            Text(file.status)
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(statusColor(for: file.status))
                                .frame(width: 22, alignment: .leading)

                            Text(file.path.shortenedPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeFg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    if gitStatus.files.count > 20 {
                        Text("... and \(gitStatus.totalFiles - 20) more")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            // Commit info
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

            // Session changes summary
            if let stats = changeStats, stats.filesChanged > 0 {
                Divider().overlay(Color.themeComment.opacity(0.15))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Session Changes")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.themeComment)

                        Text("\(stats.filesChanged) files")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeFg)

                        if stats.addedLines > 0 {
                            Text("+\(stats.addedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeGreen)
                        }
                        if stats.removedLines > 0 {
                            Text("-\(stats.removedLines)")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(.themeRed)
                        }
                    }

                    ForEach(stats.changedFiles.prefix(10), id: \.self) { file in
                        Text(file.shortenedPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.themeFgDim)
                            .lineLimit(1)
                    }

                    if stats.changedFiles.count > 10 {
                        Text("... and \(stats.changedFiles.count - 10) more")
                            .font(.caption2)
                            .foregroundStyle(.themeComment)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Helpers

    private func statusColor(for status: String) -> Color {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "M": return .themeOrange
        case "A": return .themeGreen
        case "D": return .themeRed
        case "R", "C": return .themeCyan
        case "??": return .themeComment
        case "UU", "AA", "DD": return .themeRed
        default: return .themeFg
        }
    }
}
