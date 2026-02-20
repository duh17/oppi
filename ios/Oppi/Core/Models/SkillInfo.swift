import Foundation

/// Skill metadata from the host's skill pool.
///
/// Skills are discovered by scanning `~/.pi/agent/skills/` on the server.
/// The `containerSafe` flag is a compatibility hint from the server.
/// `false` typically means the skill depends on local binaries (e.g. tmux/MLX).
struct SkillInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let containerSafe: Bool
    let hasScripts: Bool
    let path: String
    /// true for skills shipped with the server; false for user-created skills.
    /// Defaults to true when missing from JSON (backwards compat with older servers).
    let builtIn: Bool

    init(name: String, description: String, containerSafe: Bool, hasScripts: Bool, path: String, builtIn: Bool = true) {
        self.name = name
        self.description = description
        self.containerSafe = containerSafe
        self.hasScripts = hasScripts
        self.path = path
        self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        containerSafe = try c.decode(Bool.self, forKey: .containerSafe)
        hasScripts = try c.decode(Bool.self, forKey: .hasScripts)
        path = try c.decode(String.self, forKey: .path)
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? true
    }

    var id: String { name }

    /// Whether this skill can be edited from the iOS app.
    var isEditable: Bool { !builtIn }
}
