import SwiftUI

/// Session context popover. Files stay in the inspector; the document column
/// stays a document. Parse lives in OppiCore; this view only paints.
struct MacSessionContextInspectorView: View {
    let store: MacSessionTraceStore

    private var usage: ContextUsageSnapshot {
        SessionContextUsagePresentation.snapshot(for: store.session)
    }

    private var stats: SessionStatsSnapshot? {
        store.sessionStats ?? store.session.map(SessionStatsSnapshot.fallback(from:))
    }

    private var compositionSegments: [SessionContextCompositionSegment] {
        guard let composition = store.sessionStats?.contextComposition else { return [] }
        return SessionContextCompositionProjection.segments(
            totalContextTokens: usage.usedTokens,
            composition: composition
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                usageSection
                compositionSection
                skillsSection
                extensionsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 280)
        .task {
            await store.loadSessionStatsFromLocalConfig()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(usage.usageText)
                    .font(.title3.weight(.semibold))
                Spacer()
                if store.isLoadingSessionStats {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let progress = usage.progress {
                Text("\(usage.percentText) used")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(progressTint(progress))
            } else {
                Text("Context usage can be temporarily unknown right after compaction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Session Usage")
                .font(.headline)

            if let stats {
                let tokens = stats.tokens
                metricRow("Prompt input", SessionFormatting.tokenCount(tokens.promptInput))
                metricRow(
                    "Cached",
                    SessionFormatting.tokenCount(tokens.cacheRead),
                    detail: tokens.cacheHitRate.map { String(format: "%.1f%% hit", $0 * 100) }
                )
                metricRow(
                    "Uncached",
                    SessionFormatting.tokenCount(tokens.uncachedInput)
                )
                metricRow("Output", SessionFormatting.tokenCount(tokens.output))
                metricRow("Total cost", SessionFormatting.costString(stats.cost))

                if let cacheWaste = stats.cacheWaste, cacheWaste.missedTokens > 0 {
                    Text(cacheWasteDetail(cacheWaste))
                        .font(.caption)
                        .foregroundStyle(.themeOrange)
                }

                if stats.modelBreakdown.count > 1 {
                    Text("Cost by model")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(stats.modelBreakdown) { model in
                        metricRow(
                            model.model,
                            SessionFormatting.costString(model.cost),
                            detail: modelUsageDetail(model)
                        )
                    }
                }

                if let error = store.sessionStatsError, !error.isEmpty {
                    Text("Detailed usage unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.isLoadingSessionStats {
                Text("Loading session usage…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Session usage is not available yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var compositionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context Breakdown")
                .font(.headline)

            if compositionSegments.isEmpty {
                if store.isLoadingSessionStats {
                    Text("Loading breakdown…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = store.sessionStatsError, !error.isEmpty {
                    Text("Detailed breakdown unavailable: \(error)")
                        .font(.caption)
                        .foregroundStyle(.themeOrange)
                } else {
                    Text("Breakdown appears after stats load.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                compositionBar
                ForEach(compositionSegments) { segment in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(compositionColor(for: segment.kind))
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.label)
                                .font(.subheadline.weight(.semibold))
                            Text(segment.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(SessionFormatting.tokenCount(segment.tokens))
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var compositionBar: some View {
        if usage.windowTokens > 0, !compositionSegments.isEmpty {
            GeometryReader { proxy in
                let totalWidth = max(proxy.size.width, 0)
                let window = Double(usage.windowTokens)
                HStack(spacing: 1.5) {
                    ForEach(compositionSegments) { segment in
                        let fraction = CGFloat(Double(segment.tokens) / window)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(compositionColor(for: segment.kind))
                            .frame(width: max(totalWidth * fraction, 0))
                    }
                    let usedFraction = compositionSegments.reduce(0.0) { $0 + Double($1.tokens) } / window
                    let remainingWidth = totalWidth * CGFloat(max(1.0 - usedFraction, 0))
                    if remainingWidth > 1 {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(width: remainingWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 12)

            HStack {
                Text("Used: \(SessionFormatting.tokenCount(usage.usedTokens))")
                    .font(.caption)
                Spacer()
                Text("Remaining: \(SessionFormatting.tokenCount(usage.remainingTokens))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        let resources = store.sessionStats?.loadedResources
        let skills = resources?.skills.sorted { $0.name < $1.name } ?? []
        let phase = MacSessionLoadedResourcesPresentation.phase(
            isLoading: store.isLoadingSessionStats,
            error: store.sessionStatsError,
            loadedResources: resources,
            itemCount: skills.count
        )
        VStack(alignment: .leading, spacing: 8) {
            Text("Loaded Skills")
                .font(.headline)
            if let placeholder = MacSessionLoadedResourcesPresentation.placeholder(
                kind: .skills,
                phase: phase
            ) {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.subheadline.weight(.medium))
                        if let description = skill.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var extensionsSection: some View {
        let resources = store.sessionStats?.loadedResources
        let extensions = resources?.extensions.sorted { $0.name < $1.name } ?? []
        let phase = MacSessionLoadedResourcesPresentation.phase(
            isLoading: store.isLoadingSessionStats,
            error: store.sessionStatsError,
            loadedResources: resources,
            itemCount: extensions.count
        )
        VStack(alignment: .leading, spacing: 8) {
            Text("Loaded Extensions")
                .font(.headline)
            if let placeholder = MacSessionLoadedResourcesPresentation.placeholder(
                kind: .extensions,
                phase: phase
            ) {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(extensions) { ext in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ext.name)
                            .font(.subheadline.weight(.medium))
                        if !ext.path.isEmpty {
                            Text(ext.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func metricRow(_ title: String, _ value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func cacheWasteDetail(_ waste: SessionCacheWasteSnapshot) -> String {
        let misses = waste.missCount == 1 ? "1 miss" : "\(waste.missCount) misses"
        let cost = waste.missedCost >= 0.0005
            ? ", about \(SessionFormatting.costString(waste.missedCost)) extra"
            : ""
        return "Cache re-billed: \(SessionFormatting.tokenCount(waste.missedTokens)) tokens across \(misses)\(cost)."
    }

    private func modelUsageDetail(_ model: SessionModelUsageSnapshot) -> String {
        let tokens = "\(SessionFormatting.tokenCount(model.tokens)) tokens"
        guard let provider = model.provider, !provider.isEmpty else { return tokens }
        return "\(provider) · \(tokens)"
    }

    private func compositionColor(for kind: SessionContextCompositionKind) -> Color {
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
}

/// Unknown `loadedResources` is not an empty catalog. Loading or a failed
/// stats fetch must not paint “No skills/extensions loaded.”
enum MacSessionLoadedResourcesPresentation {
    enum Kind: Equatable, Sendable {
        case skills
        case extensions
    }

    enum Phase: Equatable, Sendable {
        case loading
        case failed(String)
        case unknown
        case empty
        case filled
    }

    static func phase(
        isLoading: Bool,
        error: String?,
        loadedResources: SessionLoadedResourcesSnapshot?,
        itemCount: Int
    ) -> Phase {
        guard loadedResources != nil else {
            if isLoading { return .loading }
            if let error, !error.isEmpty { return .failed(error) }
            return .unknown
        }
        return itemCount == 0 ? .empty : .filled
    }

    static func placeholder(kind: Kind, phase: Phase) -> String? {
        switch (kind, phase) {
        case (.skills, .loading):
            "Loading skills…"
        case (.extensions, .loading):
            "Loading extensions…"
        case (.skills, .failed(let error)):
            "Skills unavailable: \(error)"
        case (.extensions, .failed(let error)):
            "Extensions unavailable: \(error)"
        case (.skills, .unknown):
            "Skills appear after stats load."
        case (.extensions, .unknown):
            "Extensions appear after stats load."
        case (.skills, .empty):
            "No skills loaded for this session."
        case (.extensions, .empty):
            "No extensions loaded for this session."
        case (_, .filled):
            nil
        }
    }
}
