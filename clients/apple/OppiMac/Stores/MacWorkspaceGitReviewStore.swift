import Foundation

protocol MacWorkspaceGitReviewing: Sendable {
    func getGitStatus(workspaceId: String, worktreeId: String?) async throws -> GitStatus
    func getWorkspaceReviewDiff(
        workspaceId: String,
        path: String,
        selectedSessionId: String?,
        worktreeId: String?
    ) async throws -> WorkspaceReviewDiffResponse
}

extension MacWorkspaceClient: MacWorkspaceGitReviewing {}

enum MacWorkspaceGitReviewPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case disabled
        case loading
        case unavailable(String)
        case notGitRepo
        case ready(GitStatus)
    }

    static let emptyMessage = "Working tree is clean."

    static func phase(
        gitStatusEnabled: Bool,
        isLoading: Bool,
        gitStatus: GitStatus?,
        error: String?
    ) -> Phase {
        guard gitStatusEnabled else { return .disabled }
        if let gitStatus {
            return gitStatus.isGitRepo ? .ready(gitStatus) : .notGitRepo
        }
        if let error {
            return .unavailable(error)
        }
        return .loading
    }

    static func reviewFiles(from status: GitStatus?) -> [WorkspaceReviewFile] {
        status?.files.map { $0.toReviewFile() } ?? []
    }

    static func summaryTitle(for status: GitStatus) -> String {
        status.branch ?? "Detached HEAD"
    }

    static func summaryCounts(for status: GitStatus) -> String {
        var parts: [String] = []
        if status.totalFiles > 0 {
            parts.append("\(status.totalFiles) changed")
        } else {
            parts.append("Clean")
        }
        if status.addedLines > 0 || status.removedLines > 0 {
            parts.append("+\(status.addedLines) −\(status.removedLines)")
        }
        if let ahead = status.ahead, ahead > 0 {
            parts.append("↑\(ahead)")
        }
        if let behind = status.behind, behind > 0 {
            parts.append("↓\(behind)")
        }
        return parts.joined(separator: " · ")
    }

    static func fileViewerPlan(
        workspaceID: String,
        file: WorkspaceReviewFile,
        worktreeId: String? = nil
    ) -> FileViewerPlan? {
        let trimmed = file.status.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "D" else { return nil }
        return .workspaceFile(workspaceID: workspaceID, path: file.path, worktreeId: worktreeId)
    }

    static func diffViewerPlan(workspaceID: String, file: WorkspaceReviewFile) -> FileViewerPlan {
        .workspaceReviewDiff(workspaceID: workspaceID, path: file.path)
    }

    static func diffDescriptor(from diff: WorkspaceReviewDiffResponse) -> ToolContentDescriptor {
        let lines = diff.hunks.flatMap { hunk in
            hunk.lines.map { line in
                DiffLine(
                    kind: diffLineKind(line.kind),
                    text: line.text,
                    oldLineNumber: line.oldLine,
                    newLineNumber: line.newLine
                )
            }
        }
        return .diff(ToolContentDescriptor.Diff(lines: lines, path: diff.path))
    }

    static func keepsSingleFileDiff(selectedPath: String, diff: WorkspaceReviewDiffResponse) -> Bool {
        diff.path == selectedPath
    }

    /// Refresh invalidates a hosted review diff. A deleted file also drops a stale file column.
    static func shouldClearOpenPlanAfterRefresh(
        _ plan: FileViewerPlan?,
        workspaceID: String,
        reviewFiles: [WorkspaceReviewFile]
    ) -> Bool {
        guard let plan else { return false }
        switch plan.source {
        case .workspaceReviewDiff(let planWorkspaceID, _):
            return planWorkspaceID == workspaceID
        case .workspaceFile(let planWorkspaceID, let path):
            guard planWorkspaceID == workspaceID else { return false }
            guard let file = reviewFiles.first(where: { $0.path == path }) else { return false }
            return fileViewerPlan(workspaceID: planWorkspaceID, file: file) == nil
        case .hostFile:
            return false
        }
    }

    private static func diffLineKind(_ kind: WorkspaceReviewDiffLine.Kind) -> DiffLine.Kind {
        switch kind {
        case .context: .context
        case .added: .added
        case .removed: .removed
        }
    }
}

@MainActor
@Observable
final class MacWorkspaceGitReviewStore {
    private(set) var gitStatus: GitStatus?
    private(set) var isLoadingStatus = false
    private(set) var statusError: String?
    private(set) var selectedPath: String?
    private(set) var selectedDiff: WorkspaceReviewDiffResponse?
    private(set) var isLoadingDiff = false
    private(set) var diffError: String?
    private(set) var workspaceId: String?
    private(set) var worktreeId: String?

    private var statusGeneration: UInt64 = 0
    private var diffGeneration: UInt64 = 0

    var reviewFiles: [WorkspaceReviewFile] {
        MacWorkspaceGitReviewPresentation.reviewFiles(from: gitStatus)
    }

    var selectedFile: WorkspaceReviewFile? {
        reviewFiles.first { $0.path == selectedPath }
    }

    var selectedDiffDescriptor: ToolContentDescriptor? {
        guard let selectedDiff else { return nil }
        return MacWorkspaceGitReviewPresentation.diffDescriptor(from: selectedDiff)
    }

    var selectedDiffViewerPlan: FileViewerPlan? {
        guard let workspaceId, let selectedFile else { return nil }
        return MacWorkspaceGitReviewPresentation.diffViewerPlan(
            workspaceID: workspaceId,
            file: selectedFile
        )
    }

    var selectedFileViewerPlan: FileViewerPlan? {
        guard let workspaceId, let selectedFile else { return nil }
        return MacWorkspaceGitReviewPresentation.fileViewerPlan(
            workspaceID: workspaceId,
            file: selectedFile,
            worktreeId: worktreeId
        )
    }

    func markUnavailable(_ message: String) {
        statusGeneration += 1
        diffGeneration += 1
        gitStatus = nil
        isLoadingStatus = false
        statusError = message
        selectedPath = nil
        selectedDiff = nil
        isLoadingDiff = false
        diffError = nil
    }

    func loadStatus(
        workspaceId: String,
        worktreeId: String = WorkspaceWorktree.mainId,
        gitStatusEnabled: Bool,
        client: any MacWorkspaceGitReviewing
    ) async {
        let generation = statusGeneration + 1
        statusGeneration = generation
        diffGeneration += 1
        let normalizedWorktreeId = worktreeId.isEmpty ? WorkspaceWorktree.mainId : worktreeId
        let checkoutChanged = self.workspaceId != workspaceId
            || (self.worktreeId ?? WorkspaceWorktree.mainId) != normalizedWorktreeId
        self.workspaceId = workspaceId
        self.worktreeId = normalizedWorktreeId
        selectedPath = nil
        selectedDiff = nil
        diffError = nil
        isLoadingDiff = false

        guard gitStatusEnabled else {
            gitStatus = nil
            isLoadingStatus = false
            statusError = nil
            return
        }

        if checkoutChanged {
            gitStatus = nil
        }
        isLoadingStatus = gitStatus == nil
        statusError = nil

        do {
            let status = try await client.getGitStatus(
                workspaceId: workspaceId,
                worktreeId: normalizedWorktreeId
            )
            guard statusGeneration == generation else { return }
            gitStatus = status
            isLoadingStatus = false
        } catch is CancellationError {
            return
        } catch {
            guard statusGeneration == generation else { return }
            gitStatus = nil
            statusError = error.localizedDescription
            isLoadingStatus = false
        }
    }

    func selectFile(_ path: String, client: any MacWorkspaceGitReviewing) async {
        guard let workspaceId else { return }
        let generation = diffGeneration + 1
        diffGeneration = generation
        selectedPath = path
        selectedDiff = nil
        diffError = nil
        isLoadingDiff = true

        do {
            let diff = try await client.getWorkspaceReviewDiff(
                workspaceId: workspaceId,
                path: path,
                selectedSessionId: nil,
                worktreeId: worktreeId
            )
            guard diffGeneration == generation, selectedPath == path else { return }
            selectedDiff = diff
            isLoadingDiff = false
        } catch is CancellationError {
            return
        } catch {
            guard diffGeneration == generation, selectedPath == path else { return }
            selectedDiff = nil
            diffError = error.localizedDescription
            isLoadingDiff = false
        }
    }
}
