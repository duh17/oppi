import SwiftUI

struct ContextInspectorView: View {
    let session: Session?
    let workspace: Workspace?
    let workspaceSkillNames: [String]
    let availableSkills: [SkillInfo]
    let loadSessionStats: @MainActor () async throws -> SessionStatsSnapshot?

    @State private var loadedStats: SessionStatsSnapshot?
    @State private var statsLoading = false
    @State private var statsError: String?

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
        let color: Color

        var id: String { label }
    }

    private struct TokenBreakdownSegment: Identifiable {
        let label: String
        let tokens: Int
        let color: Color

        var id: String { label }
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

    private var sessionTokenStats: SessionTokenStats {
        if let loadedStats {
            return loadedStats.tokens
        }

        let input = session?.tokens.input ?? 0
        let output = session?.tokens.output ?? 0
        return SessionTokenStats(
            input: input,
            output: output,
            cacheRead: 0,
            cacheWrite: 0,
            total: input + output
        )
    }

    private var workspaceSkillEstimates: [SkillEstimate] {
        let byName = Dictionary(uniqueKeysWithValues: availableSkills.map { ($0.name, $0) })

        return workspaceSkillNames.sorted().map { skillName in
            let skill = byName[skillName]
            let description = skill?.description ?? "No description available"
            let location = skill?.path
            return SkillEstimate(
                name: skillName,
                description: description,
                estimatedTokens: estimateSkillPromptTokens(
                    name: skillName,
                    description: description,
                    location: location
                )
            )
        }
    }

    private var availableButDisabledSkills: [SkillInfo] {
        let enabled = Set(workspaceSkillNames)
        return availableSkills
            .filter { !enabled.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var estimatedSkillMetadataTotal: Int {
        workspaceSkillEstimates.reduce(0) { $0 + $1.estimatedTokens }
    }

    private var configuredSystemPromptEstimate: Int {
        guard let prompt = workspace?.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            return 0
        }
        return max(1, Int(ceil(Double(prompt.count) / 4.0)))
    }

    private var compositionSegments: [CompositionSegment] {
        guard let total = contextSnapshot.tokens, total > 0 else { return [] }

        let skills = min(estimatedSkillMetadataTotal, total)

        let knownSystemPrompt = min(configuredSystemPromptEstimate, max(total - skills, 0))
        let remaining = max(total - skills - knownSystemPrompt, 0)

        // Heuristic split of unknown remainder: message-heavy as sessions grow.
        let messageWeight = min(max(Double(session?.messageCount ?? 0) / 24.0, 0.25), 0.85)
        let messages = min(remaining, Int((Double(remaining) * messageWeight).rounded()))
        let systemAndAgents = max(total - skills - messages, 0)

        return [
            CompositionSegment(
                label: "System + AGENTS",
                detail: "Includes configured system prompt and agent instruction files.",
                tokens: systemAndAgents,
                color: .themePurple
            ),
            CompositionSegment(
                label: "Skills metadata",
                detail: "Workspace skill metadata available to the assistant.",
                tokens: skills,
                color: .themeBlue
            ),
            CompositionSegment(
                label: "Messages + runtime",
                detail: "Conversation content and dynamic runtime context.",
                tokens: messages,
                color: .themeGreen
            ),
        ]
    }

    private var sessionBreakdownSegments: [TokenBreakdownSegment] {
        [
            TokenBreakdownSegment(label: "Input", tokens: sessionTokenStats.input, color: .themeBlue),
            TokenBreakdownSegment(label: "Output", tokens: sessionTokenStats.output, color: .themePurple),
            TokenBreakdownSegment(label: "Cache read", tokens: sessionTokenStats.cacheRead, color: .themeGreen),
            TokenBreakdownSegment(label: "Cache write", tokens: sessionTokenStats.cacheWrite, color: .themeOrange),
        ]
        .filter { $0.tokens > 0 }
    }

    private var sessionBreakdownTotal: Int {
        let explicitTotal = sessionTokenStats.total
        let computedTotal = sessionBreakdownSegments.reduce(0) { $0 + $1.tokens }
        return max(explicitTotal, computedTotal)
    }

    var body: some View {
        List {
            Section {
                usageHeaderCard
            }

            Section("Context Composition") {
                if compositionSegments.isEmpty {
                    Text("Composition appears after context usage is available.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(compositionSegments) { segment in
                        compositionLegendRow(segment)
                    }

                    Text("Composition values are best-effort estimates from available data.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            Section("Session Activity") {
                if !sessionBreakdownSegments.isEmpty {
                    sessionBreakdownBar

                    ForEach(sessionBreakdownSegments) { segment in
                        sessionBreakdownLegendRow(segment)
                    }
                }

                metricChipRow(
                    MetricChip(title: "Input", value: formatTokenCount(sessionTokenStats.input)),
                    MetricChip(title: "Output", value: formatTokenCount(sessionTokenStats.output))
                )

                if loadedStats != nil {
                    metricChipRow(
                        MetricChip(title: "Cache read", value: formatTokenCount(sessionTokenStats.cacheRead)),
                        MetricChip(title: "Cache write", value: formatTokenCount(sessionTokenStats.cacheWrite))
                    )
                }

                metricChipRow(
                    MetricChip(title: "Total", value: formatTokenCount(sessionTokenStats.total)),
                    MetricChip(title: "Cost", value: String(format: "$%.2f", session?.cost ?? loadedStats?.cost ?? 0))
                )

                if loadedStats != nil {
                    Text("Total includes input, output, cache read, and cache write.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }

                Text("Cost uses cumulative session cost (matches session list/title).")
                    .font(.caption)
                    .foregroundStyle(.themeComment)

                if statsLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading detailed token stats…")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }

                if let statsError, !statsError.isEmpty {
                    Text(statsError)
                        .font(.caption)
                        .foregroundStyle(.themeOrange)
                }
            }

            Section("Skills in Workspace") {
                if workspaceSkillEstimates.isEmpty {
                    Text("No workspace skills configured.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(workspaceSkillEstimates) { skill in
                        NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                            skillEstimateRow(skill)
                        }
                    }

                    Text("Tap a skill to read SKILL.md and files.")
                        .font(.caption)
                        .foregroundStyle(.themeComment)
                }
            }

            if !availableButDisabledSkills.isEmpty {
                Section("Other Available Skills") {
                    ForEach(availableButDisabledSkills) { skill in
                        NavigationLink(value: SkillDetailDestination(skillName: skill.name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(skill.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.themeFg)

                                    Spacer(minLength: 8)

                                    Text("not enabled")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.themeComment)
                                }

                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.themeComment)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.themeBg)
        .tint(.themeBlue)
        .task(id: session?.id) {
            await refreshSessionStats()
        }
        .navigationDestination(for: SkillDetailDestination.self) { dest in
            SkillDetailView(skillName: dest.skillName)
        }
        .navigationDestination(for: SkillFileDestination.self) { dest in
            SkillFileView(skillName: dest.skillName, filePath: dest.filePath)
        }
    }

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

            Text(formatTokenCount(segment.tokens))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var sessionBreakdownBar: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let gap: CGFloat = 4
            let gaps = gap * CGFloat(max(sessionBreakdownSegments.count - 1, 0))
            let contentWidth = max(totalWidth - gaps, 0)

            HStack(spacing: gap) {
                ForEach(sessionBreakdownSegments) { segment in
                    let ratio = sessionBreakdownTotal > 0 ? Double(segment.tokens) / Double(sessionBreakdownTotal) : 0
                    let width = max(12, contentWidth * ratio)

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(segment.color)
                        .frame(width: width)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 14)
        .padding(.vertical, 2)
    }

    private func sessionBreakdownLegendRow(_ segment: TokenBreakdownSegment) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(segment.color)
                .frame(width: 8, height: 8)

            Text(segment.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)

            Spacer(minLength: 8)

            Text("\(String(format: "%.1f%%", segmentPercentage(segment.tokens, of: sessionBreakdownTotal) * 100))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.themeComment)

            Text(formatTokenCount(segment.tokens))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
        }
        .padding(.vertical, 1)
    }

    private func segmentPercentage(_ tokens: Int, of total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(tokens) / Double(total), 0), 1)
    }

    private struct MetricChip {
        let title: String
        let value: String
    }

    private func metricChipRow(_ left: MetricChip, _ right: MetricChip) -> some View {
        HStack(spacing: 10) {
            metricChip(left)
            metricChip(right)
        }
    }

    private func metricChip(_ metric: MetricChip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.themeComment)

            Text(metric.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.themeBgDark)
        )
    }

    private func skillEstimateRow(_ skill: SkillEstimate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)

                Text("~\(formatTokenCount(skill.estimatedTokens))")
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

    private func refreshSessionStats() async {
        statsLoading = true
        statsError = nil

        do {
            loadedStats = try await loadSessionStats()
        } catch {
            loadedStats = nil
            statsError = "Detailed stats unavailable: \(error.localizedDescription)"
        }

        statsLoading = false
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
