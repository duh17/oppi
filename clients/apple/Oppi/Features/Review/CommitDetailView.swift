import SwiftUI

/// Sheet view showing commit metadata and a tappable file list.
/// Tapping a file opens a diff view for that file in that commit.
struct CommitDetailView: View {
    let workspaceId: String
    let commit: GitCommitSummary

    @Environment(\.apiClient) private var apiClient
    @Environment(AppNavigation.self) private var navigation
    @State private var detail: GitCommitDetail?
    @State private var error: String?
    @State private var selectedFile: GitCommitFileInfo?

    var body: some View {
        Group {
            if let detail {
                loadedContent(detail)
            } else if let error {
                ContentUnavailableView(
                    "Unable to load commit",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView("Loading commit…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle("Commit")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: commit.sha) {
            await loadDetail()
        }
        .sheet(item: $selectedFile) { file in
            NavigationStack {
                CommitFileDiffView(workspaceId: workspaceId, sha: commit.sha, file: file)
                    .environment(\.selectedTextPiActionRouter, navigation.makeQuickSessionPiRouter())
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedFile = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Loaded Content

    private func loadedContent(_ detail: GitCommitDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                commitHeader(detail)

                Divider().overlay(Color.themeComment.opacity(0.2))

                filesSectionHeader(detail)

                Divider().overlay(Color.themeComment.opacity(0.15))

                fileList(detail)
            }
        }
    }

    // MARK: - Commit Header

    private func commitHeader(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // SHA
            Text(detail.sha)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)

            // Commit message
            Text(detail.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)

            // Author + date
            HStack(spacing: 8) {
                Text(detail.author)
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(relativeDate(from: detail.date))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeComment)
            }

            // Line stats
            HStack(spacing: 8) {
                if detail.addedLines > 0 {
                    Text("+\(detail.addedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffAdded)
                }
                if detail.removedLines > 0 {
                    Text("-\(detail.removedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.themeDiffRemoved)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Files Section Header

    private func filesSectionHeader(_ detail: GitCommitDetail) -> some View {
        HStack(spacing: 6) {
            Text("\(detail.files.count) file\(detail.files.count == 1 ? "" : "s") changed")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.themeComment)
                .tracking(0.4)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - File List

    private func fileList(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(detail.files) { file in
                commitFileRow(file)
            }
        }
        .padding(.vertical, 4)
    }

    private func commitFileRow(_ file: GitCommitFileInfo) -> some View {
        let icon = FileIcon.forPath(file.path)

        return Button {
            selectedFile = file
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon.symbolName)
                    .font(.appChip)
                    .foregroundStyle(icon.color)
                    .frame(width: 16, height: 16)

                Text(file.path.shortenedPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

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

                statusBadge(file.status)

                Image(systemName: "chevron.right")
                    .font(.appBadgeLight)
                    .foregroundStyle(.themeComment.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(_ status: String) -> some View {
        let (label, color) = statusInfo(status)
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }

    private func statusInfo(_ status: String) -> (String, Color) {
        switch status {
        case "M": return ("M", .themeOrange)
        case "A": return ("A", .themeDiffAdded)
        case "D": return ("D", .themeDiffRemoved)
        case "R": return ("R", .themeCyan)
        case "C": return ("C", .themeCyan)
        default: return (status, .themeComment)
        }
    }

    // MARK: - Data Loading

    private func loadDetail() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        do {
            detail = try await api.getCommitDetail(workspaceId: workspaceId, sha: commit.sha)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Date Formatting

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: isoString) else {
                return isoString
            }
            return SessionFormatting.durationString(since: date) + " ago"
        }
        return SessionFormatting.durationString(since: date) + " ago"
    }
}

/// Diff view for a single file within a specific commit.
/// Loads the diff via `getCommitFileDiff` and displays using `WorkspaceReviewDiffView`.
struct CommitFileDiffView: View {
    let workspaceId: String
    let sha: String
    let file: GitCommitFileInfo

    @Environment(\.apiClient) private var apiClient
    @State private var diff: WorkspaceReviewDiffResponse?
    @State private var error: String?

    private var fileIcon: FileIcon {
        FileIcon.forPath(file.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            Divider().overlay(Color.themeComment.opacity(0.2))

            Group {
                if let diff {
                    WorkspaceReviewDiffView(diff: diff, filePath: file.path)
                } else if let error {
                    ContentUnavailableView(
                        "Diff Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    ProgressView("Loading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.themeBgDark)
        .navigationTitle(file.path.lastPathComponentForDisplay)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sha + "|" + file.path) {
            await loadDiff()
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fileIcon.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(fileIcon.color)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fileIcon.color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(file.path.lastPathComponentForDisplay)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                        .lineLimit(1)

                    Text(file.status)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(GitStatusColor.color(for: file.status).opacity(0.12), in: Capsule())
                        .foregroundStyle(GitStatusColor.color(for: file.status))
                }

                if let parentPath = file.path.parentPathForDisplay {
                    Text(parentPath)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if let added = file.addedLines, added > 0 {
                    Text("+\(added)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffAdded)
                }
                if let removed = file.removedLines, removed > 0 {
                    Text("-\(removed)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.themeDiffRemoved)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }



    // MARK: - Data Loading

    private func loadDiff() async {
        guard let api = apiClient else {
            error = "Server is offline."
            return
        }

        do {
            diff = try await api.getCommitFileDiff(workspaceId: workspaceId, sha: sha, path: file.path)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
