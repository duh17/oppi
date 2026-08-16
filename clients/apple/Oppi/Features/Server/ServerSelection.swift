/// Pure logic for multi-server selection, extracted for testability.
enum ServerSelection {
    static func resolve(selectedId: String?, from servers: [PairedServer]) -> PairedServer? {
        if let selectedId, let match = servers.first(where: { $0.id == selectedId }) { return match }
        return servers.first
    }

    static func metadataTaskIdentity(selectedId: String?) -> String { selectedId ?? "" }
    static func taskIdentity(selectedId: String?, range: Int) -> String { "\(selectedId ?? "")-\(range)" }
}
