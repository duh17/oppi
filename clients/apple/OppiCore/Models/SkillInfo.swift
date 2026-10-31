import Foundation

/// Skill metadata from the host's skill pool.
///
/// Skills are discovered by scanning `~/.pi/agent/skills/` on the server.
struct SkillInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let path: String
    /// true for skills shipped with the server; false for user-created skills.
    /// Defaults to true when absent from JSON.
    let builtIn: Bool
    /// Whether Pi settings currently load this skill for the requested cwd.
    let enabled: Bool
    /// The server catalog's id for this Skill (`GET /server/resources/skills`),
    /// when the server sends one. `path` is the directory as Pi names it, which
    /// for a symlinked Skill is not where the catalog found it, so a client that
    /// needs "this is that catalog entry" compares this id.
    let catalogId: String?

    init(
        name: String,
        description: String,
        path: String,
        builtIn: Bool = true,
        enabled: Bool = true,
        catalogId: String? = nil
    ) {
        self.name = name
        self.description = description
        self.path = path
        self.builtIn = builtIn
        self.enabled = enabled
        self.catalogId = catalogId
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, path, builtIn, enabled
        /// The catalog's id on the wire; `id` here is the Skill's name.
        case catalogId = "id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        path = try c.decode(String.self, forKey: .path)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
    }

    var id: String { name }
}
