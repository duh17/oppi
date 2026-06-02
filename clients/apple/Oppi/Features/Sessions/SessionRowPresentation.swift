import Foundation

/// Immutable row inputs shared by workspace session surfaces.
///
/// `SessionRow` owns the visual layout. This type keeps the presentation data
/// that feeds it consistent across home previews, workspace detail, and stopped
/// history rows without making the row read observable stores directly.
struct SessionRowPresentation {
    let session: Session
    let pendingAskCount: Int
    let activitySummary: String?
    let lineageHint: String?
    let children: SessionRow.ChildSummary?
    let modelSummaries: [SessionModelSummary]
    let searchSnippet: AttributedString?
}

enum SessionRowPresentationBuilder {
    static func make(
        session: Session,
        descendants: [Session] = [],
        pendingAskCount: Int = 0,
        pendingAsk: AskRequest? = nil,
        activity: SessionActivityStore.Activity? = nil,
        lineageHint: String? = nil,
        searchSnippet: AttributedString? = nil
    ) -> SessionRowPresentation {
        SessionRowPresentation(
            session: session,
            pendingAskCount: pendingAskCount,
            activitySummary: SessionActivitySummary.text(
                session: session,
                pendingAsk: pendingAsk,
                activity: activity
            ),
            lineageHint: lineageHint,
            children: childSummary(for: session, descendants: descendants),
            modelSummaries: modelSummaries(for: session, descendants: descendants),
            searchSnippet: searchSnippet
        )
    }

    static func attentionCounts(
        sessionId: String,
        descendants: [Session],
        pendingAskCountForSession: (String) -> Int
    ) -> SessionListAttentionCounts {
        let ids = [sessionId] + descendants.map(\.id)
        return SessionListAttentionCounts(
            askCount: ids.reduce(0) { $0 + pendingAskCountForSession($1) }
        )
    }

    static func modelSummaries(for session: Session, descendants: [Session]) -> [SessionModelSummary] {
        SessionModelSummaryBuilder.summaries(
            primaryModel: session.model,
            descendantModels: descendants.compactMap(\.model)
        )
    }

    static func childSummary(
        for session: Session,
        descendants: [Session]
    ) -> SessionRow.ChildSummary? {
        guard !descendants.isEmpty else { return nil }

        var counts = SessionTreeHelper.StatusCounts()
        var totalCost = session.cost
        var aggregateCompactionCount = max(0, session.changeStats?.compactionCount ?? 0)
        var aggregateFilesChanged = max(0, session.changeStats?.filesChanged ?? 0)

        for descendant in descendants {
            counts.total += 1
            switch descendant.status {
            case .starting, .busy, .stopping: counts.working += 1
            case .ready: counts.ready += 1
            case .stopped: counts.stopped += 1
            case .error: counts.error += 1
            }
            totalCost += descendant.cost
            aggregateCompactionCount += max(0, descendant.changeStats?.compactionCount ?? 0)
            aggregateFilesChanged += max(0, descendant.changeStats?.filesChanged ?? 0)
        }

        return .init(
            childCount: descendants.count,
            statusCounts: counts,
            aggregateCost: totalCost,
            aggregateCompactionCount: aggregateCompactionCount,
            aggregateFilesChanged: aggregateFilesChanged
        )
    }
}

extension SessionRow {
    init(presentation: SessionRowPresentation) {
        self.init(
            session: presentation.session,
            pendingAskCount: presentation.pendingAskCount,
            activitySummary: presentation.activitySummary,
            lineageHint: presentation.lineageHint,
            children: presentation.children,
            modelSummaries: presentation.modelSummaries,
            searchSnippet: presentation.searchSnippet
        )
    }
}
