import SwiftUI

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
                    provider: providerFromModel(normalized) ?? "",
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

// MARK: - Session Row

/// Unified session row used in both active and stopped sections.
///
/// Three-line layout:
/// ```
/// ◉ Title                                      [time]
/// model summary [compactions] [worktree] question prompt
/// ▬ 25% · $27.45 · [doc] 4  [status pill]
/// ```
///
/// Attention text is passed in by the caller to keep this view testable and
/// avoid environment collisions with parallel work.
struct SessionRow: View {
    @Environment(\.themeID) private var themeID

    let session: Session
    let pendingAskCount: Int
    let attentionText: String?
    let lineageHint: String?
    let workspaceContext: String?
    let modelSummaries: [SessionModelSummary]
    let unreadCompletionAt: Date?
    let searchSnippet: AttributedString?

    init(
        session: Session,
        pendingAskCount: Int = 0,
        attentionText: String? = nil,
        lineageHint: String? = nil,
        workspaceContext: String? = nil,
        modelSummaries: [SessionModelSummary] = [],
        unreadCompletionAt: Date? = nil,
        searchSnippet: AttributedString? = nil
    ) {
        self.session = session
        self.pendingAskCount = pendingAskCount
        self.attentionText = attentionText
        self.lineageHint = lineageHint
        self.workspaceContext = workspaceContext
        self.modelSummaries = modelSummaries
        self.unreadCompletionAt = unreadCompletionAt
        self.searchSnippet = searchSnippet
    }

    private var title: String {
        session.displayTitle
    }

    private var contextPercent: Double? {
        guard let used = session.contextTokens,
              let window = session.contextWindow ?? inferContextWindow(from: session.model ?? ""),
              window > 0 else { return nil }
        return min(max(Double(used) / Double(window), 0), 1)
    }

    private var pillVariant: SessionPillVariant {
        .from(session: session, pendingAskCount: pendingAskCount)
    }

    private var visibleModelSummaries: [SessionModelSummary] {
        if !modelSummaries.isEmpty {
            return modelSummaries
        }
        return SessionModelSummaryBuilder.summaries(primaryModel: session.model)
    }

    private var displayCompactionCount: Int {
        session.changeStats?.compactionCount ?? 0
    }

    private var displayFilesChanged: Int {
        session.changeStats?.filesChanged ?? 0
    }

    private var isIncognito: Bool {
        session.ephemeral == true
    }

    private var worktreeIndicator: SessionWorktreeIndicatorPresentation? {
        SessionWorktreeIndicatorPresentation(session: session)
    }

    private var terminalMirrorIndicator: TerminalMirrorIndicatorPresentation? {
        TerminalMirrorIndicatorPresentation(session: session)
    }

    private var currentTurnStartedAt: Date? {
        switch session.status {
        case .starting, .busy, .stopping:
            return session.currentTurnStartedAt
        case .ready, .stopped, .error:
            return nil
        }
    }

    private var doneReferenceAt: Date {
        unreadCompletionAt ?? session.lastAgentReplyAt ?? session.lastActivity
    }

    private var isUnread: Bool {
        unreadCompletionAt != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            identityIcon
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                // Row 1: title + time
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityLabel(isUnread ? Text("Unread, \(title)") : Text(verbatim: title))

                Spacer(minLength: 4)

                timeLabel
            }

            // Row 1.5: lineage hint (stopped sessions only)
            if let lineageHint, !lineageHint.isEmpty {
                Text(lineageHint)
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(1)
            }

            // Row 1.75: search snippet (when searching)
            if let searchSnippet {
                Text(searchSnippet)
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
                    .lineLimit(2)
            }

            // Row 2: workspace + model + optional ask prompt
            HStack(spacing: 6) {
                if let workspaceContext, !workspaceContext.isEmpty {
                    workspaceContextView(workspaceContext)
                }

                if let firstModel = visibleModelSummaries.first {
                    modelSummaryView(firstModel)
                        .layoutPriority(1)
                }

                if displayCompactionCount > 0 {
                    compactionBadgeView(displayCompactionCount)
                }

                if let worktreeIndicator {
                    worktreeIndicatorView(worktreeIndicator)
                }

                if let attentionText, !attentionText.isEmpty {
                    Text(attentionText)
                        .font(.caption2)
                        .foregroundStyle(.themeFgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("session.attentionPreview.\(session.id)")
                }

                Spacer(minLength: 8)

                if let terminalMirrorIndicator {
                    TerminalMirrorIndicatorView(presentation: terminalMirrorIndicator)
                }
            }

            // Row 3: compact metrics on the left, status pinned right.
            HStack(spacing: 6) {
                if let pct = contextPercent {
                    NativeContextGauge(percent: pct)
                }

                if isIncognito {
                    incognitoBadge
                }

                if session.cost > 0 {
                    Text(costString(session.cost))
                        .monospacedDigit()
                }

                if displayFilesChanged > 0 {
                    fileCountView(displayFilesChanged)
                }

                Spacer(minLength: 8)

                if pendingAskCount > 0 {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(pillVariant.foregroundColor)
                        .accessibilityIdentifier("session.attentionBadge.\(session.id)")
                }

                SessionStatusPill(pillVariant)
                    .fixedSize()
            }
                .font(.caption)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .topLeading) {
            if isUnread {
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
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var identityIcon: some View {
        SessionIdentityIconView(
            sessionId: session.id,
            agentId: session.launch?.agentId,
            agentIcon: session.launch?.agentIcon
        )
        .frame(width: 20, height: 20)
        .frame(width: 24, height: 24)
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

    // MARK: - Privacy Badge

    private var incognitoBadge: some View {
        Label("Incognito", systemImage: "eye.slash.fill")
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.themePurple)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.themePurple.opacity(0.14), in: Capsule())
            .accessibilityLabel("Incognito session")
    }

    // MARK: - Workspace Context

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

    // MARK: - Model Summary

    @ViewBuilder
    private func modelSummaryView(_ model: SessionModelSummary) -> some View {
        HStack(spacing: 4) {
            if !model.provider.isEmpty {
                ProviderIcon(provider: model.provider, size: 11)
            }

            Text(model.label)
                .font(.caption2)
                .foregroundStyle(.themeFgDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Helpers

    private func costString(_ cost: Double) -> String {
        SessionFormatting.costString(cost)
    }

    @ViewBuilder
    private func fileCountView(_ filesChanged: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "doc")
                .font(.caption2.weight(.semibold))
            Text("\(filesChanged)")
                .monospacedDigit()
        }
        .foregroundStyle(changeSummaryColor(filesChanged: filesChanged))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionRowMetricsFormatting.filesTouchedAccessibilityLabel(filesChanged))
    }

    @ViewBuilder
    private func compactionBadgeView(_ compactionCount: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.semibold))
            Text("\(compactionCount)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.themeComment)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SessionRowMetricsFormatting.compactionAccessibilityLabel(compactionCount))
    }

    @ViewBuilder
    private func worktreeIndicatorView(_ presentation: SessionWorktreeIndicatorPresentation) -> some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.themePurple)
            .frame(width: 16, height: 16)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.worktreeId)
    }

    private func changeSummaryColor(filesChanged: Int) -> Color {
        if filesChanged >= 25 {
            return .themeRed
        }
        if filesChanged >= 10 {
            return .themeOrange
        }
        return .themeGreen
    }
}

struct SessionIdentityIconView: UIViewRepresentable {
    let sessionId: String
    var agentId: String?
    var agentIcon: String?

    func makeUIView(context: Context) -> SessionGridBadgeView {
        let view = SessionGridBadgeView()
        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        return view
    }

    func updateUIView(_ view: SessionGridBadgeView, context: Context) {
        view.sessionId = sessionId
        view.agentId = agentId
        view.agentIcon = agentIcon

        switch AssistantIdentityPresentation.resolve(agentId: agentId, agentIcon: agentIcon) {
        case .globalAvatar:
            view.accessibilityLabel = "Pi"
        case .agent(let content):
            view.accessibilityLabel = "Saved Agent, \(content.accessibilityDescription)"
        }
    }
}

// MARK: - Row Metrics Formatting

enum SessionRowMetricsFormatting {
    static func filesTouchedAccessibilityLabel(_ filesChanged: Int) -> String {
        filesChanged == 1 ? String(localized: "1 file touched") : String(localized: "\(filesChanged) files touched")
    }

    static func compactionAccessibilityLabel(_ compactionCount: Int) -> String {
        compactionCount == 1 ? "1 compaction" : "\(compactionCount) compactions"
    }
}

// MARK: - Context Gauge

/// Compact context usage indicator using app theme colors.
struct NativeContextGauge: View {
    let percent: Double

    private var clamped: Double { min(max(percent, 0), 1) }

    private var tint: Color {
        if clamped > 0.9 { return .themeRed }
        if clamped > 0.7 { return .themeOrange }
        return .themeGreen
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.themeBgHighlight)
                Capsule()
                    .fill(tint)
                    .frame(width: 24 * clamped)
            }
            .frame(width: 24, height: 4)

            Text("\(Int((clamped * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.themeComment)
        }
    }
}
