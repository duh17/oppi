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
    let modelSummaries: [SessionModelSummary]
    let searchSnippet: AttributedString?
}

enum SessionRowPresentationBuilder {
    static func make(
        session: Session,
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
            modelSummaries: modelSummaries(for: session),
            searchSnippet: searchSnippet
        )
    }

    static func attentionCounts(
        sessionId: String,
        pendingAskCountForSession: (String) -> Int
    ) -> SessionListAttentionCounts {
        SessionListAttentionCounts(askCount: pendingAskCountForSession(sessionId))
    }

    static func modelSummaries(for session: Session) -> [SessionModelSummary] {
        SessionModelSummaryBuilder.summaries(
            primaryModel: session.model,
            descendantModels: []
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
            modelSummaries: presentation.modelSummaries,
            searchSnippet: presentation.searchSnippet
        )
    }
}
