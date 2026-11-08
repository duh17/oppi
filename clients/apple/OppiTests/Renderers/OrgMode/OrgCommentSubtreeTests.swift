import Testing
@testable import Oppi

/// Org leaves a `COMMENT` heading and everything under it out of the rendered
/// document; Source mode shows the file as written.
@Suite("Org COMMENT subtree")
struct OrgCommentSubtreeTests {
    private func markdown(_ source: String) -> String {
        DocumentRenderPipeline.orgToMarkdown(source)
    }

    @Test func subtreeEndsAtTheNextSameLevelHeading() {
        let out = markdown("""
        * Kept before
        before body
        * COMMENT Hidden
        hidden body
        ** Hidden child
        child body
        * Kept after
        after body
        """)
        #expect(out.contains("Kept before") && out.contains("before body"))
        #expect(out.contains("Kept after") && out.contains("after body"))
        #expect(!out.contains("Hidden") && !out.contains("hidden body") && !out.contains("child body"))
    }

    @Test func subtreeEndsAtAHigherLevelHeadingButNotADeeperOne() {
        let out = markdown("""
        * Parent
        ** COMMENT Hidden
        hidden body
        *** Deeper
        deeper body
        ** Sibling
        sibling body
        """)
        #expect(out.contains("Parent") && out.contains("Sibling") && out.contains("sibling body"))
        #expect(!out.contains("Hidden") && !out.contains("deeper body"))
    }

    @Test func commentAfterATodoStateAndPriorityHides() {
        let out = markdown("* TODO [#A] COMMENT Hidden\nbody\n* Shown")
        #expect(!out.contains("Hidden") && !out.contains("body"))
        #expect(out.contains("Shown"))
    }

    @Test func onlyTheKeywordWordHides() {
        let out = markdown("* COMMENTARY stays\ntext\n* A COMMENT in the middle\nmore")
        #expect(out.contains("COMMENTARY stays") && out.contains("text"))
        #expect(out.contains("A COMMENT in the middle") && out.contains("more"))
    }
}
