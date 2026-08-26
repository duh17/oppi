import Foundation

enum ServerExtensionSectionKind: String, CaseIterable, Sendable {
    case builtIn = "Built-in"
    case needsAttention = "Needs Attention"
    case enabledPiExtensions = "Enabled Pi Extensions"
    case disabledPiExtensions = "Disabled Pi Extensions"
}

struct ServerExtensionListSection: Sendable, Equatable {
    let kind: ServerExtensionSectionKind
    let extensions: [ServerExtensionSummary]
}

/// Pure Extensions list policy. Built-in ordering is semantic; generic rows
/// never infer identity from a display name, source label, or path.
struct ServerExtensionListPresentation: Sendable, Equatable {
    let allExtensions: [ServerExtensionSummary]
    let query: String
    let sections: [ServerExtensionListSection]

    init(extensions: [ServerExtensionSummary], query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        allExtensions = extensions
        self.query = normalizedQuery
        let filtered = extensions.filter { Self.matches($0, query: normalizedQuery) }

        let builtIn = Self.sortedBuiltIns(filtered.filter { $0.kind == .builtIn })
        let normal = filtered.filter { $0.kind != .builtIn }
        let attention = Self.sorted(normal.filter { $0.state == .error || $0.state == .unknown })
        let enabled = Self.sorted(normal.filter { $0.state == .on })
        let disabled = Self.sorted(normal.filter { $0.state == .off })

        sections = [
            builtIn.isEmpty ? nil : ServerExtensionListSection(kind: .builtIn, extensions: builtIn),
            attention.isEmpty ? nil : ServerExtensionListSection(kind: .needsAttention, extensions: attention),
            enabled.isEmpty ? nil : ServerExtensionListSection(kind: .enabledPiExtensions, extensions: enabled),
            disabled.isEmpty ? nil : ServerExtensionListSection(kind: .disabledPiExtensions, extensions: disabled),
        ].compactMap { $0 }
    }

    var visibleExtensions: [ServerExtensionSummary] {
        sections.flatMap(\.extensions)
    }

    var hasNoPiExtensions: Bool {
        query.isEmpty && allExtensions.allSatisfy { $0.kind == .builtIn }
    }

    var isFilteredNoResults: Bool {
        !query.isEmpty && visibleExtensions.isEmpty
    }

    static func stateLabel(for state: ServerExtensionState) -> String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .error, .unknown: "Error"
        }
    }

    static func kindLabel(for kind: ServerExtensionKind) -> String {
        switch kind {
        case .builtIn: "Built-in extension"
        case .file: "File"
        case .directory: "Directory"
        case .package: "Package"
        case .unknown: "Unknown kind"
        }
    }

    static func accessibilityLabel(for resource: ServerExtensionSummary) -> String {
        var components = [resource.name]
        if let packageName = resource.packageName {
            components.append(packageName)
        }
        components.append(resource.provenance.label)
        components.append(stateLabel(for: resource.state))
        return components.joined(separator: ", ")
    }

    private static func matches(_ resource: ServerExtensionSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            resource.name,
            resource.description,
            resource.packageName,
            resource.provenance.label,
            kindLabel(for: resource.kind),
            stateLabel(for: resource.state),
        ].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private static func sortedBuiltIns(_ resources: [ServerExtensionSummary]) -> [ServerExtensionSummary] {
        sorted(resources)
    }

    private static func sorted(_ resources: [ServerExtensionSummary]) -> [ServerExtensionSummary] {
        resources.sorted(by: compare)
    }

    private static func compare(_ lhs: ServerExtensionSummary, _ rhs: ServerExtensionSummary) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }
}

enum ServerExtensionCatalogPresentationState: Equatable, Sendable {
    case firstLoad
    case cachedOffline
    case unavailable
    case filteredNoResults
    case content

    static func resolve(
        hasLoaded: Bool,
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
        return .content
    }
}
