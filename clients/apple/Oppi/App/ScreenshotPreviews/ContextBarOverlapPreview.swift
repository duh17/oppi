#if DEBUG
import SwiftUI

// MARK: - Context Bar Overlap Preview

struct ContextBarOverlapPreview: View {
    @State private var connection = ServerConnection()

    private static let workspaceId = "preview-workspace"
    private static let currentSessionId = "session-current"

    private static let gitStatus = GitStatus(
        isGitRepo: true,
        branch: "main",
        headSha: "9f81c2a",
        ahead: 0,
        behind: 0,
        dirtyCount: 3,
        untrackedCount: 0,
        stagedCount: 0,
        files: [
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/ChatView.swift", addedLines: 18, removedLines: 4),
            GitFileStatus(status: " M", path: "clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift", addedLines: 42, removedLines: 9),
            GitFileStatus(status: " M", path: "server/src/session-events.ts", addedLines: 11, removedLines: 2),
        ],
        totalFiles: 3,
        addedLines: 71,
        removedLines: 15,
        stashCount: 0,
        lastCommitMessage: "Polish session context bar",
        lastCommitDate: nil,
        recentCommits: []
    )

    var body: some View {
        ZStack(alignment: .top) {
            Color.themeBg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cross-session overlap")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.themeFg)
                    Text("The current session still owns the list. The amber badge only marks files another session also touched.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                WorkspaceContextBar(
                    gitStatus: Self.gitStatus,
                    isLoading: false,
                    workspaceId: Self.workspaceId,
                    sessionId: Self.currentSessionId,
                    initialExpanded: true
                )

                Spacer()
            }
        }
        .environment(connection.sessionStore)
        .environment(connection.askRequestStore)
        .environment(\.apiClient, connection.apiClient)
        .onAppear(perform: configureSessions)
        .accessibilityIdentifier("screenshot.ready")
    }

    private func configureSessions() {
        connection.sessionStore.switchServer(to: "preview-server")
        connection.sessionStore.activeSessionId = Self.currentSessionId
        connection.sessionStore.sessions = [Self.currentSession(), Self.otherSession()]
    }

    private static func currentSession() -> Session {
        var session = makeSession(id: currentSessionId, name: "Current session")
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 2,
            filesChanged: 2,
            changedFiles: [
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/ChatView.swift",
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift",
            ],
            changedFilesOverflow: nil,
            addedLines: 60,
            removedLines: 13
        )
        return session
    }

    private static func otherSession() -> Session {
        var session = makeSession(id: "session-other", name: "Parallel review")
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 2,
            filesChanged: 2,
            changedFiles: [
                "/Users/example/workspace/oppi/clients/apple/Oppi/Features/Chat/Support/WorkspaceContextBar.swift",
                "/Users/example/workspace/oppi/server/src/session-events.ts",
            ],
            changedFilesOverflow: nil,
            addedLines: 53,
            removedLines: 11
        )
        return session
    }

    private static func makeSession(id: String, name: String) -> Session {
        var session = Session(
            id: id,
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_000_100),
            messageCount: 4,
            tokens: TokenUsage(input: 1_000, output: 500),
            cost: 0.02
        )
        session.workspaceId = workspaceId
        session.name = name
        return session
    }
}
#endif
