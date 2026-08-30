import SwiftUI

struct MacWorkspaceGitStatusView: View {
    let workspace: Workspace
    let worktreeId: String
    @Binding var openPlan: FileViewerPlan?
    @Binding var openDescriptor: ToolContentDescriptor?
    @Binding var isLoadingDocument: Bool
    @Binding var documentError: String?

    @State private var store = MacWorkspaceGitReviewStore()

    private var gitStatusEnabled: Bool {
        workspace.gitStatusEnabled ?? true
    }

    var body: some View {
        gitCard
            .accessibilityIdentifier("workspace.gitStatus")
            .task(id: "\(workspace.id):\(worktreeId)") {
                await loadStatus()
            }
            .onChange(of: gitStatusEnabled) { _, _ in
                Task { await loadStatus() }
            }
    }

    private var gitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Git status", systemImage: "arrow.triangle.branch")
                .font(.headline)
            if case .ready(let status) = currentPhase {
                Text(MacWorkspaceGitReviewPresentation.summaryTitle(for: status))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(MacWorkspaceGitReviewPresentation.summaryCounts(for: status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await loadStatus() }
            } label: {
                Label("Refresh Git Status", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(store.isLoadingStatus || !gitStatusEnabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch currentPhase {
        case .disabled:
            ContentUnavailableView(
                "Git status off",
                systemImage: "eye.slash",
                description: Text("Turn on workspace changes to load git status for this folder.")
            )
            .frame(maxWidth: .infinity, minHeight: 80)
        case .loading:
            ProgressView("Loading git status...")
                .frame(maxWidth: .infinity, minHeight: 80)
        case .unavailable(let error):
            ContentUnavailableView(
                "Could not load git status",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, minHeight: 80)
        case .notGitRepo:
            ContentUnavailableView(
                "Not a git repository",
                systemImage: "folder",
                description: Text("This workspace folder has no git history to review.")
            )
            .frame(maxWidth: .infinity, minHeight: 80)
        case .ready(let status):
            readyContent(status)
        }
    }

    @ViewBuilder
    private func readyContent(_ status: GitStatus) -> some View {
        if let message = status.lastCommitMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        if store.reviewFiles.isEmpty {
            ContentUnavailableView(
                MacWorkspaceGitReviewPresentation.emptyMessage,
                systemImage: "checkmark.circle",
                description: Text("No files to open for review.")
            )
            .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            fileList
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(store.reviewFiles) { file in
                    fileRow(file)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 80, maxHeight: 220)
    }

    private func fileRow(_ file: WorkspaceReviewFile) -> some View {
        let isSelected = store.selectedPath == file.path
        return Button {
            Task { await openDiff(file) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.forwardslash.minus")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(file.statusLabel)
                        if let added = file.addedLines, let removed = file.removedLines {
                            Text("+\(added) −\(removed)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open diff") {
                Task { await openDiff(file) }
            }
            if MacWorkspaceGitReviewPresentation.fileViewerPlan(
                workspaceID: workspace.id,
                file: file
            ) != nil {
                Button("Open file") {
                    openWorkspaceFile(file)
                }
            }
        }
    }

    private var currentPhase: MacWorkspaceGitReviewPresentation.Phase {
        MacWorkspaceGitReviewPresentation.phase(
            gitStatusEnabled: gitStatusEnabled,
            isLoading: store.isLoadingStatus,
            gitStatus: store.gitStatus,
            error: store.statusError
        )
    }

    private func loadStatus() async {
        guard let client = MacWorkspaceClient.localOwner() else {
            store.markUnavailable("Local server config is not initialized yet.")
            clearStaleDocumentColumnIfNeeded()
            return
        }
        await store.loadStatus(
            workspaceId: workspace.id,
            worktreeId: worktreeId,
            gitStatusEnabled: gitStatusEnabled,
            client: client
        )
        clearStaleDocumentColumnIfNeeded()
    }

    private func openDiff(_ file: WorkspaceReviewFile) async {
        guard let client = MacWorkspaceClient.localOwner() else {
            store.markUnavailable("Local server config is not initialized yet.")
            return
        }
        let plan = MacWorkspaceGitReviewPresentation.diffViewerPlan(
            workspaceID: workspace.id,
            file: file
        )
        isLoadingDocument = true
        openDescriptor = nil
        documentError = nil
        openPlan = plan
        await store.selectFile(file.path, client: client)
        guard openPlan == plan else { return }
        isLoadingDocument = false
        if let descriptor = store.selectedDiffDescriptor {
            openDescriptor = descriptor
            documentError = nil
        } else {
            openDescriptor = nil
            documentError = store.diffError ?? "Could not load diff."
        }
    }

    private func openWorkspaceFile(_ file: WorkspaceReviewFile) {
        if let plan = MacWorkspaceGitReviewPresentation.fileViewerPlan(
            workspaceID: workspace.id,
            file: file,
            worktreeId: worktreeId
        ) {
            openPlan = plan
            return
        }
        openPlan = nil
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = false
    }

    private func clearStaleDocumentColumnIfNeeded() {
        guard MacWorkspaceGitReviewPresentation.shouldClearOpenPlanAfterRefresh(
            openPlan,
            workspaceID: workspace.id,
            reviewFiles: store.reviewFiles
        ) else { return }
        openPlan = nil
        openDescriptor = nil
        documentError = nil
        isLoadingDocument = false
    }
}
