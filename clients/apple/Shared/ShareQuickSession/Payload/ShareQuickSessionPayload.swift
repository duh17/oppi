import Foundation

/// In-memory draft assembled by the iOS share extension.
///
/// Shared files are copied into the app-group inbox so the extension composer
/// can upload them from stable file URLs without materializing them in memory.
struct ShareQuickSessionPayload: Equatable, Sendable {
    struct SharedFile: Equatable, Sendable {
        let name: String
        let relativePath: String
        let mimeType: String
    }

    let id: String
    let text: String?
    let files: [SharedFile]

    static let inboxDirectoryName = "QuickSessionShareInbox"

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier)
    }

    static var inboxURL: URL? {
        appGroupContainerURL?.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    static func payloadDirectoryURL(id: String) -> URL? {
        inboxURL?.appendingPathComponent(id, isDirectory: true)
    }

    static func removePayloadFiles(id: String) {
        guard let url = payloadDirectoryURL(id: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// What each shared item resolved to, for one share. Item-provider callbacks
/// finish concurrently and in any order; the snapshot keeps the order the items
/// were shared in, so "the first screenshot" stays first. All mutable state is
/// protected by `lock`, which is why this reference can cross callback threads.
final class SharePayloadAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var textParts: [Int: String] = [:]
    private var files: [Int: ShareQuickSessionPayload.SharedFile] = [:]

    func setText(_ value: String, forItemAt index: Int) {
        lock.lock()
        defer { lock.unlock() }
        textParts[index] = value
    }

    func setFile(_ file: ShareQuickSessionPayload.SharedFile, forItemAt index: Int) {
        lock.lock()
        defer { lock.unlock() }
        files[index] = file
    }

    func snapshot() -> (textParts: [String], files: [ShareQuickSessionPayload.SharedFile]) {
        lock.lock()
        defer { lock.unlock() }
        return (
            textParts.sorted { $0.key < $1.key }.map(\.value),
            files.sorted { $0.key < $1.key }.map(\.value)
        )
    }
}
