import Testing
@testable import Oppi

@Suite("TextSearchMatch")
struct TextSearchMatchTests {
    @Test func exactSubstringMatchesCaseInsensitively() {
        let result = TextSearchMatch.match(
            query: "session",
            candidate: "read server/src/session-broadcast.ts"
        )

        #expect(result != nil)
        #expect(result?.positions == Array(16..<23))
    }

    @Test func fuzzyCharacterSequenceDoesNotMatch() {
        let result = TextSearchMatch.match(
            query: "session",
            candidate: "**Searching OSLogStore** | I need to use the devdoc command"
        )

        #expect(result == nil)
    }

    @Test func exactPhraseRanksAboveSeparatedTermMatches() {
        let exact = TextSearchMatch.match(
            query: "server logs",
            candidate: "**Evaluating server logs** | JSONL format"
        )
        let separated = TextSearchMatch.match(
            query: "server logs",
            candidate: "server process emitted JSONL logs"
        )

        #expect(exact != nil)
        #expect(separated != nil)
        if let exact, let separated {
            #expect(exact.score > separated.score)
        }
    }

    @Test func allTermsMustMatchForMultiWordQuery() {
        let match = TextSearchMatch.match(
            query: "server logs",
            candidate: "server process emitted JSONL logs"
        )
        let miss = TextSearchMatch.match(
            query: "server logs",
            candidate: "server route handler"
        )

        #expect(match != nil)
        #expect(miss == nil)
    }

    @Test func exactPrefixRanksAboveLaterSubstring() {
        let prefix = TextSearchMatch.match(query: "session", candidate: "Session search failed")
        let later = TextSearchMatch.match(query: "session", candidate: "read server/src/session-broadcast.ts")

        #expect(prefix != nil)
        #expect(later != nil)
        if let prefix, let later {
            #expect(prefix.score > later.score)
        }
    }

    @Test func searchSortsByScoreAndPreservesEqualScoreOrder() {
        let candidates = [
            "server process emitted JSONL logs",
            "unrelated route handler",
            "**Evaluating server logs** | JSONL format",
            "another server process emitted logs",
        ]

        let results = TextSearchMatch.search(query: "server logs", candidates: candidates, limit: 10)

        #expect(results.map(\.index) == [2, 0, 3])
    }

    @Test func searchRespectsLimit() {
        let candidates = (0..<200).map { "session item \($0)" }

        let results = TextSearchMatch.search(query: "session", candidates: candidates, limit: 5)

        #expect(results.count == 5)
        #expect(results.map(\.index) == [0, 1, 2, 3, 4])
    }
}
