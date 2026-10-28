import Foundation

// The vocabulary of the Agent editor's selection pages and Pi's Tools page.

enum AgentToolSelectionMode: String, CaseIterable {
    case inherit
    case exact
    case existingPolicy

    var title: String {
        switch self {
        case .inherit: "Pi defaults"
        case .exact: "Choose tools"
        case .existingPolicy: "Existing policy"
        }
    }
}

struct AgentExtensionToolGroup: Identifiable {
    let id: String
    let name: String
    let tools: [ServerToolSummary]
}

enum AgentResourceCatalogState: Equatable {
    case unavailable
    case loading
    case neverLoaded
    case failed
    case cachedOffline
    case empty
    case content

    static func resolve(
        hasLoaded: Bool,
        isSyncing: Bool,
        lastSyncFailed: Bool,
        hasRows: Bool
    ) -> Self {
        guard hasLoaded else {
            if isSyncing { return .loading }
            return lastSyncFailed ? .failed : .neverLoaded
        }
        if lastSyncFailed { return .cachedOffline }
        return hasRows ? .content : .empty
    }

    static func isExactSelectionSaveAllowed(
        initialSelectionWasInherited: Bool,
        catalogState: Self
    ) -> Bool {
        !initialSelectionWasInherited || [.empty, .content, .cachedOffline].contains(catalogState)
    }

    func statusMessage(for resourceName: String) -> String? {
        switch self {
        case .unavailable:
            return "Connect to load the server's \(resourceName) catalog."
        case .loading:
            return "Loading \(resourceName.lowercased())…"
        case .neverLoaded:
            return "The \(resourceName) catalog has not loaded yet."
        case .failed:
            return "Could not load the \(resourceName.lowercased()) catalog. Existing selections are kept."
        case .cachedOffline:
            return "Showing cached \(resourceName.lowercased()) settings. Pull to retry."
        case .empty, .content:
            return nil
        }
    }
}

extension String {
    var managementNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
