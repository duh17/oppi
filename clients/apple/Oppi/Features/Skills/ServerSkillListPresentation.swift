import Foundation

enum ServerSkillSectionKind: String, CaseIterable, Sendable {
    case needsAttention = "Needs Attention"
    case enabled = "Enabled"
    case disabled = "Disabled"
}

struct ServerSkillListSection: Sendable, Equatable {
    let kind: ServerSkillSectionKind
    let skills: [ServerSkillSummary]
}

/// Pure Skills list policy: search, semantic grouping, stable localized order,
/// and accessibility text stay independent from SwiftUI and transport state.
struct ServerSkillListPresentation: Sendable, Equatable {
    let allSkills: [ServerSkillSummary]
    let query: String
    let sections: [ServerSkillListSection]

    init(skills: [ServerSkillSummary], query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        allSkills = skills
        self.query = normalizedQuery
        let filtered = skills.filter { Self.matches($0, query: normalizedQuery) }

        let attention = Self.sorted(filtered.filter { $0.state == .error || $0.state == .unknown })
        let enabled = Self.sorted(filtered.filter { $0.state == .enabled })
        let disabled = Self.sorted(filtered.filter { $0.state == .disabled })

        sections = [
            attention.isEmpty ? nil : ServerSkillListSection(kind: .needsAttention, skills: attention),
            enabled.isEmpty ? nil : ServerSkillListSection(kind: .enabled, skills: enabled),
            disabled.isEmpty ? nil : ServerSkillListSection(kind: .disabled, skills: disabled),
        ].compactMap { $0 }
    }

    var visibleSkills: [ServerSkillSummary] {
        sections.flatMap(\.skills)
    }

    var isCatalogEmpty: Bool {
        allSkills.isEmpty && query.isEmpty
    }

    var isFilteredNoResults: Bool {
        !query.isEmpty && visibleSkills.isEmpty
    }

    static func stateLabel(for state: ServerSkillState) -> String {
        switch state {
        case .enabled: "Enabled"
        case .disabled: "Disabled"
        case .error, .unknown: "Error"
        }
    }

    static func accessibilityLabel(for skill: ServerSkillSummary) -> String {
        var components = [skill.name]
        if let packageName = skill.packageName {
            components.append(packageName)
        }
        components.append(skill.provenance.label)
        components.append(stateLabel(for: skill.state))
        return components.joined(separator: ", ")
    }

    private static func matches(_ skill: ServerSkillSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        var searchableFields = [
            skill.name,
            skill.description,
            skill.provenance.label,
            stateLabel(for: skill.state),
        ]
        if let packageName = skill.packageName {
            searchableFields.append(packageName)
        }
        return searchableFields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sorted(_ skills: [ServerSkillSummary]) -> [ServerSkillSummary] {
        skills.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }
}

enum ServerSkillCatalogPresentationState: Equatable, Sendable {
    case firstLoad
    case cachedOffline
    case unavailable
    case empty
    case filteredNoResults
    case content

    static func resolve(
        hasLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasVisibleRows: Bool,
        isFilteredNoResults: Bool
    ) -> Self {
        if !hasLoaded {
            return lastSyncFailed ? .unavailable : .firstLoad
        }
        if isFilteredNoResults {
            return .filteredNoResults
        }
        if lastSyncFailed {
            return hasVisibleRows ? .cachedOffline : .unavailable
        }
        if !hasVisibleRows {
            return .empty
        }
        return .content
    }
}
