import Foundation

/// Skill metadata from the host's skill pool.
///
/// Skills are discovered by scanning `~/.pi/agent/skills/` on the server.
/// The `containerSafe` flag indicates whether the skill can run inside
/// an Apple container (some need host-only binaries like tmux or MLX).
struct SkillInfo: Codable, Identifiable, Sendable, Equatable {
    let name: String
    let description: String
    let containerSafe: Bool
    let hasScripts: Bool
    let path: String

    var id: String { name }
}
