import SwiftUI

struct ContextInspectorView: View {
    let session: Session?
    let workspace: Workspace?
    let loadSessionStats: @MainActor () async throws -> SessionStatsSnapshot?

    @State private var loadedStats: SessionStatsSnapshot?
    @State private var statsLoading = false
    @State private var statsError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.themeID) private var themeID

    private struct SkillEstimate: Identifiable {
        let name: String
        let description: String
        let estimatedTokens: Int

        var id: String { name }
    }

    private struct CompositionSegment: Identifiable {
        let label: String
        let detail: String
        let tokens: Int
        let color: ThemeShapeStyle

        var id: String { label }
    }

    private struct UsageMetric {
        let title: String
        let value: String
        let detail: String
        let tint: ThemeShapeStyle
    }

    private var contextSnapshot: ContextUsageSnapshot {
        let fallbackWindow: Int?
        if let model = session?.model {
            fallbackWindow = inferContextWindow(from: model)
        } else {
            fallbackWindow = nil
        }

        return ContextUsageSnapshot(
            tokens: session?.contextTokens,
            window: session?.contextWindow ?? fallbackWindow
        )
    }

    private var sessionSkillEstimates: [SkillEstimate] {
        guard let loadedSkills = loadedStats?.loadedResources?.skills else { return [] }
        return loadedSkills.sorted { $0.name < $1.name }.map { skill in
            let description = skill.description ?? "No description available"
            return SkillEstimate(
                name: skill.name,
                description: description,
                estimatedTokens: estimateSkillPromptTokens(
                    name: skill.name,
                    description: description,
                    location: skill.path
                )
            )
        }
    }

    private var sessionExtensions: [SessionResourceSnapshot] {
        loadedStats?.loadedResources?.extensions.sorted { $0.name < $1.name } ?? []
    }

    private var skillDetailCwd: String? {
        workspace?.hostMount
    }

    /// Breaks the total context into up to 4 colored segments:
    /// Pi base prompt, AGENTS files, skills index, and messages/runtime.
    private var compositionSegments: [CompositionSegment] {
        guard let total = contextSnapshot.tokens, total > 0 else { return [] }
        guard let composition = loadedStats?.contextComposition else { return [] }
        return SessionContextCompositionProjection.segments(
            totalContextTokens: total,
            composition: composition
        ).map { segment in
            CompositionSegment(
                label: segment.label,
                detail: segment.detail,
                tokens: segment.tokens,
                color: compositionColor(for: segment.kind)
            )
        }
    }

    private var sessionUsageStats: SessionStatsSnapshot? {
        if let loadedStats { return loadedStats }
        guard let session else { return nil }
        return SessionStatsSnapshot.fallback(from: session)
    }

    private var contextUsedTokens: Int {
        max(contextSnapshot.tokens ?? 0, 0)
    }

    private var contextWindowTokens: Int {
        max(contextSnapshot.window ?? 0, 0)
    }

    private var contextRemainingTokens: Int {
        max(contextWindowTokens - contextUsedTokens, 0)
    }

    var body: some View {
        List {
            Section {
                usageHeaderCard
            }

            Section("Session Usage") {
                if let stats = sessionUsageStats {
                    sessionUsageOverview(stats)

                    if let cacheWaste = stats.cacheWaste, cacheWaste.missedTokens > 0 {
                        cacheWasteRow(cacheWaste)
                    }

                    if stats.modelBreakdown.count > 1 {
                        modelUsageBreakdown(stats.modelBreakdown)
                    }

                    if let statsError, !statsError.isEmpty {
                        Text("Detailed usage unavailable: \(statsError)")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                } else if statsLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading session usage…")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                } else {
                    Text("Session usage is not available yet.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                }
            }

            Section("Context Breakdown") {
                if compositionSegments.isEmpty {
                    if statsLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading breakdown…")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                    } else if let statsError, !statsError.isEmpty {
                        Text("Detailed breakdown unavailable: \(statsError)")
                            .font(.caption)
                            .foregroundStyle(.themeOrange)
                    } else {
                        Text("Breakdown appears after stats load.")
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                    }
                } else {
                    compositionBar

                    ForEach(compositionSegments) { segment in
                        compositionLegendRow(segment)
                    }
                }
            }

            Section("Loaded Skills") {
                if sessionSkillEstimates.isEmpty {
                    Text("No skills loaded for this session.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(sessionSkillEstimates) { skill in
                        NavigationLink(value: SkillDetailDestination(skillName: skill.name, cwd: skillDetailCwd)) {
                            skillEstimateRow(skill)
                        }
                    }

                    Text("Tap a skill to read SKILL.md and files.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Section("Loaded Extensions") {
                if sessionExtensions.isEmpty {
                    Text("No extensions loaded for this session.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(sessionExtensions) { ext in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ext.name)
                                .font(.body)
                                .foregroundStyle(.themeFg)
                            Text(ext.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.themeComment)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(.themeBg)
        .tint(.themeBlue)
        .id(themeID)
        .task(id: session?.id) {
            await refreshSessionStats()
        }
        .navigationDestination(for: SkillDetailDestination.self) { dest in
            SkillDetailView(skillName: dest.skillName, cwd: dest.cwd)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath, cwd: dest.cwd)
        }
    }

    // MARK: - Header

    private var usageHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(contextSnapshot.usageText)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)

            if let progress = contextSnapshot.progress {
                Text("\(contextSnapshot.percentText) used")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(progressTint(progress))
            } else {
                Text("Context usage can be temporarily unknown right after compaction.")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Composition Bar

    /// Multi-segment bar where each segment's width is proportional to its
    /// share of the total context window.
    @ViewBuilder
    private var compositionBar: some View {
        if contextWindowTokens > 0, !compositionSegments.isEmpty {
            GeometryReader { proxy in
                let totalWidth = max(proxy.size.width, 0)
                let window = Double(contextWindowTokens)

                HStack(spacing: 1.5) {
                    ForEach(compositionSegments) { segment in
                        let fraction = CGFloat(Double(segment.tokens) / window)
                        let segmentWidth = max(totalWidth * fraction, 0)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(segment.color)
                            .frame(width: segmentWidth)
                    }

                    // Remaining (unused) portion
                    let usedFraction = compositionSegments.reduce(0.0) { $0 + Double($1.tokens) }
                        / window
                    let remainingFraction = max(1.0 - usedFraction, 0)
                    let remainingWidth = totalWidth * CGFloat(remainingFraction)

                    if remainingWidth > 1 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.themeComment.opacity(0.2))
                            .frame(width: remainingWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 14)
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                Text("Used: \(SessionFormatting.tokenCount(contextUsedTokens))")
                    .font(.caption)
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)

                Text("Remaining: \(SessionFormatting.tokenCount(contextRemainingTokens))")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        }
    }

    // MARK: - Legend

    private func compositionLegendRow(_ segment: CompositionSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(segment.color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(segment.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Text(segment.detail)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }

            Spacer(minLength: 8)

            Text(SessionFormatting.tokenCount(segment.tokens))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Session Usage

    private func sessionUsageOverview(_ stats: SessionStatsSnapshot) -> some View {
        let tokens = stats.tokens
        let cachedFraction = tokens.promptInput > 0
            ? CGFloat(Double(tokens.cacheRead) / Double(tokens.promptInput))
            : 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Prompt input")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)

                Text(SessionFormatting.tokenCount(tokens.promptInput))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.themeFg)
            }

            if tokens.promptInput > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.themeOrange.opacity(0.55))

                        if cachedFraction > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.themeGreen)
                                .frame(width: proxy.size.width * cachedFraction)
                        }
                    }
                }
                .frame(height: 10)
                .accessibilityHidden(true)
            }

            usageMetricPair(
                first: UsageMetric(
                    title: "Cached",
                    value: SessionFormatting.tokenCount(tokens.cacheRead),
                    detail: tokens.cacheHitRate.map { String(format: "%.1f%% hit", $0 * 100) } ?? "No cache reads",
                    tint: .themeGreen
                ),
                second: UsageMetric(
                    title: "Uncached",
                    value: SessionFormatting.tokenCount(tokens.uncachedInput),
                    detail: tokens.cacheWrite > 0
                        ? "\(SessionFormatting.tokenCount(tokens.cacheWrite)) written"
                        : "Not served from cache",
                    tint: .themeOrange
                )
            )

            Divider()

            usageMetricPair(
                first: UsageMetric(
                    title: "Output",
                    value: SessionFormatting.tokenCount(tokens.output),
                    detail: "Generated tokens",
                    tint: .themeBlue
                ),
                second: UsageMetric(
                    title: "Total cost",
                    value: SessionFormatting.costString(stats.cost),
                    detail: "Entire session",
                    tint: .themePurple
                )
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func usageMetricPair(
        first: UsageMetric,
        second: UsageMetric
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                usageMetric(title: first.title, value: first.value, detail: first.detail, tint: first.tint)
                usageMetric(title: second.title, value: second.value, detail: second.detail, tint: second.tint)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                usageMetric(title: first.title, value: first.value, detail: first.detail, tint: first.tint)
                usageMetric(title: second.title, value: second.value, detail: second.detail, tint: second.tint)
            }
        }
    }

    private func usageMetric(title: String, value: String, detail: String, tint: ThemeShapeStyle) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func cacheWasteRow(_ waste: SessionCacheWasteSnapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(.themeOrange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Cache re-billed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Text(cacheWasteDetail(waste))
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func cacheWasteDetail(_ waste: SessionCacheWasteSnapshot) -> String {
        let misses = waste.missCount == 1 ? "1 miss" : "\(waste.missCount) misses"
        let cost = waste.missedCost >= 0.0005
            ? ", about \(SessionFormatting.costString(waste.missedCost)) extra"
            : ""
        return "\(SessionFormatting.tokenCount(waste.missedTokens)) tokens across \(misses)\(cost)."
    }

    private func modelUsageBreakdown(_ models: [SessionModelUsageSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost by model")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)

            ForEach(models) { model in
                modelUsageRow(model)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func modelUsageRow(_ model: SessionModelUsageSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                modelUsageIdentity(model)
                Text(SessionFormatting.costString(model.cost))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.themeFg)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                modelUsageIdentity(model)
                Spacer(minLength: 8)
                Text(SessionFormatting.costString(model.cost))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.themeFg)
            }
        }
    }

    private func modelUsageIdentity(_ model: SessionModelUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.model)
                .font(.caption.weight(.medium))
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
            Text(modelUsageDetail(model))
                .font(.caption2)
                .foregroundStyle(.themeComment)
        }
    }

    private func modelUsageDetail(_ model: SessionModelUsageSnapshot) -> String {
        let tokens = "\(SessionFormatting.tokenCount(model.tokens)) tokens"
        guard let provider = model.provider, !provider.isEmpty else { return tokens }
        return "\(provider) · \(tokens)"
    }

    // MARK: - Skills

    private func skillEstimateRow(_ skill: SkillEstimate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)

                Text("~\(SessionFormatting.tokenCount(skill.estimatedTokens))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.themeComment)
            }

            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private func refreshSessionStats() async {
        statsLoading = true
        statsError = nil

        do {
            loadedStats = try await loadSessionStats()
        } catch {
            loadedStats = nil
            statsError = error.localizedDescription
        }

        statsLoading = false
    }

    private func compositionColor(for kind: SessionContextCompositionKind) -> ThemeShapeStyle {
        switch kind {
        case .piBasePrompt: .themePurple
        case .agentsFiles: .themeCyan
        case .skillsIndex: .themeYellow
        case .messagesAndRuntime: .themeGreen
        }
    }

    private func progressTint(_ progress: Double) -> Color {
        if progress > 0.9 { return .themeRed }
        if progress > 0.7 { return .themeOrange }
        return .themeGreen
    }

    private func estimateSkillPromptTokens(name: String, description: String, location: String?) -> Int {
        let snippet = """
          <skill>
            <name>\(name)</name>
            <description>\(description)</description>
            <location>\(location ?? "")</location>
          </skill>
        """

        return max(1, Int(ceil(Double(snippet.count) / 4.0)))
    }
}
