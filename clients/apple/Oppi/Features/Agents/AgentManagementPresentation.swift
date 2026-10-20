import Foundation

enum AgentManagementRow: Equatable, Identifiable {
    case pi
    case saved(AgentDefinitionSummary)

    var id: String {
        switch self {
        case .pi: "pi"
        case .saved(let agent): "saved:\(agent.id)"
        }
    }

    var agentId: String? {
        guard case .saved(let agent) = self else { return nil }
        return agent.id
    }

    var name: String {
        switch self {
        case .pi: "Pi"
        case .saved(let agent): agent.name
        }
    }
}

enum AgentManagementPresentation {
    static let globalSystemPromptPath = "~/.pi/agent/SYSTEM.md"
    static let piIdentityAccessibilityLabel = "Pi"
    static let piDefaultPromptInUseLabel = "Pi default in use until SYSTEM.md exists"
    static let piStandardToolsSummary = "Pi standard"
    static let piToolsInheritFooter =
        "Uses Pi's standard built-in tools. Extension tools stay enabled."
    static let piToolsExactFooter =
        "Only the selected built-in tools are available. Extension tools stay enabled."
    static let piOptionalToolsFooter =
        "Pi and its extensions register these tools off; turning one on adds it to Pi's defaultTools. MCP servers can still turn on codemode or tool_search when their exposure needs it."

    static func rows(savedAgents: [AgentDefinitionSummary]) -> [AgentManagementRow] {
        [.pi] + savedAgents.map(AgentManagementRow.saved)
    }

    static func piPromptIsReviewable(_ source: PiSystemPromptSnapshot.Source) -> Bool {
        source == .file
    }

    static func piSystemPromptAccessibilityLabel(source: PiSystemPromptSnapshot.Source) -> String {
        source == .file ? "Read and comment on SYSTEM.md" : piDefaultPromptInUseLabel
    }

    static func piSystemPromptAccessibilityValue(source: PiSystemPromptSnapshot.Source) -> String? {
        source == .file ? nil : piDefaultPromptInUseLabel
    }

    struct PiToolsSaveCoordinator: Equatable {
        var persisted: [String]?
        private(set) var isSaving = false
        private var hasQueuedSave = false

        init(persisted: [String]? = nil) {
            self.persisted = persisted
        }

        private(set) var pendingDesired: [String]?

        /// Returns true when the caller should run the save loop.
        mutating func requestSave() -> Bool {
            if isSaving {
                hasQueuedSave = true
                return false
            }
            isSaving = true
            hasQueuedSave = false
            return true
        }

        /// Captures the latest leave-time payload, then requests the save loop.
        mutating func requestSave(desired next: [String]?) -> Bool {
            pendingDesired = next
            return requestSave()
        }

        /// Call after a write or unchanged skip. Returns true to continue with the latest desired value.
        mutating func finishAttempt(persisted next: [String]?) -> Bool {
            persisted = next
            if hasQueuedSave {
                hasQueuedSave = false
                return true
            }
            isSaving = false
            return false
        }

        mutating func fail() {
            hasQueuedSave = false
            isSaving = false
        }
    }

    enum PiToolsSavePayload: Equatable {
        /// Tools never loaded; do not PUT.
        case skip
        /// PUT this defaultTools value. `nil` writes JSON null (Pi defaults).
        case write([String]?)
    }

    /// PUT body for Pi Tools. Back (isPresented true→false) and post-load
    /// checkbox/mode changes both save the captured selection, not later view state.
    static func piToolsSavePayload(
        leaveHasLoadedTools: Bool,
        leaveMode: AgentToolSelectionMode,
        leaveSelectedNames: Set<String>,
        leaveOptionalNames: Set<String>,
        laterHasLoadedTools _: Bool,
        laterMode _: AgentToolSelectionMode,
        laterSelectedNames _: Set<String>,
        builtInTools: [ServerToolSummary],
        optionalTools: [ServerToolSummary],
        pickerWasPresented: Bool,
        pickerIsPresented: Bool,
        selectionChangedAfterLoad: Bool,
        isApplyingLoadedTools: Bool = false,
        namesChanged: Bool = false
    ) -> PiToolsSavePayload {
        guard leaveHasLoadedTools else { return .skip }
        // GET/revert binding writes are not a user selection change.
        guard !isApplyingLoadedTools else { return .skip }
        // inherit→exact sets names then mode; names onChange must not PUT null.
        if namesChanged && leaveMode == .inherit { return .skip }
        let dismissedPicker = pickerWasPresented && !pickerIsPresented
        guard dismissedPicker || selectionChangedAfterLoad else { return .skip }
        return .write(piDefaultTools(
            mode: leaveMode,
            selectedNames: leaveSelectedNames,
            optionalNames: leaveOptionalNames,
            builtInTools: builtInTools,
            optionalTools: optionalTools
        ))
    }

    struct PiToolsSelection: Equatable {
        let mode: AgentToolSelectionMode
        let builtInNames: Set<String>
        /// Turned-on tools that Pi extensions register off, such as `codemode`.
        let optionalNames: Set<String>
    }

    /// Reads Pi's `defaultTools` the way Pi resolves it: plain names replace the standard
    /// tools, then `+name` / `-name` apply in order. A modifier-only list that leaves the
    /// built-ins standard, like Pi's documented `["+codemode"]`, stays on Pi defaults.
    static func piToolsSelection(
        defaultTools: [String]?,
        builtInTools: [ServerToolSummary],
        optionalTools: [ServerToolSummary]
    ) -> PiToolsSelection {
        let standard = builtInTools.filter { $0.defaultEnabled == true }.map(\.name)
        guard let defaultTools else {
            return PiToolsSelection(mode: .inherit, builtInNames: Set(standard), optionalNames: [])
        }
        let plain = defaultTools.filter { !isPiToolModifier($0) }
        let modifiesStandard = plain.isEmpty && !defaultTools.isEmpty
        var resolved = modifiesStandard ? standard : plain
        for entry in defaultTools where isPiToolModifier(entry) {
            let name = String(entry.dropFirst())
            if entry.hasPrefix("+") {
                if !name.isEmpty, !resolved.contains(name) { resolved.append(name) }
            } else if let index = resolved.firstIndex(of: name) {
                resolved.remove(at: index)
            }
        }
        let resolvedSet = Set(resolved)
        let builtInNames = resolvedSet.intersection(builtInTools.map(\.name))
        return PiToolsSelection(
            mode: modifiesStandard && builtInNames == Set(standard) ? .inherit : .exact,
            builtInNames: builtInNames,
            optionalNames: resolvedSet.intersection(optionalTools.map(\.name))
        )
    }

    /// `defaultTools` for a Pi Tools selection. On Pi defaults, optional tools are written as
    /// `+name` so the standard built-ins keep following Pi.
    static func piDefaultTools(
        mode: AgentToolSelectionMode,
        selectedNames: Set<String>,
        optionalNames: Set<String>,
        builtInTools: [ServerToolSummary],
        optionalTools: [ServerToolSummary]
    ) -> [String]? {
        let optional = optionalTools.map(\.name).filter { optionalNames.contains($0) }
        guard mode == .exact else {
            return optional.isEmpty ? nil : optional.map { "+\($0)" }
        }
        return piExactToolNames(selectedNames: selectedNames, builtInTools: builtInTools) + optional
    }

    private static func isPiToolModifier(_ entry: String) -> Bool {
        entry.hasPrefix("+") || entry.hasPrefix("-")
    }

    /// Skip replacing the in-memory selection while a write is in flight or the picker is open.
    /// PUT failure still reverts visible selection, including while the picker is presented.
    static func shouldApplyLoadedPiTools(
        hasLoadedTools: Bool,
        isSaving: Bool,
        pickerIsPresented: Bool,
        isRevertingAfterFailure: Bool = false
    ) -> Bool {
        if isRevertingAfterFailure { return true }
        return !hasLoadedTools || (!isSaving && !pickerIsPresented)
    }

    static func piToolsSummary(defaultTools: [String]?) -> String {
        guard let defaultTools else { return piStandardToolsSummary }
        if defaultTools.isEmpty { return "None" }
        if defaultTools.allSatisfy(isPiToolModifier) {
            return ([piStandardToolsSummary] + defaultTools).joined(separator: " ")
        }
        return defaultTools.joined(separator: ", ")
    }

    static func piExactToolNames(
        selectedNames: Set<String>,
        builtInTools: [ServerToolSummary]
    ) -> [String] {
        builtInTools.map(\.name).filter { selectedNames.contains($0) }
    }
}
