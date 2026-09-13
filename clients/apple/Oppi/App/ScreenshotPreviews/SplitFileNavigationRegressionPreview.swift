#if DEBUG
import SwiftUI

// MARK: - Split File Navigation Regression Preview

struct SplitFileNavigationRegressionPreview: View {
    @State private var navigation = AppNavigation()
    @State private var lastPathCount = 0

    private static let workspace = Workspace(
        id: "preview-workspace",
        name: "oppi-dev",
        description: "Preview workspace",
        icon: .symbol("folder"),
        systemPrompt: nil,
        hostMount: "~/workspace/oppi",
        gitStatusEnabled: true,
        createdAt: Date(),
        updatedAt: Date()
    )

    private static let workspaceTarget = WorkspaceNavTarget(serverId: "preview-server", workspace: workspace)
    private static let sessionTarget = WorkspaceSessionNavTarget(serverId: "preview-server", sessionId: "session-1")
    private static let linkedFileTarget = WorkspaceLinkedFileNavTarget.workspaceFile(
        serverId: "preview-server",
        workspaceId: "preview-workspace",
        path: "notes/second.md",
        fileName: "second.md"
    )

    var body: some View {
        @Bindable var nav = navigation

        NavigationStack(path: $nav.workspacePath) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Split file navigation regression")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text("Open a session in split mode, push a linked file, then convert to compact stack.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                Button("Open split session link then compact") {
                    openSplitLinkThenCompact()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("splitFileNavigation.open")

                Text("Path count: \(lastPathCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
                    .accessibilityIdentifier("splitFileNavigation.pathCount")

                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.themeBg.ignoresSafeArea())
            .navigationTitle("Regression")
            .navigationDestination(for: WorkspaceSessionNavTarget.self) { target in
                SplitFileNavigationSessionProbe(target: target)
            }
            .navigationDestination(for: WorkspaceLinkedFileNavTarget.self) { target in
                SplitFileNavigationLinkedFileProbe(target: target)
            }
        }
        .environment(navigation)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func openSplitLinkThenCompact() {
        navigation.setWorkspaceNavigationPresentation(.split)
        navigation.openWorkspaceSession(Self.sessionTarget, workspace: Self.workspaceTarget)
        navigation.openWorkspaceLinkedFile(Self.linkedFileTarget, workspace: Self.workspaceTarget)
        navigation.setWorkspaceNavigationPresentation(.stack)
        lastPathCount = navigation.workspacePath.count
    }
}


private struct SplitFileNavigationSessionProbe: View {
    let target: WorkspaceSessionNavTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Session: \(target.sessionId)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("splitFileNavigation.session")

            Text("Back target preserved after compact conversion.")
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle("Session")
    }
}


private struct SplitFileNavigationLinkedFileProbe: View {
    @Environment(\.dismiss) private var dismiss
    let target: WorkspaceLinkedFileNavTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(linkedFileLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("splitFileNavigation.linkedFile")

            Text("This destination was reconstructed from split detail path metadata.")
                .font(.caption)
                .foregroundStyle(.themeComment)

            Button("Back to session") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("splitFileNavigation.backToSession")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.themeBg.ignoresSafeArea())
        .navigationTitle(fileName)
    }

    private var linkedFileLabel: String {
        switch target.kind {
        case .workspaceFile(let path, _):
            return "Linked file: \(path)"
        case .sessionFile(let path, _, _):
            return "Current file: \(path)"
        case .hostFile(let path, _):
            return "Host file: \(path)"
        }
    }

    private var fileName: String {
        switch target.kind {
        case .workspaceFile(_, let fileName),
             .sessionFile(_, let fileName, _),
             .hostFile(_, let fileName):
            return fileName
        }
    }
}
#endif
