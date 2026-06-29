import Foundation

/// Full skill detail from `GET /skills/:name`.
///
/// Extends the basic ``SkillInfo`` with the raw SKILL.md content
/// and a flat file tree of the skill directory.
struct SkillDetail: Codable, Sendable {
    let skill: SkillInfo
    /// Raw SKILL.md content (markdown).
    let content: String
    /// Relative file paths in the skill directory.
    let files: [String]
}
