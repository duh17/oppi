import SwiftUI

struct ContextInspectorView: View {
    let session: Session?
    let workspace: Workspace?
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

        let systemTotal = min(max(composition.piSystemPromptTokens, 0), total)
        let agents = min(max(composition.agentsTokens, 0), systemTotal)
        let skills = min(max(composition.skillsListingTokens, 0), systemTotal)
        let basePrompt = max(systemTotal - agents - skills, 0)
        let messages = max(total - systemTotal, 0)

        var segments: [CompositionSegment] = []

        if basePrompt > 0 {
            segments.append(CompositionSegment(
                label: "Pi Base Prompt",
                detail: "Pi system prompt, tools, and baseline instructions.",
                tokens: basePrompt,
                color: .themePurple
            ))
        }

        if agents > 0 {
            let fileCount = composition.agentsFiles.count
            segments.append(CompositionSegment(
                label: "AGENTS files (\(fileCount))",
                detail: "Workspace instructions from AGENTS.md files.",
                tokens: agents,
                color: .themeCyan
            ))
        }

        if skills > 0 {
            segments.append(CompositionSegment(
                label: "Skills Index",
                detail: "Available skill names and descriptions included in context.",
                tokens: skills,
                color: .themeYellow
            ))
        }

        if messages > 0 {
            segments.append(CompositionSegment(
                label: "Messages and Runtime",
                detail: "Conversation history, tool calls, and results.",
                tokens: messages,
                color: .themeGreen
            ))
        }

        return segments
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
                        Text(statsError)
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
        .background(Color.themeBg)
        .tint(.themeBlue)
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
                            .fill(Color.themeComment.opacity(0.2))
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
