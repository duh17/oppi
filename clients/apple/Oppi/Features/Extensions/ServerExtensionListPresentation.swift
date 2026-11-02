import Foundation

enum ServerExtensionSectionKind: String, CaseIterable, Sendable {
    case builtIn = "Built-in"
    case needsAttention = "Needs Attention"
    /// Pi extensions and plugins alike: a package can be both, and its toggle is one.
    case enabled = "Enabled"
    case disabled = "Disabled"
}

/// A pill on an extension's row, from its protocol fields only.
struct ServerExtensionBadge: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case kind, source, required }

    let label: String
    let tone: Tone
}

/// One group of what a plugin contributes, on its detail page.
struct ServerPluginDetailSection: Sendable, Equatable {
    let title: String
    let lines: [String]
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

        // Whatever failed to load needs attention, a built-in included; the rest are
        // built-ins or the owner's, on or off.
        let attention = Self.sorted(filtered.filter(Self.needsAttention))
        let healthy = filtered.filter { !Self.needsAttention($0) }
        let builtIn = Self.sorted(healthy.filter(\.isBuiltIn))
        let normal = healthy.filter { !$0.isBuiltIn }
        let enabled = Self.sorted(normal.filter { $0.state == .on })
        let disabled = Self.sorted(normal.filter { $0.state == .off })

        sections = [
            builtIn.isEmpty ? nil : ServerExtensionListSection(kind: .builtIn, extensions: builtIn),
            attention.isEmpty ? nil : ServerExtensionListSection(kind: .needsAttention, extensions: attention),
            enabled.isEmpty ? nil : ServerExtensionListSection(kind: .enabled, extensions: enabled),
            disabled.isEmpty ? nil : ServerExtensionListSection(kind: .disabled, extensions: disabled),
        ].compactMap { $0 }
    }

    private static func needsAttention(_ resource: ServerExtensionSummary) -> Bool {
        resource.state == .error || resource.state == .unknown
    }

    var visibleExtensions: [ServerExtensionSummary] {
        sections.flatMap(\.extensions)
    }

    /// Nothing but Oppi's own and plugins: the page says where Pi extensions come from.
    var hasNoPiExtensions: Bool {
        query.isEmpty && !allExtensions.contains { $0.isPiExtension && !$0.isBuiltIn }
    }

    var isFilteredNoResults: Bool {
        !query.isEmpty && visibleExtensions.isEmpty
    }

    static func stateLabel(for state: ServerExtensionState) -> String {
        switch state {
        case .on: "Enabled"
        case .off: "Disabled"
        case .error, .unknown: "Error"
        }
    }

    /// The state, and for a plugin whose reload failed, that its previous code still runs.
    static func statusLabel(for resource: ServerExtensionSummary) -> String {
        let state = stateLabel(for: resource.state)
        return resource.plugin?.kept == true ? "\(state), previous code still running" : state
    }

    /// Plugin, Pi extension, or both; then Built-in or Project (the owner's is the default);
    /// then Required. Only the row's fields decide, never its name.
    static func badges(for resource: ServerExtensionSummary) -> [ServerExtensionBadge] {
        var badges: [ServerExtensionBadge] = []
        let kinds = resource.kinds ?? []
        if kinds.contains(.plugin) { badges.append(.init(label: "Plugin", tone: .kind)) }
        if kinds.contains(.piExtension) { badges.append(.init(label: "Pi extension", tone: .kind)) }
        if let source = sourceLabel(resource.source), resource.source != .owner {
            badges.append(.init(label: source, tone: .source))
        }
        if resource.plugin?.required == true { badges.append(.init(label: "Required", tone: .required)) }
        return badges
    }

    /// "Plugin", "Pi extension", or both; nil from a server that predates plugins.
    static func kindsLabel(for resource: ServerExtensionSummary) -> String? {
        let labels = badges(for: resource).filter { $0.tone == .kind }.map(\.label)
        return labels.isEmpty ? nil : labels.joined(separator: " and ")
    }

    static func sourceLabel(_ source: ServerExtensionSource?) -> String? {
        switch source {
        case .builtIn: "Built-in"
        case .owner: "Owner"
        case .project: "Project"
        case .unknown, nil: nil
        }
    }

    /// What a plugin's extension contributes, one group each, empty groups left out. Hooks are
    /// grouped by task, each handler once.
    static func pluginSections(for plugin: ServerPluginSummary) -> [ServerPluginDetailSection] {
        var tasks: [String] = []
        var handlers: [String: [String]] = [:]
        for hook in plugin.hooks {
            if handlers[hook.task] == nil { tasks.append(hook.task) }
            for handler in hook.handlers where handlers[hook.task]?.contains(handler) != true {
                handlers[hook.task, default: []].append(handler)
            }
        }
        let wraps = plugin.wraps.compactMap { wrap -> String? in
            if let tool = wrap.tool { return "Tool \(tool)" }
            if let section = wrap.section { return "Prompt section \(section)" }
            return nil
        }
        return [
            ServerPluginDetailSection(title: "Tools", lines: plugin.tools),
            ServerPluginDetailSection(
                title: "Hooks",
                lines: tasks.map { "\($0): \((handlers[$0] ?? []).joined(separator: ", "))" }
            ),
            ServerPluginDetailSection(title: "Prompt Sections", lines: plugin.sections),
            ServerPluginDetailSection(title: "Wraps", lines: wraps),
            ServerPluginDetailSection(title: "Tasks", lines: plugin.tasks),
            ServerPluginDetailSection(title: "Runtimes", lines: plugin.runtimes),
        ].filter { !$0.lines.isEmpty }
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

    /// The host file Edit with Oppi changes, or nil when the extension has none.
    /// Only a single file the user owns qualifies: the server resolves a Pi
    /// extension's entry file, so a package (installed under the package
    /// manager, rewritten on update), a built-in, a directory, and an unknown
    /// kind have no file to revise. The path must be absolute and one line, as
    /// the Context panel requires of a host extension file.
    static func editablePath(for resource: ServerExtensionSummary) -> String? {
        guard resource.kind == .file,
              resource.provenance.kind != .package,
              resource.provenance.kind != .builtIn,
              let path = resource.path,
              path.hasPrefix("/"),
              !path.contains(where: \.isNewline) else { return nil }
        return path
    }

    static func accessibilityLabel(for resource: ServerExtensionSummary) -> String {
        var components = [resource.name]
        if let packageName = resource.packageName {
            components.append(packageName)
        }
        components.append(resource.provenance.label)
        components += badges(for: resource).map(\.label)
        components.append(statusLabel(for: resource))
        return components.joined(separator: ", ")
    }

    private static func matches(_ resource: ServerExtensionSummary, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return FuzzyMatch.matchesAny(query: query, fields: [
            resource.name,
            resource.description,
            resource.packageName,
            resource.provenance.label,
            kindLabel(for: resource.kind),
            stateLabel(for: resource.state),
        ] + badges(for: resource).map { Optional($0.label) })
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

/// One line of the Extensions page's Last Reload section.
struct ServerPluginReloadLine: Sendable, Hashable {
    /// Unique within one report: its kind and the plugin, name, or entry it is about.
    let id: String
    /// Its row's identifier key: its kind and the plugin, name, or entry, never display text.
    let accessibilityKey: String
    let text: String
    let detail: String?
    let symbol: String
    let isIssue: Bool

    init(id: String, accessibilityKey: String? = nil, text: String, detail: String?, symbol: String, isIssue: Bool) {
        self.id = id
        self.accessibilityKey = accessibilityKey ?? id
        self.text = text
        self.detail = detail
        self.symbol = symbol
        self.isIssue = isIssue
    }
}

/// What the last plugin reload did, as the Extensions page lists it: what loaded, what kept its
/// previous code, what was removed, what failed, and what was skipped.
enum ServerPluginReloadPresentation {
    static func lines(for state: ServerPluginReloadState) -> [ServerPluginReloadLine] {
        switch state {
        case .reloading:
            return [.init(id: "reloading", text: String(localized: "Reloading plugins…"), detail: nil, symbol: "arrow.clockwise", isIssue: false)]
        case .failed(let reason):
            return [.init(id: "failed", text: String(localized: "Couldn't reload plugins"), detail: reason, symbol: "exclamationmark.triangle.fill", isIssue: true)]
        case .finished(let report):
            return lines(for: report)
        }
    }

    /// The issue's file under its message, unless the message already names it.
    private static func fileDetail(_ issue: ServerPluginReloadReport.Issue) -> String? {
        issue.message.contains(issue.entry) ? nil : issue.entry
    }

    private static func lines(for report: ServerPluginReloadReport) -> [ServerPluginReloadLine] {
        var lines: [ServerPluginReloadLine] = []
        if !report.loaded.isEmpty {
            lines.append(.init(
                id: "loaded",
                text: report.loaded.count == 1
                    ? String(localized: "Loaded 1 plugin")
                    : String(localized: "Loaded \(report.loaded.count) plugins"),
                detail: report.loaded.map(\.name).joined(separator: ", "),
                symbol: "checkmark.circle",
                isIssue: false
            ))
        }
        for kept in report.kept {
            lines.append(.init(
                id: "kept.\(kept.name)",
                text: String(localized: "\(kept.name) failed to reload; its previous code still runs"),
                detail: kept.entry,
                symbol: "exclamationmark.triangle.fill",
                isIssue: true
            ))
        }
        for name in report.removed {
            lines.append(.init(id: "removed.\(name)", text: String(localized: "Removed \(name)"), detail: nil, symbol: "minus.circle", isIssue: false))
        }
        for issue in report.errors {
            lines.append(.init(id: "error.\(issue.entry).\(issue.message)", accessibilityKey: "error.\(issue.entry)", text: issue.message, detail: fileDetail(issue), symbol: "xmark.octagon", isIssue: true))
        }
        for issue in report.skipped {
            lines.append(.init(id: "skipped.\(issue.entry).\(issue.message)", accessibilityKey: "skipped.\(issue.entry)", text: issue.message, detail: fileDetail(issue), symbol: "arrow.uturn.right", isIssue: false))
        }
        if lines.isEmpty {
            lines.append(.init(id: "none", text: String(localized: "No plugins found."), detail: nil, symbol: "puzzlepiece.extension", isIssue: false))
        }
        // A diffable list traps on a repeated item.
        var seen = Set<String>()
        return lines.filter { seen.insert($0.id).inserted }
    }
}
