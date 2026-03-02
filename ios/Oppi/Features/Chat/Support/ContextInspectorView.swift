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

    private var compositionSegments: [CompositionSegment] {
        guard let total = contextSnapshot.tokens, total > 0 else { return [] }
        guard let composition = loadedStats?.contextComposition else { return [] }

        let system = min(max(composition.piSystemPromptTokens, 0), total)
        let messages = max(total - system, 0)

        return [
            CompositionSegment(
                label: "Pi system prompt (actual)",
                detail: "Exact current prompt text loaded by pi (includes AGENTS and instructions).",
                tokens: system,
                color: .themePurple
            ),
            CompositionSegment(
                label: "Messages + runtime",
                detail: "Everything else currently in context beyond the system prompt.",
                tokens: messages,
                color: .themeGreen
            ),
        ]
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

            Section("Context Composition") {
                if compositionSegments.isEmpty {
                    Text("Composition appears after detailed stats load.")
                        .font(.subheadline)
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(compositionSegments) { segment in
                        compositionLegendRow(segment)
                    }

                    if let composition = loadedStats?.contextComposition {
                        Text("AGENTS files loaded: \(composition.agentsFiles.count) (~\(formatTokenCount(composition.agentsTokens))).")
                            .font(.caption)
                            .foregroundStyle(.themeComment)
                    }
                }
            }

            Section("Session Activity") {
                contextUsageBar

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
    private var contextUsageBar: some View {
        if let progress = contextSnapshot.progress,
           contextWindowTokens > 0 {
            GeometryReader { proxy in
                let totalWidth = max(proxy.size.width, 0)
                let usedWidth = totalWidth * CGFloat(progress)
                let remainingWidth = max(totalWidth - usedWidth, 0)

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(progressTint(progress))
                        .frame(width: usedWidth)

                    if remainingWidth > 0 {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.themeComment.opacity(0.25))
                            .frame(width: remainingWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 14)
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                Text("Used: \(formatTokenCount(contextUsedTokens))")
                    .font(.caption)
                    .foregroundStyle(.themeFg)

                Spacer(minLength: 8)

                Text("Remaining: \(formatTokenCount(contextRemainingTokens))")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
            }
        } else {
            Text("Context usage unavailable.")
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
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
