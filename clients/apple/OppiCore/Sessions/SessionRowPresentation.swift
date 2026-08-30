import Foundation

struct SessionModelSummary: Identifiable, Equatable, Sendable {
    let rawModel: String
    let provider: String
    let label: String

    var id: String { rawModel }
}

enum SessionModelSummaryBuilder {
    static func summaries(primaryModel: String?, descendantModels: [String] = []) -> [SessionModelSummary] {
        let candidates = [primaryModel] + descendantModels.map(Optional.some)
        var seen: Set<String> = []
        var result: [SessionModelSummary] = []

        for candidate in candidates {
            guard let normalized = normalize(candidate), seen.insert(normalized).inserted else {
                continue
            }

            result.append(
                SessionModelSummary(
                    rawModel: normalized,
                    provider: provider(from: normalized),
                    label: displayLabel(for: normalized)
                )
            )
        }

        return result
    }

    static func displayLabel(for rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        if let slashIndex = trimmed.firstIndex(of: "/") {
            let remainder = String(trimmed[trimmed.index(after: slashIndex)...])
            if !remainder.isEmpty {
                return remainder
            }
        }

        return trimmed
    }

    private static func normalize(_ rawModel: String?) -> String? {
        guard let rawModel else { return nil }
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func provider(from rawModel: String) -> String {
        guard let slashIndex = rawModel.firstIndex(of: "/"), slashIndex != rawModel.startIndex else {
            return ""
        }
        return String(rawModel[rawModel.startIndex..<slashIndex])
    }
}

struct SessionWorktreeIndicatorPresentation: Equatable, Sendable {
    let worktreeId: String
    let accessibilityLabel: String

    init?(session: Session) {
        guard let worktreeId = Self.normalizedWorktreeId(session.worktreeId) else { return nil }
        self.worktreeId = worktreeId
        accessibilityLabel = "Worktree session"
    }

    private static func normalizedWorktreeId(_ rawWorktreeId: String?) -> String? {
        guard let rawWorktreeId else { return nil }
        let trimmed = rawWorktreeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != WorkspaceWorktree.mainId else { return nil }
        return trimmed
    }
}

enum SessionRowMetricsFormatting {
    static func filesTouchedAccessibilityLabel(_ filesChanged: Int) -> String {
        filesChanged == 1 ? String(localized: "1 file touched") : String(localized: "\(filesChanged) files touched")
    }

    static func compactionAccessibilityLabel(_ compactionCount: Int) -> String {
        compactionCount == 1 ? "1 compaction" : "\(compactionCount) compactions"
    }
}

/// Status kind for session rows. Colors stay in the platform paint layer.
enum SessionRowStatusKind: Equatable, Sendable {
    case question
    case idle
    case working
    case done
    case stopped
    case error

    /// Priority: ask/input request > status-based.
    static func from(status: SessionStatus, pendingAskCount: Int = 0) -> SessionRowStatusKind {
        if pendingAskCount > 0 { return .question }

        switch status {
        case .busy, .starting, .stopping:
            return .working
        case .ready:
            return .done
        case .stopped:
            return .stopped
        case .error:
            return .error
        }
    }

    static func from(session: Session, pendingAskCount: Int = 0) -> SessionRowStatusKind {
        if pendingAskCount > 0 { return .question }
        if session.isAwaitingFirstPrompt { return .idle }
        return from(status: session.status)
    }

    var label: String {
        switch self {
        case .question: "Question"
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .stopped: "Stopped"
        case .error: "Error"
        }
    }
}

/// Immutable row inputs shared by workspace session surfaces.
///
/// Platform rows own visual layout. This type keeps the presentation data
/// that feeds them consistent across home, workspace detail, and stopped
/// history without making the row read observable stores directly.
struct SessionRowPresentation: Equatable, Sendable {
    let session: Session
    let pendingAskCount: Int
    let attentionText: String?
    let lineageHint: String?
    let workspaceContext: String?
    let modelSummaries: [SessionModelSummary]
    let unreadCompletionAt: Date?
    let searchSnippet: AttributedString?

    var statusKind: SessionRowStatusKind {
        SessionRowStatusKind.from(session: session, pendingAskCount: pendingAskCount)
    }

    var visibleModelSummaries: [SessionModelSummary] {
        if !modelSummaries.isEmpty {
            return modelSummaries
        }
        return SessionModelSummaryBuilder.summaries(primaryModel: session.model)
    }

    var contextPercent: Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow,
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }
}

enum SessionRowPresentationBuilder {
    static func make(
        session: Session,
        pendingAskCount: Int = 0,
        pendingAsk: AskRequest? = nil,
        lineageHint: String? = nil,
        workspaceContext: String? = nil,
        unreadCompletionAt: Date? = nil,
        searchSnippet: AttributedString? = nil
    ) -> SessionRowPresentation {
        SessionRowPresentation(
            session: session,
            pendingAskCount: pendingAskCount,
            attentionText: attentionText(for: pendingAsk) ?? attentionText(forPendingAskCount: pendingAskCount),
            lineageHint: lineageHint,
            workspaceContext: normalizedWorkspaceContext(workspaceContext),
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

    static func normalizedWorkspaceContext(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func allSessionsWorkspaceContext(
        for session: Session,
        workspaceName: String? = nil
    ) -> String? {
        if session.control != nil {
            return "Pi Control"
        }
        return normalizedWorkspaceContext(session.workspaceName ?? workspaceName)
    }
}
