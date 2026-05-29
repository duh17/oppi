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

// MARK: - Session Row

/// Unified session row used in both active and stopped sections.
///
/// Three-line layout:
/// ```
/// Title (bold if needs attention)                [time]
/// model summary activity
/// ▬ 25% · $27.45 · [doc] 4  [status pill] [child badge if any]
/// ```
///
/// Activity summary is passed in by the caller (computed from
/// SessionActivityStore + PermissionStore) to keep this view
/// testable and avoid environment collisions with parallel work.
struct SessionRow: View {
    let session: Session
    let pendingCount: Int
    let pendingAskCount: Int
    let activitySummary: String?
    let lineageHint: String?
    let children: ChildSummary?
    let modelSummaries: [SessionModelSummary]
    let searchSnippet: AttributedString?

    /// Summary of spawned child sessions, shown as a badge on parent rows.
    struct ChildSummary {
        let childCount: Int
        let statusCounts: SessionTreeHelper.StatusCounts
        let aggregateCost: Double
        let aggregateCompactionCount: Int
        let aggregateFilesChanged: Int
    }

    init(
        session: Session,
        pendingCount: Int,
        pendingAskCount: Int = 0,
        activitySummary: String? = nil,
        lineageHint: String? = nil,
        children: ChildSummary? = nil,
        modelSummaries: [SessionModelSummary] = [],
        searchSnippet: AttributedString? = nil
    ) {
        self.session = session
        self.pendingCount = pendingCount
        self.pendingAskCount = pendingAskCount
        self.activitySummary = activitySummary
        self.lineageHint = lineageHint
        self.children = children
        self.modelSummaries = modelSummaries
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
        .from(session: session, pendingCount: pendingCount, pendingAskCount: pendingAskCount)
    }

    private var visibleModelSummaries: [SessionModelSummary] {
        if !modelSummaries.isEmpty {
            return modelSummaries
        }
        return SessionModelSummaryBuilder.summaries(primaryModel: session.model)
    }

    private var displayCompactionCount: Int {
        children?.aggregateCompactionCount ?? session.changeStats?.compactionCount ?? 0
    }

    private var displayFilesChanged: Int {
        children?.aggregateFilesChanged ?? session.changeStats?.filesChanged ?? 0
    }

    private var isIncognito: Bool {
        session.ephemeral == true
    }

    private var terminalMirrorIndicator: (accessibilityLabel: String, color: Color, isAnimated: Bool)? {
        guard session.runtime == .piTuiMirror else { return nil }
        if session.mirror?.status == "connected" {
            return ("Terminal mirror live", .themeGreen, true)
        }
        return ("Terminal mirror offline", .themeComment, false)
    }

    private var currentTurnStartedAt: Date? {
        switch session.status {
        case .starting, .busy, .stopping:
            return session.currentTurnStartedAt
        case .ready, .stopped, .error:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: title + time
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.body)
                    .fontWeight((pendingCount > 0 || pendingAskCount > 0) ? .semibold : .regular)
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .layoutPriority(1)

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

            // Row 2: model + child badge + activity summary
            HStack(spacing: 6) {
                if let firstModel = visibleModelSummaries.first {
                    modelSummaryView(firstModel)
                        .layoutPriority(1)
                }

                if displayCompactionCount > 0 {
                    compactionBadgeView(displayCompactionCount)
                }

                if let children {
                    childBadge(children: children)
                }

                if let activitySummary, !activitySummary.isEmpty {
                    Text(activitySummary)
                        .font(.caption2)
                        .foregroundStyle(.themeFgDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if let terminalMirrorIndicator {
                    TerminalMirrorIndicatorView(
                        accessibilityLabel: terminalMirrorIndicator.accessibilityLabel,
                        color: terminalMirrorIndicator.color,
                        isAnimated: terminalMirrorIndicator.isAnimated
                    )
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

                let displayCost = children?.aggregateCost ?? session.cost
                if displayCost > 0 {
                    Text(costString(displayCost))
                        .monospacedDigit()
                }

                if displayFilesChanged > 0 {
                    fileCountView(displayFilesChanged)
                }

                Spacer(minLength: 8)

                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.themeBg)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pillVariant.foregroundColor, in: Capsule())
                } else if pendingAskCount > 0 {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(pillVariant.foregroundColor)
                }

                SessionStatusPill(pillVariant)
                    .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.themeFgDim)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var timeLabel: some View {
        if let currentTurnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(SessionFormatting.durationString(since: currentTurnStartedAt))
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .monospacedDigit()
                    .fixedSize()
            }
        } else {
            Text(session.lastActivity.relativeString())
                .font(.caption2)
                .foregroundStyle(.themeComment)
                .fixedSize()
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

    private struct TerminalMirrorIndicatorView: View {
        let accessibilityLabel: String
        let color: Color
        let isAnimated: Bool

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var breathing = false

        private var shouldAnimate: Bool {
            isAnimated && !reduceMotion
        }

        var body: some View {
            Image(systemName: "terminal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .opacity(shouldAnimate && breathing ? 1 : 0.82)
                .frame(width: 18, height: 16, alignment: .trailing)
                .accessibilityLabel(accessibilityLabel)
                .onAppear(perform: updateBreathing)
                .onChange(of: shouldAnimate) { _, _ in
                    updateBreathing()
                }
        }

        private func updateBreathing() {
            guard shouldAnimate else {
                breathing = false
                return
            }
            breathing = false
            withAnimation(ThemeMotion.animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), reduceMotion: reduceMotion)) {
                breathing = true
            }
        }
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

    // MARK: - Child Badge

    @ViewBuilder
    private func childBadge(children: ChildSummary) -> some View {
        HStack(spacing: 3) {
            let counts = children.statusCounts
            if counts.working > 0 {
                Text("\u{1F527}\(counts.working)")
                    .foregroundStyle(.themeOrange)
            }
            let done = counts.ready + counts.stopped
            if done > 0 {
                Text("\u{2713}\(done)")
                    .foregroundStyle(.themeGreen)
            }
            if counts.error > 0 {
                Text("\u{2717}\(counts.error)")
                    .foregroundStyle(.themeRed)
            }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Color.themeCyan.opacity(0.1), in: Capsule())
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

// MARK: - Row Metrics Formatting

enum SessionRowMetricsFormatting {
    static func filesTouchedAccessibilityLabel(_ filesChanged: Int) -> String {
        filesChanged == 1 ? String(localized: "1 file touched") : String(localized: "\(filesChanged) files touched")
    }

    static func compactionAccessibilityLabel(_ compactionCount: Int) -> String {
        compactionCount == 1 ? "1 compaction" : "\(compactionCount) compactions"
    }
}

// MARK: - Activity Summary

/// Generate activity summary text from session state and activity data.
///
/// Called by `SessionRowPresentationBuilder` before passing inputs to
/// `SessionRow`. Keeps SessionRow pure and testable.
enum SessionActivitySummary {
    static func text(
        session: Session,
        pendingCount: Int,
        pendingPermissions: [PermissionRequest],
        pendingAsk: AskRequest? = nil,
        activity: SessionActivityStore.Activity?
    ) -> String? {
        // Pending permissions take priority
        if pendingCount > 0, let first = pendingPermissions.first {
            return permissionDescription(first)
        }

        // Pending ask questions (after permissions)
        if let ask = pendingAsk, let first = ask.questions.first {
            return askDescription(first)
        }

        if session.isAwaitingFirstPrompt {
            return nil
        }

        // Working: show current tool
        if session.status == .busy || session.status == .starting || session.status == .stopping {
            if let activity {
                return formatToolActivity(activity)
            }
            return nil
        }

        // Ready: keep row quiet unless something more specific is happening.
        if session.status == .ready {
            return nil
        }

        // Stopped: keep activity text quiet. Change metrics are rendered once
        // in SessionRow's compact metrics line so home previews and workspace
        // detail rows do not duplicate "files changed" text.
        if session.status == .stopped {
            return nil
        }

        // Error
        if session.status == .error {
            return "agent error"
        }

        return nil
    }

    private static func askDescription(_ question: AskQuestion) -> String {
        let text = question.question
        let truncated = text.count > 40 ? String(text.prefix(40)) + "..." : text
        return "question: \(truncated)"
    }

    private static func permissionDescription(_ perm: PermissionRequest) -> String {
        let tool = perm.tool.lowercased()
        if let path = perm.input["path"]?.stringValue {
            return "permission: \(tool) \(shortenPath(path))"
        }
        if let cmd = perm.input["command"]?.stringValue {
            let truncated = cmd.count > 30 ? String(cmd.prefix(30)) + "..." : cmd
            return "permission: \(truncated)"
        }
        return "permission: \(perm.tool)"
    }

    static func formatToolActivity(_ activity: SessionActivityStore.Activity) -> String {
        let verb = toolVerb(activity.toolName)
        if let arg = activity.keyArg {
            return "\(verb) \(shortenPath(arg))"
        }
        return verb
    }

    private static func toolVerb(_ tool: String) -> String {
        switch tool.lowercased() {
        case "read": return "reading"
        case "write": return "writing"
        case "edit": return "editing"
        case "bash", "execute": return "running"
        case "search", "grep": return "searching"
        case "glob", "find": return "finding"
        default: return tool.lowercased()
        }
    }

    private static func shortenPath(_ path: String) -> String {
        // Show last two path components for readability
        let components = path.split(separator: "/")
        if components.count <= 2 {
            return path
        }
        return components.suffix(2).joined(separator: "/")
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
