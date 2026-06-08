import SwiftUI

/// Model picker sheet with provider grouping and context window info.
///
/// Uses `chatState.cachedModels` for instant open, with background refresh.
/// Recently-used models appear in a dedicated section at the top.
struct ModelPickerSheet: View {
    let currentModel: String?
    let onSelect: (ModelInfo) -> Void

    @Environment(\.apiClient) private var apiClient
    @Environment(ChatSessionState.self) private var chatState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var collapsedProviders: Set<String> = []
    @State private var codexUsage: CodexUsageInfo?
    private var recentIds: [String] { AppPreferences.RecentModels.load() }

    private var models: [ModelInfo] { chatState.cachedModels }

    /// Full provider/id key for matching (delegates to policy to avoid double-prefix).
    private func fullId(_ model: ModelInfo) -> String {
        ModelSwitchPolicy.fullModelID(for: model)
    }

    /// Models the user picked recently, ordered by recency.
    private var recentModels: [ModelInfo] {
        let ids = recentIds
        let lookup = Dictionary(models.map { (fullId($0), $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { lookup[$0] }
    }

    /// All models grouped by provider, excluding any in the recent section.
    /// When searching, uses FuzzyMatch across name/id/provider and sorts by score.
    private var groupedModels: [(provider: String, models: [ModelInfo], modelCount: Int)] {
        let recentSet = Set(recentIds)
        let filtered: [ModelInfo]
        if searchText.isEmpty {
            filtered = models.filter { !recentSet.contains(fullId($0)) }
        } else {
            // Fuzzy search across name, id, and provider — take best score
            let query = searchText
            var scored: [(model: ModelInfo, score: Int)] = []
            for model in models {
                let candidates = [model.name, model.id, model.provider]
                let bestScore = candidates.compactMap { FuzzyMatch.match(query: query, candidate: $0)?.score }.max()
                if let score = bestScore {
                    scored.append((model, score))
                }
            }
            scored.sort { $0.score > $1.score }
            filtered = scored.map(\.model)
        }

        let grouped = Dictionary(grouping: filtered) { $0.provider }
        let providerCounts = Dictionary(grouping: models) { $0.provider }
            .mapValues(\.count)
        let providers = searchText.isEmpty
            ? Array(providerCounts.keys)
            : Array(grouped.keys)
        let orderedProviders = ModelPickerProviderOrdering.sortProviders(
            providers,
            recentModels: recentModels
        )
        return orderedProviders.map { provider in
            (
                provider: provider,
                models: grouped[provider] ?? [],
                modelCount: providerCounts[provider] ?? grouped[provider]?.count ?? 0
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if models.isEmpty && !chatState.modelsCacheReady {
                    ProgressView("Loading models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if models.isEmpty {
                    ContentUnavailableView(
                        "No Models Available",
                        systemImage: "cpu",
                        description: Text("Server returned no models.")
                    )
                } else {
                    modelList
                }
            }
            .background(Color.themeBg)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // Background refresh — UI already shows cached data
                if let api = apiClient {
                    async let refresh: Void = chatState.refreshModelCache(api: api)
                    async let usage: Void = loadCodexUsage(api: api)
                    _ = await (refresh, usage)
                }
            }
        }
    }

    private var modelList: some View {
        List {
            // Recent section (only when not searching)
            if searchText.isEmpty, !recentModels.isEmpty {
                Section {
                    ForEach(recentModels) { model in
                        modelRow(model)
                    }
                } header: {
                    Text("Recent")
                        .font(.caption.bold())
                        .foregroundStyle(.themeFgDim)
                }
            }

            ForEach(groupedModels, id: \.provider) { group in
                let isCollapsed = isProviderCollapsed(group.provider)
                let hasVisibleModels = !group.models.isEmpty

                Section {
                    if !isCollapsed {
                        ForEach(group.models) { model in
                            modelRow(model)
                        }
                    }
                } header: {
                    providerHeader(
                        provider: group.provider,
                        isCollapsed: isCollapsed,
                        modelCount: group.modelCount,
                        hasVisibleModels: hasVisibleModels
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        let isCurrent = isCurrentModel(model)
        ModelRow(model: model, isCurrent: isCurrent)
            .contentShape(Rectangle())
            .onTapGesture {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelect(model)
                dismiss()
            }
            .listRowBackground(
                isCurrent ? Color.themeBlue.opacity(0.12) : Color.themeBg
            )
    }

    private func isCurrentModel(_ model: ModelInfo) -> Bool {
        guard let current = currentModel else { return false }
        let fid = fullId(model)
        return current == fid || current == model.id
    }

    private func providerDisplayName(_ provider: String) -> String {
        ProviderIcon.displayName(for: provider)
    }

    private func isProviderCollapsed(_ provider: String) -> Bool {
        searchText.isEmpty && collapsedProviders.contains(provider)
    }

    private func toggleProviderCollapse(_ provider: String) {
        if collapsedProviders.contains(provider) {
            collapsedProviders.remove(provider)
        } else {
            collapsedProviders.insert(provider)
        }
    }

    private func providerHeader(
        provider: String,
        isCollapsed: Bool,
        modelCount: Int,
        hasVisibleModels: Bool
    ) -> some View {
        let isSearchActive = !searchText.isEmpty
        let name = providerDisplayName(provider)

        return Button {
            guard !isSearchActive && hasVisibleModels else { return }
            withAnimation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion)) {
                toggleProviderCollapse(provider)
            }
        } label: {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider)
                Text(name)

                Spacer(minLength: 8)

                let usageBadges = codexUsageBadges(for: provider)
                if !usageBadges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(usageBadges.indices), id: \.self) { index in
                            let badge = usageBadges[index]
                            StatusPill(
                                text: badge.label,
                                tone: tone(for: badge.tone),
                                emphasis: .tinted,
                                size: .small,
                                monospacedDigit: true
                            )
                        }
                    }
                }

                if !isSearchActive {
                    Text("\(modelCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.themeComment)

                    if hasVisibleModels {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.themeComment)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption.bold())
        .foregroundStyle(.themeFgDim)
        .accessibilityLabel(
            isSearchActive || !hasVisibleModels
                ? name
                : (isCollapsed ? "Expand \(name) models" : "Collapse \(name) models")
        )
    }

    @MainActor
    private func loadCodexUsage(api: APIClient) async {
        do {
            codexUsage = try await api.fetchCodexUsage()
        } catch {
            // Keep picker lightweight; missing usage data should not block model selection.
        }
    }

    private func codexUsageBadges(for provider: String) -> [CodexUsageInfo.ProviderBadge] {
        codexUsage?.providerBadges(for: provider) ?? []
    }

    private func tone(for tone: CodexUsageInfo.BadgeTone) -> StatusPillTone {
        switch tone {
        case .green:
            return .success
        case .orange:
            return .warning
        case .red:
            return .danger
        }
    }
}

enum ModelPickerProviderOrdering {
    struct Stats: Equatable {
        var count = 0
        var bestRecentIndex = Int.max
    }

    static func sortProviders(_ providers: [String], recentModels: [ModelInfo]) -> [String] {
        let stats = providerStats(from: recentModels)
        return providers.sorted { lhs, rhs in
            let lhsFamily = providerFamily(lhs)
            let rhsFamily = providerFamily(rhs)
            let lhsStats = stats[lhsFamily] ?? Stats()
            let rhsStats = stats[rhsFamily] ?? Stats()

            if lhsStats.count != rhsStats.count {
                return lhsStats.count > rhsStats.count
            }
            if lhsStats.bestRecentIndex != rhsStats.bestRecentIndex {
                return lhsStats.bestRecentIndex < rhsStats.bestRecentIndex
            }

            let lhsBoost = providerBoost(lhsFamily)
            let rhsBoost = providerBoost(rhsFamily)
            if lhsBoost != rhsBoost {
                return lhsBoost < rhsBoost
            }

            let lhsName = ProviderIcon.displayName(for: lhs)
            let rhsName = ProviderIcon.displayName(for: rhs)
            let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    static func providerFamily(_ provider: String) -> String {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "openai-codex":
            return "openai"
        default:
            return normalized
        }
    }

    private static func providerStats(from recentModels: [ModelInfo]) -> [String: Stats] {
        var stats: [String: Stats] = [:]
        for (index, model) in recentModels.enumerated() {
            let family = providerFamily(model.provider)
            var entry = stats[family] ?? Stats()
            entry.count += 1
            entry.bestRecentIndex = min(entry.bestRecentIndex, index)
            stats[family] = entry
        }
        return stats
    }

    private static func providerBoost(_ family: String) -> Int {
        family == "openai" ? 0 : 1
    }
}


// MARK: - Model Row

private struct ModelRow: View {
    let model: ModelInfo
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Left: name + provider/id
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline.weight(isCurrent ? .bold : .regular))
                        .foregroundStyle(isCurrent ? .themeBlue : .themeFg)
                        .lineLimit(1)

                    if isCurrent {
                        StatusPill(
                            text: "current",
                            tone: .accent,
                            emphasis: .tinted,
                            size: .mini
                        )
                    }
                }

                Text(ModelSwitchPolicy.fullModelID(for: model))
                    .font(.caption.monospaced())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            // Right: context window + checkmark, fixed trailing column
            HStack(spacing: 8) {
                if model.contextWindow > 0 {
                    Text(SessionFormatting.tokenCount(model.contextWindow))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.themeFgDim)
                }

                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.themeBlue)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}
