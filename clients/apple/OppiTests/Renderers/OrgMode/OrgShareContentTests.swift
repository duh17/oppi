import Testing
@testable import Oppi

@Suite("Org share content")
struct OrgShareContentTests {
    @Test func orgShareKeepsTheDocumentPathForLinkResolution() {
        let content = FileShareService.ShareableContent.fromText(
            "* Target\n:PROPERTIES:\n:ID: abc\n:END:\nSee [[id:abc][here]].",
            filePath: "/workspace/notes/plan.org"
        )
        guard case .orgMode(let source, _, let path) = content else {
            Issue.record("Expected org content, got \(content)")
            return
        }
        #expect(path == "/workspace/notes/plan.org")
        // An in-document link resolves to the document's name only with its path.
        #expect(DocumentRenderPipeline.orgToMarkdown(source, documentPath: path).contains("(plan.org)"))
        #expect(content.originalFileName == "plan.org")
        guard case .orgMode(_, let fileName, _) = content else { return }
        #expect(fileName == "plan.org")
    }
}
