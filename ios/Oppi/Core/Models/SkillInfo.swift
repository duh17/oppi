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

    init(name: String, description: String, path: String, builtIn: Bool = true) {
        self.name = name
        self.description = description
        self.path = path
        self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        path = try c.decode(String.self, forKey: .path)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
    }

    var id: String { name }

    /// Whether this skill can be edited from the iOS app.
    var isEditable: Bool { !builtIn }
}
