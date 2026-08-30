import SwiftUI

/// Compact Mac inbox/workspace session row. Consumes shared
/// ``SessionRowPresentation`` and paints with SwiftUI identity/status.
///
/// ```
/// ◉ Title                                      [time]
/// workspace · model                          [status]
/// ```
struct WorkspaceSessionSummaryRow: View {
    @Environment(\.themeID) private var themeID

    let presentation: SessionRowPresentation

    private var session: Session { presentation.session }

    private var titleTruncationMode: Text.TruncationMode {
        switch MacSessionInboxRowPaint.titleTruncation {
        case .head: .head
        case .middle: .middle
        case .tail: .tail
        }
    }

    private var pillVariant: SessionRowStatusKind { presentation.statusKind }

    private var currentTurnStartedAt: Date? {
        switch session.status {
        case .starting, .busy, .stopping:
            return session.currentTurnStartedAt
        case .ready, .stopped, .error:
            return nil
        }
    }

    private var doneReferenceAt: Date {
        presentation.unreadCompletionAt ?? session.lastAgentReplyAt ?? session.lastActivity
    }

    private var secondaryMetadata: String {
        MacSessionInboxRowPaint.secondaryAccessibilityValue(for: presentation)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MacSessionRowIdentityIcon(session: session)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                titleBand
                contextBand
            }
        }
        .overlay(alignment: .topLeading) {
            if MacSessionInboxRowPaint.showsUnreadDot(for: presentation) {
                Circle()
                    .fill(.themeBlue)
                    .frame(width: 6, height: 6)
                    .padding(.top, 7)
                    .padding(.leading, 1)
                    .accessibilityHidden(true)
            }
        }
        .id(themeID)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(secondaryMetadata)
        .help(secondaryMetadata)
    }

    private var titleBand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.displayTitle)
                .font(.body)
                .foregroundStyle(.themeFg)
                .lineLimit(1)
                .truncationMode(titleTruncationMode)
                .layoutPriority(1)

            Spacer(minLength: 4)

            timeLabel
        }
    }

    private var contextBand: some View {
        HStack(spacing: 6) {
            if let visibleReason = MacSessionInboxRowPaint.visibleReason(for: presentation) {
                visibleReasonView(visibleReason)
                    .layoutPriority(2)
            } else {
                if let workspaceContext = presentation.workspaceContext, !workspaceContext.isEmpty {
                    workspaceContextView(workspaceContext)
                        .layoutPriority(1)
                }

                if let firstModel = presentation.visibleModelSummaries.first {
                    modelSummaryView(firstModel)
                        .layoutPriority(2)
                }
            }

            Spacer(minLength: 4)

            Text(pillVariant.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(statusForeground)
                .multilineTextAlignment(.trailing)
                .fixedSize()
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func visibleReasonView(_ reason: MacSessionInboxRowPaint.VisibleReason) -> some View {
        switch reason {
        case .search(let snippet):
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeBlue)
                    .accessibilityHidden(true)
                Text(highlightedSearchSnippet(snippet))
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .lineage(let lineage):
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themePurple)
                    .accessibilityHidden(true)
                Text(lineage)
                    .font(.caption2)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func highlightedSearchSnippet(_ snippet: AttributedString) -> AttributedString {
        var highlighted = snippet
        for run in highlighted.runs
            where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        {
            highlighted[run.range].foregroundColor = .themeYellow
        }
        return highlighted
    }

    private var statusForeground: Color {
        switch pillVariant {
        case .idle, .done: .themeGreen
        case .question, .working: .themeBlue
        case .stopped: .themeComment
        case .error: .themeRed
        }
    }

    @ViewBuilder
    private var timeLabel: some View {
        if let currentTurnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SessionFormatting.durationString(since: currentTurnStartedAt, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .monospacedDigit()
                    .fixedSize()
            }
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(doneReferenceAt.relativeString(relativeTo: context.date))
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .fixedSize()
            }
        }
    }

    private func workspaceContextView(_ workspaceContext: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.caption2.weight(.semibold))
            Text(workspaceContext)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.themeFgDim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workspace \(workspaceContext)")
    }

    private func modelSummaryView(_ model: SessionModelSummary) -> some View {
        HStack(spacing: 4) {
            if !model.provider.isEmpty {
                ProviderGlyph(provider: model.provider, size: 11, color: .themeFgDim)
            }

            Text(model.label)
                .font(.caption2)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model \(model.label)")
    }
}

/// SwiftUI session identity. Ordinary sessions use the official Pi mark;
/// saved-Agent sessions retain the icon authored for that Agent.
private struct MacSessionRowIdentityIcon: View {
    let session: Session

    var body: some View {
        let paint = MacSessionRowIdentityPaint.make(session: session)
        Group {
            switch paint {
            case .officialPi:
                MacAssistantAvatarView(
                    avatar: .officialPi,
                    sessionId: session.id,
                    size: 20
                )
            case .emoji(let value):
                Text(value)
                    .font(.system(size: 12))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.themeFg)
            }
        }
        .frame(width: 20, height: 20)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
