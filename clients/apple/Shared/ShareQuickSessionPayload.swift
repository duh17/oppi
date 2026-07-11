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
