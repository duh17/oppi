import Foundation
import Testing
@testable import Oppi

@Suite("SessionRowPresentationBuilder")
struct SessionRowPresentationBuilderTests {
    private func makeSession(
        id: String,
        status: SessionStatus = .stopped,
        parentSessionId: String? = nil,
        model: String? = "openai/gpt-5.5",
        cost: Double = 1,
        filesChanged: Int = 0,
        compactions: Int = 0
    ) -> Session {
        let stats = SessionChangeStats(
            mutatingToolCalls: filesChanged,
            compactionCount: compactions,
            filesChanged: filesChanged,
            changedFiles: (0..<filesChanged).map { "file-\($0).swift" },
            addedLines: 0,
            removedLines: 0
        )
        return Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Workspace",
            name: "Session \(id)",
            status: status,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            model: model,
            messageCount: 1,
            tokens: TokenUsage(input: 10, output: 5),
            cost: cost,
            changeStats: stats,
            contextTokens: nil,
            contextWindow: nil,
            firstMessage: "hello",
            lastMessage: nil,
            thinkingLevel: nil,
            parentSessionId: parentSessionId
        )
    }

    @Test func stoppedPresentationDoesNotDuplicateFileSummaryText() {
        let session = makeSession(id: "root", filesChanged: 3)
        let presentation = SessionRowPresentationBuilder.make(session: session)

        #expect(presentation.activitySummary == nil)
        #expect(presentation.session.changeStats?.filesChanged == 3)
    }

    @Test func childSummaryAggregatesParentAndDescendantMetrics() {
        let parent = makeSession(id: "parent", cost: 2, filesChanged: 4, compactions: 1)
        let child = makeSession(id: "child", status: .ready, parentSessionId: "parent", cost: 3, filesChanged: 5, compactions: 2)

        let summary = SessionRowPresentationBuilder.childSummary(for: parent, descendants: [child])

        #expect(summary?.childCount == 1)
        #expect(summary?.aggregateCost == 5)
        #expect(summary?.aggregateFilesChanged == 9)
        #expect(summary?.aggregateCompactionCount == 3)
        #expect(summary?.statusCounts.ready == 1)
    }

    @Test func attentionCountsIncludeDescendants() {
        let child = makeSession(id: "child", parentSessionId: "parent")
        let grandchild = makeSession(id: "grandchild", parentSessionId: "child")

        let counts = SessionRowPresentationBuilder.attentionCounts(
            sessionId: "parent",
            descendants: [child, grandchild],
            pendingAskCountForSession: { $0 == "child" ? 1 : 0 }
        )

        #expect(counts.askCount == 1)
    }
}
