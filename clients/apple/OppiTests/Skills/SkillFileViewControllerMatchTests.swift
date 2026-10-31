import Foundation
import Testing
@testable import Oppi

/// The chat's Skill reader decides editability by matching the Skill it read
/// against the server's catalog. The two name a Skill differently — the catalog
/// hashes the Skill's `SKILL.md` after resolving it, the detail reports the
/// directory Pi named (a symlink for most installed Skills) — so the match is on
/// the catalog's own id.
@Suite("Chat skill file edit match")
struct SkillFileViewControllerMatchTests {
    @MainActor private func summary(
        id: String,
        path: String?,
        editable: Bool = true
    ) -> ServerSkillSummary {
        ServerSkillSummary(
            id: id,
            name: "release",
            description: "Review release readiness.",
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/skills"),
            path: path,
            state: .enabled,
            loadError: nil,
            warnings: [],
            editable: editable
        )
    }

    @MainActor private func detail(catalogId: String?, path: String) -> SkillDetail {
        SkillDetail(
            skill: SkillInfo(
                name: "release",
                description: "Review release readiness.",
                path: path,
                builtIn: false,
                enabled: true,
                catalogId: catalogId
            ),
            content: "# Release",
            files: ["SKILL.md"]
        )
    }

    /// The catalog's path is the realpath of `<dir>/SKILL.md`; the detail's is the
    /// symlinked directory. The ids still agree, so the pencil appears.
    @Test @MainActor func matchesACatalogSkillByItsIdDespiteASymlinkedDirectory() throws {
        let target = "/Users/me/workspace/agent-skills/release"
        let link = "/Users/me/.pi/agent/skills/release"
        let match = SkillFileViewController.editableFile(
            detail: detail(catalogId: "skill_abc", path: link),
            filePath: "SKILL.md",
            skills: [summary(id: "skill_abc", path: "\(target)/SKILL.md")]
        )

        let editable = try #require(match)
        #expect(editable.summary.id == "skill_abc")
        #expect(editable.hostPath == "\(target)/SKILL.md")
        #expect(editable.skillFile == SkillFileEditTarget(skillId: "skill_abc", path: "SKILL.md"))
    }

    /// A detail without an id names no catalog entry, so there is no pencil —
    /// even when a path happens to look the same.
    @Test @MainActor func aDetailWithoutACatalogIdMatchesNothing() {
        let path = "/Users/me/.pi/agent/skills/release"
        let match = SkillFileViewController.editableFile(
            detail: detail(catalogId: nil, path: path),
            filePath: "SKILL.md",
            skills: [summary(id: "skill_abc", path: "\(path)/SKILL.md")]
        )

        #expect(match == nil)
    }

    /// The id names the Skill; `editable` is still the catalog's to say, so a
    /// package Skill's own file has no pencil.
    @Test @MainActor func aReadOnlyCatalogSkillOffersNoEditor() {
        let path = "/Users/me/.pi/agent/skills/release"
        let match = SkillFileViewController.editableFile(
            detail: detail(catalogId: "skill_abc", path: path),
            filePath: "SKILL.md",
            skills: [summary(id: "skill_abc", path: "\(path)/SKILL.md", editable: false)]
        )

        #expect(match == nil)
    }

    /// The wire carries the catalog's id as `id`; the model keeps it apart from
    /// the Skill's own `id`, which is its name.
    @Test func decodesTheCatalogIdFromTheDetailJSON() throws {
        let json = """
        {"skill":{"name":"release","description":"Review release readiness.",\
        "path":"/Users/me/.pi/agent/skills/release","id":"skill_abc"},"content":"# Release","files":[]}
        """
        let detail = try JSONDecoder().decode(SkillDetail.self, from: Data(json.utf8))

        #expect(detail.skill.id == "release")
        #expect(detail.skill.catalogId == "skill_abc")
    }
}
