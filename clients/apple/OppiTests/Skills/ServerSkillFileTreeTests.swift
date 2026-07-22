import Testing
@testable import Oppi

@Suite("Server skill file tree")
struct ServerSkillFileTreeTests {
    @Test func buildsDirectoriesBeforeFilesAndPreservesRelativePaths() throws {
        let tree = ServerSkillFileTree.build(paths: [
            "SKILL.md",
            "references/review.md",
            "references/nested/checklist.md",
            "scripts/validate.ts",
        ])

        #expect(tree.map(\.name) == ["references", "scripts", "SKILL.md"])
        let references = try #require(tree.first { $0.name == "references" })
        #expect(references.kind == .directory)
        #expect(references.children.map(\.name) == ["nested", "review.md"])
        #expect(references.children.last?.path == "references/review.md")
        #expect(references.children.first?.children.first?.path == "references/nested/checklist.md")
    }

    @Test func removesDuplicatesAndRejectsTraversalComponents() {
        let tree = ServerSkillFileTree.build(paths: [
            "SKILL.md",
            "SKILL.md",
            "../secret.md",
            "references/./hidden.md",
            "/absolute.md",
        ])

        #expect(tree.map(\.path) == ["SKILL.md"])
    }
}
