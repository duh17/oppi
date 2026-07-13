#if DEBUG
import SwiftUI

/// Isolated visual fixture for reviewing git metadata in the compact workspace drawer.
struct WorkspaceSidebarGitStatusPreview: View {
    private struct Fixture: Identifiable {
        let workspace: Workspace
        let sessionStatus: WorkspaceSidebarSessionStatus
        let gitSummary: WorkspaceSidebarGitSummary?
        let isSelected: Bool

        var id: String { workspace.id }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            workspace: workspace(
                id: "oppi",
                name: "Oppi Mobile Client and Self-Hosted Server",
                description: "Native client and server runtime",
                icon: "iphone.and.arrow.forward"
            ),
            sessionStatus: WorkspaceSidebarSessionStatus(errorCount: 1, workingCount: 2),
            gitSummary: WorkspaceSidebarGitSummary(changedCount: 14, aheadCount: 3, behindCount: 1),
            isSelected: true
        ),
        Fixture(
            workspace: workspace(
                id: "kypu",
                name: "Kypu Fitness Data Platform",
                description: "Training and health data",
                icon: "figure.run"
            ),
            sessionStatus: WorkspaceSidebarSessionStatus(workingCount: 1),
            gitSummary: WorkspaceSidebarGitSummary(changedCount: 2, aheadCount: 0, behindCount: 0),
            isSelected: false
        ),
        Fixture(
            workspace: workspace(
                id: "chaosdonkey",
                name: "Chaosdonkey Writing and Publishing",
                description: "Blog and long-form writing",
                icon: "text.book.closed"
            ),
            sessionStatus: WorkspaceSidebarSessionStatus(doneCount: 1),
            gitSummary: nil,
            isSelected: false
        ),
        Fixture(
            workspace: workspace(
                id: "webtools",
                name: "Webtools Research Utilities",
                description: "Search, markets, and fetch tools",
                icon: "globe"
            ),
            sessionStatus: WorkspaceSidebarSessionStatus(),
            gitSummary: WorkspaceSidebarGitSummary(changedCount: 0, aheadCount: 0, behindCount: 6),
            isSelected: false
        ),
        Fixture(
            workspace: workspace(
                id: "design-system",
                name: "A Very Long Workspace Name Without Git Changes",
                description: "Description remains when git is quiet",
                icon: "paintpalette"
            ),
            sessionStatus: WorkspaceSidebarSessionStatus(questionCount: 2),
            gitSummary: nil,
            isSelected: false
        ),
    ]

    var body: some View {
        GeometryReader { proxy in
            let sidebarWidth = min(proxy.size.width * 0.80, 320)

            ZStack(alignment: .topLeading) {
                Color.themeBg
                    .ignoresSafeArea()

                sidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)

                previewForeground
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color.themeBgDark)
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 22, x: -5)
                    .offset(x: sidebarWidth)
                    .accessibilityHidden(true)
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screenshot.ready")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Workspaces")
                .font(.title2.weight(.bold))
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 2) {
                    ForEach(Self.fixtures) { fixture in
                        WorkspaceSidebarRow(
                            workspace: fixture.workspace,
                            status: fixture.sessionStatus,
                            gitSummary: fixture.gitSummary,
                            isSelected: fixture.isSelected
                        )
                        .accessibilityIdentifier("workspace.gitPreview.\(fixture.id)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.themeBlue)

                Text("New Workspace")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
        }
        .background(Color.themeBg.ignoresSafeArea())
    }

    private var previewForeground: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.themeComment.opacity(0.28))
                .frame(width: 110, height: 8)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.themeComment.opacity(0.16))
                .frame(width: 180, height: 8)
            Spacer()
        }
        .padding(.top, 82)
        .padding(.horizontal, 22)
    }

    private static func workspace(
        id: String,
        name: String,
        description: String,
        icon: String
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            description: description,
            icon: icon,
            systemPrompt: nil,
            hostMount: "~/workspace/\(id)",
            gitStatusEnabled: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
#endif
