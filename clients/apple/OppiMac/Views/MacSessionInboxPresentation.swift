import Foundation

enum MacSessionInboxPresentation {
    static func sections(
        targets: [MacSelectedSessionTarget],
        now: Date,
        calendar: Calendar
    ) -> SessionInboxSections<MacSelectedSessionTarget> {
        SessionInboxGrouping.make(
            items: targets,
            now: now,
            calendar: calendar,
            session: { $0.summary.session },
            attention: { SessionListAttentionCounts(askCount: $0.summary.pendingAskCount) }
        )
    }

    static func rowPresentation(
        for target: MacSelectedSessionTarget,
        includeWorkspaceContext: Bool = true,
        searchSnippet: AttributedString? = nil
    ) -> SessionRowPresentation {
        rowPresentation(
            for: target.summary,
            includeWorkspaceContext: includeWorkspaceContext,
            searchSnippet: searchSnippet
        )
    }

    static func rowPresentation(
        for summary: SessionSummary,
        includeWorkspaceContext: Bool = true,
        searchSnippet: AttributedString? = nil
    ) -> SessionRowPresentation {
        let session = summary.session
        return SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: summary.pendingAskCount,
            workspaceContext: includeWorkspaceContext
                ? SessionRowPresentationBuilder.allSessionsWorkspaceContext(for: session)
                : nil,
            searchSnippet: searchSnippet
        )
    }
}

/// Home-list runtime caption. Runtime-only rows paint a compact status strip.
/// ``SessionShellDetail`` paints its own stats grid and does not use this caption.
enum MacHomeSessionListPaint {
    static func readableStatus(for session: StatsActiveSession) -> String {
        switch session.status {
        case "busy": "Running"
        case "starting": "Starting"
        case "ready": "Idle"
        case "stopped": "Stopped"
        case "error": "Error"
        default: session.status
        }
    }

    static func runtimeCaption(for session: StatsActiveSession) -> String {
        "\(session.displayTitle) · \(readableStatus(for: session))"
    }
}

/// Session-row chrome for the Mac inbox and workspace session lists.
///
/// Stop and Delete stay in the context menu. Abort a running turn from the
/// composer, like iOS — not from an inline list button.
struct MacSessionInboxRowChrome: Equatable, Sendable {
    var showsInlineStop: Bool
    var showsInlineDelete: Bool
    var showsContextMenuStop: Bool
    var showsContextMenuDelete: Bool

    static func make(status: SessionStatus) -> Self {
        MacSessionInboxRowChrome(
            showsInlineStop: false,
            showsInlineDelete: false,
            showsContextMenuStop: MacSessionActionPolicy.canStop(status),
            showsContextMenuDelete: MacSessionActionPolicy.canDelete(status)
        )
    }
}

/// Session titles are natural-language summaries, so preserve their beginning.
/// Paths and opaque identifiers use middle truncation in their own painters.
enum MacSessionInboxRowPaint: Sendable {
    enum Truncation: String, Sendable {
        case head
        case middle
        case tail
    }

    static var titleTruncation: Truncation { .tail }

    enum VisibleReason: Equatable, Sendable {
        case search(AttributedString)
        case lineage(String)
    }

    /// Search relevance or parentage is the reason this row is in front of
    /// the user, so it replaces ordinary context in the same compact band.
    static func visibleReason(
        for presentation: SessionRowPresentation
    ) -> VisibleReason? {
        if let searchSnippet = presentation.searchSnippet,
           normalized(String(searchSnippet.characters)) != nil {
            return .search(searchSnippet)
        }
        if let lineageHint = normalized(presentation.lineageHint) {
            return .lineage(lineageHint)
        }
        return nil
    }

    /// Keep the pointer and assistive-technology paths complete even though
    /// the 280pt visual row is intentionally limited to two scan bands.
    static func secondaryAccessibilityValue(
        for presentation: SessionRowPresentation
    ) -> String {
        let session = presentation.session
        var parts: [String] = []

        // A visible search or lineage reason consumes the row's only context
        // band, so carry the displaced workspace and primary model here.
        if visibleReason(for: presentation) != nil {
            if let workspaceContext = normalized(presentation.workspaceContext) {
                parts.append("Workspace \(workspaceContext)")
            }
            if let primaryModel = presentation.visibleModelSummaries.first {
                parts.append("Model \(primaryModel.label)")
            }
        }
        if let lineageHint = normalized(presentation.lineageHint) {
            parts.append(lineageHint)
        }
        if let searchSnippet = presentation.searchSnippet,
           let snippet = normalized(String(searchSnippet.characters)) {
            parts.append("Search match: \(snippet)")
        }
        if let contextPercent = presentation.contextPercent {
            parts.append("Context \(Int((contextPercent * 100).rounded()))%")
        }
        if let compactionCount = session.changeStats?.compactionCount,
           compactionCount > 0 {
            parts.append(SessionRowMetricsFormatting.compactionAccessibilityLabel(compactionCount))
        }
        if let worktree = SessionWorktreeIndicatorPresentation(session: session) {
            parts.append("Worktree \(worktree.worktreeId)")
        }
        if let attentionText = normalized(presentation.attentionText) {
            parts.append(attentionText)
        }
        if session.runtime == .piTui {
            let state = session.mirror?.status == "connected" ? "connected" : "offline"
            parts.append("pi-tui \(state)")
        }
        if session.ephemeral == true {
            parts.append("Incognito")
        }
        if session.cost > 0 {
            parts.append("Cost \(SessionFormatting.costString(session.cost))")
        }
        if let filesChanged = session.changeStats?.filesChanged,
           filesChanged > 0 {
            parts.append(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(filesChanged))
        }
        for model in presentation.visibleModelSummaries.dropFirst() {
            parts.append("Additional model \(model.label)")
        }

        return parts.joined(separator: ", ")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Overlay only when the shared presentation already carries an unread date.
    /// This does not invent unread tracking.
    static func showsUnreadDot(for presentation: SessionRowPresentation) -> Bool {
        presentation.unreadCompletionAt != nil
    }
}

/// Ordinary sessions use Pi's official identity. Saved Agents keep their
/// authored icon so the list still distinguishes explicitly branded launches.
enum MacSessionRowIdentityPaint: Equatable, Sendable {
    case officialPi
    case emoji(String)
    case symbol(String)

    static func make(session: Session) -> Self {
        if let agentId = session.launch?.agentId, !agentId.isEmpty {
            switch session.launch?.agentIcon {
            case .emoji(let value):
                return .emoji(value)
            case .symbol(let name):
                return .symbol(name)
            default:
                return .symbol("person.crop.circle")
            }
        }

        return .officialPi
    }
}
