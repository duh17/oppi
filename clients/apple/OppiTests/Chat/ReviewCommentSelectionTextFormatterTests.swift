import Testing
@testable import Oppi

@Suite("Review comment selection text formatting")
struct ReviewCommentSelectionTextFormatterTests {
    @Test func normalizesLineEndingsAndTrimsOuterWhitespace() {
        let result = ReviewCommentSelectionTextFormatter.normalizedSelectedText("  first\r\nsecond\rthird  \n")
        #expect(result == "first\nsecond\nthird")
    }

    @Test func preservesInternalWhitespace() {
        let result = ReviewCommentSelectionTextFormatter.normalizedSelectedText("let  value = 42")
        #expect(result == "let  value = 42")
    }
}
