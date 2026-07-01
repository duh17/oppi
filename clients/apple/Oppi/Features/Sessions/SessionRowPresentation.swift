import Foundation

/// Immutable row inputs shared by workspace session surfaces.
///
/// `SessionRow` owns the visual layout. This type keeps the presentation data
/// that feeds it consistent across home previews, workspace detail, and stopped
/// history rows without making the row read observable stores directly.
struct SessionRowPresentation {
    let session: Session
    let pendingAskCount: Int
    let attentionText: String?
    let lineageHint: String?
    let modelSummaries: [SessionModelSummary]
    let unreadCompletionAt: Date?
    let searchSnippet: AttributedString?
}

enum SessionRowPresentationBuilder {
    static func make(
        session: Session,
        pendingAskCount: Int = 0,
        pendingAsk: AskRequest? = nil,
        lineageHint: String? = nil,
        unreadCompletionAt: Date? = nil,
        searchSnippet: AttributedString? = nil
    ) -> SessionRowPresentation {
        SessionRowPresentation(
            session: session,
            pendingAskCount: pendingAskCount,
            attentionText: attentionText(for: pendingAsk) ?? attentionText(forPendingAskCount: pendingAskCount),
            lineageHint: lineageHint,
            modelSummaries: modelSummaries(for: session),
            unreadCompletionAt: unreadCompletionAt,
            searchSnippet: searchSnippet
        )
    }

    static func attentionCounts(
        sessionId: String,
        pendingAskCountForSession: (String) -> Int
    ) -> SessionListAttentionCounts {
        SessionListAttentionCounts(askCount: pendingAskCountForSession(sessionId))
    }

    static func attentionText(for pendingAsk: AskRequest?) -> String? {
        guard let question = pendingAsk?.questions.first?.question else { return nil }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let truncated = trimmed.count > 40 ? String(trimmed.prefix(40)) + "..." : trimmed
        return "question: \(truncated)"
    }

    static func attentionText(forPendingAskCount pendingAskCount: Int) -> String? {
        pendingAskCount > 0 ? "question pending" : nil
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
            attentionText: presentation.attentionText,
            lineageHint: presentation.lineageHint,
            modelSummaries: presentation.modelSummaries,
            unreadCompletionAt: presentation.unreadCompletionAt,
            searchSnippet: presentation.searchSnippet
        )
    }
}
