/// Usage tab range. The raw value is the `/server/stats?range=` wire value.
enum UsageRange: String, CaseIterable, Sendable {
    case week = "7"
    case month = "30"
    case quarter = "90"
    case year = "365"
    case all

    var label: String {
        switch self {
        case .week: "7d"
        case .month: "30d"
        case .quarter: "90d"
        case .year: "1y"
        case .all: "All"
        }
    }
}

/// Pure logic for multi-server selection, extracted for testability.
enum ServerSelection {
    static func resolve(selectedId: String?, from servers: [PairedServer]) -> PairedServer? {
        if let selectedId, let match = servers.first(where: { $0.id == selectedId }) { return match }
        return servers.first
    }

    /// Opened host jobs follow the pill's active host. Frozen route IDs are a fallback.
    static func resolveVisible(
        activeId: String?,
        frozenId: String?,
        from servers: [PairedServer]
    ) -> PairedServer? {
        resolve(selectedId: activeId ?? frozenId, from: servers)
    }

    static func metadataTaskIdentity(selectedId: String?) -> String { selectedId ?? "" }
    static func taskIdentity(selectedId: String?, range: UsageRange) -> String {
        "\(selectedId ?? "")-\(range.rawValue)"
    }

    /// Apply an in-flight host load only while that host is still visible.
    /// Cancellation must not surface as a load failure on the next host.
    static func shouldApplyHostResult(
        requestedId: String,
        visibleId: String?,
        error: Error? = nil
    ) -> Bool {
        if error is CancellationError { return false }
        return requestedId == visibleId
    }
}
