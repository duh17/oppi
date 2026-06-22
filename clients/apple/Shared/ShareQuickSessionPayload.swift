import Foundation

/// Payload written by the iOS Share extension and consumed by the main app.
///
/// The extension cannot pass large files through a URL, so it copies shared
/// items into the app-group container and stores this small manifest in shared
/// defaults. The main app turns the files into normal composer attachments.
struct ShareQuickSessionPayload: Codable, Equatable, Sendable {
    struct SharedFile: Codable, Equatable, Sendable {
        let name: String
        let relativePath: String
        let mimeType: String
    }

    let id: String
    let text: String?
    let files: [SharedFile]
    let createdAt: Date

    static let defaultsPrefix = "quickSession.sharePayload."
    static let pendingPayloadIdKey = "quickSession.sharePayload.pendingId"
    static let inboxDirectoryName = "QuickSessionShareInbox"

    static func defaultsKey(for id: String) -> String {
        defaultsPrefix + id
    }

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier)
    }

    static var inboxURL: URL? {
        appGroupContainerURL?.appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    static func payloadDirectoryURL(id: String) -> URL? {
        inboxURL?.appendingPathComponent(id, isDirectory: true)
    }

    static func store(_ payload: ShareQuickSessionPayload) throws {
        let data = try JSONEncoder().encode(payload)
        let defaults = SharedConstants.sharedDefaults
        defaults.set(data, forKey: defaultsKey(for: payload.id))
        defaults.set(payload.id, forKey: pendingPayloadIdKey)
        defaults.set(true, forKey: SharedConstants.quickSessionPendingKey)
    }

    static func load(id: String) -> ShareQuickSessionPayload? {
        guard let data = SharedConstants.sharedDefaults.data(forKey: defaultsKey(for: id)) else {
            return nil
        }
        return try? JSONDecoder().decode(ShareQuickSessionPayload.self, from: data)
    }

    static func consume(id: String) -> ShareQuickSessionPayload? {
        let defaults = SharedConstants.sharedDefaults
        let payload = load(id: id)
        defaults.removeObject(forKey: defaultsKey(for: id))
        if defaults.string(forKey: pendingPayloadIdKey) == id {
            defaults.removeObject(forKey: pendingPayloadIdKey)
        }
        defaults.removeObject(forKey: SharedConstants.quickSessionPendingKey)
        return payload
    }

    static func removePayloadFiles(id: String) {
        guard let url = payloadDirectoryURL(id: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
