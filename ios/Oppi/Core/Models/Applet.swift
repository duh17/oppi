import Foundation

/// Applet model matching server's `Applet` type.
///
/// Server sends timestamps as Unix milliseconds (not ISO 8601).
struct Applet: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let workspaceId: String
    var title: String
    var description: String?
    var currentVersion: Int
    var tags: [String]?
    let createdAt: Date
    var updatedAt: Date
}

extension Applet: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, workspaceId, title, description, currentVersion, tags, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        currentVersion = try c.decode(Int.self, forKey: .currentVersion)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)

        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        let updatedMs = try c.decode(Double.self, forKey: .updatedAt)
        updatedAt = Date(timeIntervalSince1970: updatedMs / 1000)
    }
}

/// Applet version metadata (no HTML content).
struct AppletVersion: Identifiable, Sendable, Equatable {
    var id: Int { version }
    let version: Int
    let appletId: String
    var sessionId: String?
    var toolCallId: String?
    let size: Int
    var changeNote: String?
    let createdAt: Date
}

extension AppletVersion: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version, appletId, sessionId, toolCallId, size, changeNote, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        appletId = try c.decode(String.self, forKey: .appletId)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        size = try c.decode(Int.self, forKey: .size)
        changeNote = try c.decodeIfPresent(String.self, forKey: .changeNote)

        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: createdMs / 1000)
    }
}

/// Version with HTML content included (from GET /versions/:v).
struct AppletVersionWithHTML: Sendable, Equatable {
    let version: AppletVersion
    let html: String
}

extension AppletVersionWithHTML: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version, html, appletId, sessionId, toolCallId, size, changeNote, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        let v = try c.decode(Int.self, forKey: .version)
        let appletId = try c.decode(String.self, forKey: .appletId)
        let sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        let toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        let size = try c.decode(Int.self, forKey: .size)
        let changeNote = try c.decodeIfPresent(String.self, forKey: .changeNote)
        let createdMs = try c.decode(Double.self, forKey: .createdAt)
        let createdAt = Date(timeIntervalSince1970: createdMs / 1000)

        version = AppletVersion(
            version: v,
            appletId: appletId,
            sessionId: sessionId,
            toolCallId: toolCallId,
            size: size,
            changeNote: changeNote,
            createdAt: createdAt
        )

        html = try c.decode(String.self, forKey: .html)
    }
}
