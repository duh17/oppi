import SwiftUI

/// Centralized session change browser.
///
/// Groups edit/write tool calls by file and lets users drill into per-change
/// diff/content using native list navigation.
struct SessionChangesView: View {
    let sessionId: String
    let workspaceId: String?
    let items: [ChatItem]
    let searchText: String

    @Environment(ToolArgsStore.self) private var toolArgsStore

    private var allFileChanges: [SessionFileChangeEntry] {
        var entries: [SessionFileChangeEntry] = []
        entries.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            guard case .toolCall(let id, let tool, let argsSummary, _, _, let isError, _) = item else {
                continue
            }
            guard !isError else { continue }

            let normalized = ToolCallFormatting.normalized(tool)
            guard normalized == "edit" || normalized == "write" else { continue }

            let args = toolArgsStore.args(for: id)
            guard let rawPath = ToolCallFormatting.filePath(from: args)
                ?? ToolCallFormatting.parseArgValue("path", from: argsSummary) else {
                continue
            }

            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }

            if normalized == "edit" {
                let stats = ToolCallFormatting.editDiffStats(from: args)
                let entry = SessionFileChangeEntry(
                    id: id,
                    kind: .edit,
                    path: path,
                    oldText: args?["oldText"]?.stringValue,
                    newText: args?["newText"]?.stringValue,
                    writeContent: nil,
                    addedLines: stats?.added ?? 0,
                    removedLines: stats?.removed ?? 0,
                    order: index
                )
                entries.append(entry)
            } else {
                let content = args?["content"]?.stringValue
                let entry = SessionFileChangeEntry(
                    id: id,
                    kind: .write,
                    path: path,
                    oldText: nil,
                    newText: nil,
                    writeContent: content,
                    addedLines: content.map(Self.lineCount(of:)) ?? 0,
                    removedLines: 0,
                    order: index
                )
                entries.append(entry)
            }
        }

        return entries
    }

    private var fileChangeGroups: [SessionFileChangeGroup] {
        let grouped = Dictionary(grouping: allFileChanges, by: \.path)
        return grouped
            .map { path, entries in
                SessionFileChangeGroup(
                    path: path,
                    entries: entries.sorted { $0.order > $1.order }
                )
            }
            .sorted { lhs, rhs in
                (lhs.entries.first?.order ?? -1) > (rhs.entries.first?.order ?? -1)
            }
    }

    private var filteredChangeGroups: [SessionFileChangeGroup] {
        guard !searchText.isEmpty else { return fileChangeGroups }
        let query = searchText.lowercased()
        return fileChangeGroups.filter { group in
            if group.path.lowercased().contains(query) {
                return true
            }
            return group.entries.contains { entry in
                entry.kind.label.lowercased().contains(query)
            }
        }
    }

    private var totalChangeCount: Int {
        allFileChanges.count
    }

    private var totalFilesChanged: Int {
        fileChangeGroups.count
    }

    private var totalAddedLines: Int {
        allFileChanges.reduce(0) { $0 + $1.addedLines }
    }

    private var totalRemovedLines: Int {
        allFileChanges.reduce(0) { $0 + $1.removedLines }
    }

    var body: some View {
        if fileChangeGroups.isEmpty {
            ContentUnavailableView(
                "No File Changes",
                systemImage: "doc.badge.plus",
                description: Text("Edit and write tool calls will appear here.")
            )
        } else if filteredChangeGroups.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                Section("Summary") {
                    LabeledContent("Files Changed") {
                        Text("\(totalFilesChanged)")
                            .foregroundStyle(.tokyoFg)
                    }
                    LabeledContent("Total Changes") {
                        Text("\(totalChangeCount)")
                            .foregroundStyle(.tokyoFg)
                    }
                    if totalAddedLines > 0 || totalRemovedLines > 0 {
                        HStack(spacing: 10) {
                            if totalAddedLines > 0 {
                                Text("+\(totalAddedLines)")
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(.tokyoGreen)
                            }
                            if totalRemovedLines > 0 {
                                Text("-\(totalRemovedLines)")
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(.tokyoRed)
                            }
                        }
                    }
                }

                Section("Changed Files") {
                    ForEach(filteredChangeGroups) { group in
                        NavigationLink {
                            FileChangeGroupView(
                                sessionId: sessionId,
                                workspaceId: workspaceId,
                                group: group
                            )
                        } label: {
                            FileChangeGroupRow(group: group)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.tokyoBg)
        }
    }

    private static func lineCount(of text: String) -> Int {
        if text.isEmpty { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

// MARK: - Change Models

private enum SessionFileChangeKind: String, Sendable {
    case edit
    case write

    var icon: String {
        switch self {
        case .edit: return "pencil"
        case .write: return "square.and.pencil"
        }
    }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .write: return "Write"
        }
    }

    var detailActionLabel: String {
        switch self {
        case .edit: return "Modify existing file"
        case .write: return "Create or overwrite file"
        }
    }
}

private struct SessionFileChangeEntry: Identifiable, Sendable {
    let id: String
    let kind: SessionFileChangeKind
    let path: String
    let oldText: String?
    let newText: String?
    let writeContent: String?
    let addedLines: Int
    let removedLines: Int
    let order: Int
}

private struct SessionFileChangeGroup: Identifiable, Sendable {
    let path: String
    let entries: [SessionFileChangeEntry]

    var id: String { path }

    var totalAddedLines: Int {
        entries.reduce(0) { $0 + $1.addedLines }
    }

    var totalRemovedLines: Int {
        entries.reduce(0) { $0 + $1.removedLines }
    }

    var editCount: Int {
        entries.filter { $0.kind == .edit }.count
    }

    var writeCount: Int {
        entries.filter { $0.kind == .write }.count
    }
}

private struct SessionOverallFileDiff: Sendable {
    let oldText: String
    let newText: String
    let diffLines: [DiffLine]
}

// MARK: - File Change Views

private struct FileChangeGroupRow: View {
    let group: SessionFileChangeGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.path.shortenedPath)
                .font(.subheadline.monospaced())
                .foregroundStyle(.tokyoFg)
                .lineLimit(1)

            HStack(spacing: 10) {
                Text("\(group.entries.count) changes")
                    .font(.caption)
                    .foregroundStyle(.tokyoComment)

                if group.editCount > 0 {
                    Text("edit \(group.editCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tokyoCyan)
                }

                if group.writeCount > 0 {
                    Text("write \(group.writeCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tokyoBlue)
                }

                if group.totalAddedLines > 0 {
                    Text("+\(group.totalAddedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.tokyoGreen)
                }

                if group.totalRemovedLines > 0 {
                    Text("-\(group.totalRemovedLines)")
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(.tokyoRed)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private actor SessionOverallDiffCache {
    static let shared = SessionOverallDiffCache()
    private var values: [String: APIClient.SessionOverallDiffResponse] = [:]

    func get(key: String) -> APIClient.SessionOverallDiffResponse? {
        values[key]
    }

    func set(key: String, value: APIClient.SessionOverallDiffResponse) {
        values[key] = value
    }
}

private struct FileChangeGroupView: View {
    let sessionId: String
    let workspaceId: String?
    let group: SessionFileChangeGroup

    @Environment(ServerConnection.self) private var connection

    @State private var remoteDiff: APIClient.SessionOverallDiffResponse?
    @State private var remoteError: String?
    @State private var loadingRemoteDiff = false

    private var cacheKey: String {
        "\(workspaceId ?? "legacy")|\(sessionId)|\(group.path)"
    }

    private var overallDiff: SessionOverallFileDiff? {
        guard let remoteDiff else { return nil }
        return SessionOverallFileDiff(
            oldText: remoteDiff.baselineText,
            newText: remoteDiff.currentText,
            diffLines: remoteDiff.diffLines.map { line in
                let kind: DiffLine.Kind
                switch line.kind {
                case .context: kind = .context
                case .added: kind = .added
                case .removed: kind = .removed
                }
                return DiffLine(kind: kind, text: line.text)
            }
        )
    }

    private var overallDiffStats: (added: Int, removed: Int)? {
        guard let remoteDiff else { return nil }
        return (added: remoteDiff.addedLines, removed: remoteDiff.removedLines)
    }

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Path") {
                    Text(group.path.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                }
                LabeledContent("Revisions") {
                    Text("\(group.entries.count)")
                        .foregroundStyle(.tokyoFg)
                }

                if let stats = overallDiffStats {
                    HStack(spacing: 10) {
                        if stats.added > 0 {
                            Text("+\(stats.added)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoGreen)
                        }
                        if stats.removed > 0 {
                            Text("-\(stats.removed)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoRed)
                        }
                        if stats.added == 0 && stats.removed == 0 {
                            Text("no net change")
                                .font(.caption)
                                .foregroundStyle(.tokyoComment)
                        }
                    }
                } else if group.totalAddedLines > 0 || group.totalRemovedLines > 0 {
                    HStack(spacing: 10) {
                        if group.totalAddedLines > 0 {
                            Text("+\(group.totalAddedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoGreen)
                        }
                        if group.totalRemovedLines > 0 {
                            Text("-\(group.totalRemovedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoRed)
                        }
                    }
                }
            }

            if let overallDiff {
                Section {
                    NavigationLink {
                        OverallFileDiffDetailView(
                            filePath: group.path,
                            overallDiff: overallDiff,
                            revisionCount: remoteDiff?.revisionCount ?? group.entries.count
                        )
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.caption)
                                .foregroundStyle(.tokyoPurple)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Overall Diff")
                                    .font(.subheadline)
                                    .foregroundStyle(.tokyoFg)
                                Text("Revision 1 → Revision \(remoteDiff?.revisionCount ?? group.entries.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tokyoComment)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Overview")
                }
            } else if loadingRemoteDiff {
                Section("Overview") {
                    ProgressView("Loading overall diff…")
                        .tint(.tokyoPurple)
                }
            } else if let remoteError {
                Section("Overview") {
                    Text(remoteError)
                        .font(.caption)
                        .foregroundStyle(.tokyoComment)
                }
            }

            Section("Revisions") {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    let ordinal = group.entries.count - index
                    NavigationLink {
                        FileChangeEntryDetailView(entry: entry, filePath: group.path)
                    } label: {
                        FileChangeEntryRow(entry: entry, ordinal: ordinal)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.tokyoBg)
        .navigationTitle(group.path.shortenedPath)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: cacheKey) {
            await loadOverallDiffIfNeeded()
        }
    }

    private func loadOverallDiffIfNeeded() async {
        if remoteDiff != nil || loadingRemoteDiff { return }

        if let cached = await SessionOverallDiffCache.shared.get(key: cacheKey) {
            remoteDiff = cached
            return
        }

        guard let apiClient = connection.apiClient else {
            remoteError = "Overall diff unavailable (offline)."
            return
        }
        guard let workspaceId, !workspaceId.isEmpty else {
            remoteError = "Overall diff unavailable (missing workspace)."
            return
        }

        loadingRemoteDiff = true
        defer { loadingRemoteDiff = false }

        do {
            let diff = try await apiClient.getSessionOverallDiff(
                sessionId: sessionId,
                workspaceId: workspaceId,
                path: group.path
            )
            remoteDiff = diff
            remoteError = nil
            await SessionOverallDiffCache.shared.set(key: cacheKey, value: diff)
        } catch {
            remoteError = "Overall diff unavailable."
        }
    }
}

private struct FileChangeEntryRow: View {
    let entry: SessionFileChangeEntry
    let ordinal: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.icon)
                .font(.caption)
                .foregroundStyle(entry.kind == .edit ? .tokyoCyan : .tokyoBlue)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(entry.kind.label) #\(ordinal)")
                    .font(.subheadline)
                    .foregroundStyle(.tokyoFg)

                HStack(spacing: 8) {
                    if entry.addedLines > 0 {
                        Text("+\(entry.addedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoGreen)
                    }
                    if entry.removedLines > 0 {
                        Text("-\(entry.removedLines)")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(.tokyoRed)
                    }
                    if entry.addedLines == 0 && entry.removedLines == 0 {
                        Text("modified")
                            .font(.caption2)
                            .foregroundStyle(.tokyoComment)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OverallFileDiffDetailView: View {
    let filePath: String
    let overallDiff: SessionOverallFileDiff
    let revisionCount: Int

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Path") {
                    Text(filePath.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                }
                LabeledContent("Range") {
                    Text("Revision 1 → Revision \(revisionCount)")
                        .foregroundStyle(.tokyoFg)
                }
            }

            Section("Overall Diff") {
                AsyncDiffView(
                    oldText: overallDiff.oldText,
                    newText: overallDiff.newText,
                    filePath: filePath,
                    showHeader: true,
                    precomputedLines: overallDiff.diffLines
                )
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.tokyoBg)
        .navigationTitle("Overall Diff")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FileChangeEntryDetailView: View {
    let entry: SessionFileChangeEntry
    let filePath: String

    var body: some View {
        List {
            Section("Change") {
                LabeledContent("Action") {
                    Text(entry.kind.detailActionLabel)
                        .foregroundStyle(.tokyoFg)
                }
                LabeledContent("Path") {
                    Text(filePath.shortenedPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tokyoFg)
                }
                if entry.addedLines > 0 || entry.removedLines > 0 {
                    HStack(spacing: 10) {
                        if entry.addedLines > 0 {
                            Text("+\(entry.addedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoGreen)
                        }
                        if entry.removedLines > 0 {
                            Text("-\(entry.removedLines)")
                                .font(.caption.monospaced().bold())
                                .foregroundStyle(.tokyoRed)
                        }
                    }
                }
            }

            Section(entry.kind == .edit ? "Diff" : "Content") {
                contentView
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.tokyoBg)
        .navigationTitle(entry.kind == .edit ? "Change Detail" : "Write Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var contentView: some View {
        switch entry.kind {
        case .edit:
            if let oldText = entry.oldText, let newText = entry.newText {
                AsyncDiffView(
                    oldText: oldText,
                    newText: newText,
                    filePath: filePath,
                    showHeader: true
                )
            } else {
                Text("Diff unavailable for this change.")
                    .font(.caption)
                    .foregroundStyle(.tokyoComment)
            }

        case .write:
            if let content = entry.writeContent {
                FileContentView(content: content, filePath: filePath)
            } else {
                Text("Write content unavailable for this change.")
                    .font(.caption)
                    .foregroundStyle(.tokyoComment)
            }
        }
    }
}
