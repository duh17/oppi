import Foundation

enum ServerExtensionSectionKind: String, CaseIterable, Sendable {
    /// Oppi's own plugins: what durable sessions run on.
    case builtIn = "Built into Durable Sessions"
    case needsAttention = "Needs Attention"
    /// Pi extensions and plugins alike: a package can be both, and its toggle is one.
    case enabled = "Enabled"
    case disabled = "Disabled"
}

/// A pill on an extension's row, from its protocol fields only.
struct ServerExtensionBadge: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case kind, source }

    let label: String
    let tone: Tone
}

/// A row's puzzle mark. Off is the same symbol emptied, in a muted tint, so a
/// disabled row reads as off before its state line is read.
enum ServerExtensionRowIcon: Sendable, Equatable {
    case enabled, disabled

    var symbolName: String {
        self == .enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension"
    }
}

/// One group of what a plugin contributes, on its detail page.
struct ServerPluginDetailSection: Sendable, Equatable {
    let title: String
    let lines: [String]
}

/// Which sessions a tool reaches: a plugin's run in durable sessions, a classic Pi
/// extension's in Pi sessions.
/// Its raw value keys the tool's row identifier.
enum ServerExtensionToolOrigin: String, Hashable, Sendable {
    case plugin, piExtension
}

/// One tool row on an extension's detail page: its name and the first line of
/// its description.
struct ServerExtensionToolRow: Sendable, Equatable {
    let name: String
    let summary: String?
}

/// The tools of one origin. A row that is a plugin and a Pi extension lists two
/// groups, so each says which sessions it is for.
struct ServerExtensionToolGroup: Sendable, Equatable {
    let origin: ServerExtensionToolOrigin
    let title: String
    let tools: [ServerExtensionToolRow]
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
        let builtIn = Self.sorted(filtered.filter(Self.isInBuiltInSection))
        let normal = filtered.filter { !Self.needsAttention($0) && !$0.isBuiltIn }
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

    /// A healthy built-in: its section already says it ships with Oppi.
    private static func isInBuiltInSection(_ resource: ServerExtensionSummary) -> Bool {
        resource.isBuiltIn && !needsAttention(resource)
    }

    /// Part of the durable session runtime and running: its plugin cannot be turned off.
    static func isAlwaysOn(_ resource: ServerExtensionSummary) -> Bool {
        resource.state == .on && resource.plugin?.required == true
    }

    /// The section's one sentence, or nil for a section that needs none.
    static func footer(for kind: ServerExtensionSectionKind) -> String? {
        kind == .builtIn
            ? String(localized: "These ship with Oppi and run in durable sessions; the ones you can’t turn off are part of the runtime.")
            : nil
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

    /// The row's state line: "Always on" for a runtime plugin; otherwise the state, and for a
    /// plugin whose reload failed, that its previous code still runs.
    static func statusLabel(for resource: ServerExtensionSummary) -> String {
        if isAlwaysOn(resource) { return String(localized: "Always on") }
        let state = stateLabel(for: resource.state)
        return resource.plugin?.kept == true ? "\(state), previous code still running" : state
    }

    /// Filled while on (or failing, which the state line flags); emptied while off.
    static func icon(for resource: ServerExtensionSummary) -> ServerExtensionRowIcon {
        resource.state == .off ? .disabled : .enabled
    }

    /// Plugin, Pi extension, or both; then Built-in or Project (the owner's is the default).
    /// In the built-in section the section names the source, and a plugin is what it holds,
    /// so only a Pi extension there says so. Only the row's fields decide, never its name.
    static func badges(for resource: ServerExtensionSummary) -> [ServerExtensionBadge] {
        var badges: [ServerExtensionBadge] = []
        let kinds = resource.kinds ?? []
        let inBuiltInSection = isInBuiltInSection(resource)
        if kinds.contains(.plugin), !inBuiltInSection { badges.append(.init(label: "Plugin", tone: .kind)) }
        if kinds.contains(.piExtension) { badges.append(.init(label: "Pi extension", tone: .kind)) }
        if let source = sourceLabel(resource.source), resource.source != .owner, !inBuiltInSection {
            badges.append(.init(label: source, tone: .source))
        }
        return badges
    }

    /// "Plugin", "Pi extension", or both; nil from a server that predates plugins.
    static func kindsLabel(for resource: ServerExtensionSummary) -> String? {
        let kinds = resource.kinds ?? []
        let labels = [
            kinds.contains(.plugin) ? "Plugin" : nil,
            kinds.contains(.piExtension) ? "Pi extension" : nil,
        ].compactMap { $0 }
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

    /// The About card's Type: the layer, what the row is, and the shape it is installed
    /// in ("Built-in plugin", "Owner Pi extension · Package"). A built-in's layer already
    /// says how it ships, so its kind adds nothing; a server that predates plugins says
    /// Built-in only in `kind`.
    static func typeLabel(for resource: ServerExtensionSummary) -> String {
        let kinds = resource.kinds ?? []
        var what = [
            kinds.contains(.plugin) ? "plugin" : nil,
            resource.isPiExtension ? "Pi extension" : nil,
        ].compactMap { $0 }.joined(separator: " and ")
        if what.isEmpty { what = "extension" }
        let layer = sourceLabel(resource.source) ?? (resource.kind == .builtIn ? "Built-in" : nil)
        let label = [layer, what].compactMap { $0 }.joined(separator: " ")
        let shape: String? = switch resource.kind {
        case .file, .directory, .package: kindLabel(for: resource.kind)
        case .builtIn, .unknown: nil
        }
        let full = [label.prefix(1).uppercased() + label.dropFirst(), shape].compactMap { $0 }
        return full.joined(separator: " · ")
    }

    /// The About card's From: the package, else where the server found it.
    static func fromLabel(for resource: ServerExtensionSummary) -> String {
        resource.packageName ?? resource.provenance.label
    }

    /// The About card's Runs In: a plugin's runtimes as one value ("Host and sandbox"),
    /// or nil for a row with none (a classic extension, a plugin that never loaded).
    static func runtimesLabel(for plugin: ServerPluginSummary?) -> String? {
        guard let runtimes = plugin?.runtimes, !runtimes.isEmpty else { return nil }
        let joined = ListFormatter.localizedString(byJoining: runtimes)
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// A description's first line, the tool row's subtitle.
    static func firstLine(of text: String?) -> String? {
        let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    /// The detail page's tools: a plugin's (from its summary) and a classic extension's
    /// (from the detail), each name once per group. When both have tools, each group says
    /// which sessions it is for.
    static func toolGroups(
        summary: ServerExtensionSummary,
        detail: ServerExtensionDetail?
    ) -> [ServerExtensionToolGroup] {
        let descriptions = Dictionary(
            (detail?.contributedToolDetails ?? []).map { ($0.name, $0.description) },
            uniquingKeysWith: { first, _ in first }
        )
        let classic = detail?.contributedTools ?? detail?.contributedToolDetails?.map(\.name) ?? []
        let groups: [(ServerExtensionToolOrigin, [ServerExtensionToolRow])] = [
            (.plugin, uniqueNames(summary.plugin?.tools ?? []).map { ServerExtensionToolRow(name: $0, summary: nil) }),
            (.piExtension, uniqueNames(classic).map {
                ServerExtensionToolRow(name: $0, summary: firstLine(of: descriptions[$0] ?? nil))
            }),
        ].filter { !$0.1.isEmpty }
        return groups.map { origin, tools in
            let title = groups.count == 1 ? "Tools"
                : origin == .plugin ? "Tools in Durable Sessions" : "Tools in Pi Sessions"
            return ServerExtensionToolGroup(origin: origin, title: title, tools: tools)
        }
    }

    private static func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// What a plugin's extension contributes besides its tools (the Tools section) and
    /// runtimes (the About card), one group each, empty groups left out. Hooks are grouped
    /// by task, each handler once.
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
            ServerPluginDetailSection(
                title: "Hooks",
                lines: tasks.map { "\($0): \((handlers[$0] ?? []).joined(separator: ", "))" }
            ),
            ServerPluginDetailSection(title: "Prompt Sections", lines: plugin.sections),
            ServerPluginDetailSection(title: "Wraps", lines: wraps),
            ServerPluginDetailSection(title: "Tasks", lines: plugin.tasks),
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
        // The state stays spoken; a runtime plugin adds that it cannot be turned off.
        components.append(isAlwaysOn(resource)
            ? "\(stateLabel(for: resource.state)), \(String(localized: "always on"))"
            : statusLabel(for: resource))
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
            statusLabel(for: resource),
            kindsLabel(for: resource),
            sourceLabel(resource.source),
        ])
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
