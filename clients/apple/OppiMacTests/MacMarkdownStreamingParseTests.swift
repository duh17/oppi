import Testing
@testable import Oppi

@Suite("Mac markdown streaming parse")
struct MacMarkdownStreamingParseTests {
    @Test func growingStringsUseTailOnlyAfterFirstParseWhenPrefixIsStable() {
        var parser = CommonMarkStreamingParser()
        let first = """
        Finalized paragraph.

        Streaming tail
        """
        let firstResult = MacMarkdownPaintDispatch.parseStreaming(first, parser: &parser)
        #expect(firstResult.strategy == .full)
        #expect(firstResult.blocks == MacMarkdownPaintDispatch.parsedBlocks(from: first))

        let second = first + " grows."
        let secondResult = MacMarkdownPaintDispatch.parseStreaming(second, parser: &parser)
        #expect(secondResult.strategy == .tailOnly)
        #expect(secondResult.blocks == MacMarkdownPaintDispatch.parsedBlocks(from: second))
    }

    @Test func streamingParseRewritesWikiLinksWithWorkspaceContext() throws {
        var parser = CommonMarkStreamingParser()
        let result = MacMarkdownPaintDispatch.parseStreaming(
            "![[demo.mp4]]",
            parser: &parser,
            workspaceID: "ws-mac",
            sessionID: "sess-mac"
        )
        let kinds = MacMarkdownPaintDispatch.kinds(
            from: result.blocks,
            workspaceID: "ws-mac",
            sessionID: "sess-mac"
        )
        let kind = try #require(kinds.first { if case .video = $0 { return true }; return false })
        guard case .video(let embed) = kind else {
            Issue.record("Expected wiki video embed after streaming parse, got \(kinds)")
            return
        }
        #expect(embed.reference.workspaceID == "ws-mac")
        #expect(embed.reference.sourceSessionID == "sess-mac")
        #expect(result.strategy == .full)
    }

    @MainActor
    @Test func storeReusesParserForTheSameChatItemID() {
        let store = MacMarkdownStreamingParserStore()
        let first = """
        Finalized paragraph.

        Streaming tail
        """
        #expect(store.parse(itemID: "msg-1", markdown: first).strategy == .full)
        #expect(store.parse(itemID: "msg-1", markdown: first + " grows.").strategy == .tailOnly)
        #expect(store.parse(itemID: "msg-2", markdown: first + " grows.").strategy == .full)
    }

    @MainActor
    @Test func retainDropsParsersForIDsThatLeft() {
        let store = MacMarkdownStreamingParserStore()
        let first = """
        Finalized paragraph.

        Streaming tail
        """
        #expect(store.parse(itemID: "keep", markdown: first).strategy == .full)
        #expect(store.parse(itemID: "drop", markdown: first).strategy == .full)
        store.retain(itemIDs: ["keep"])
        #expect(store.parse(itemID: "keep", markdown: first + " grows.").strategy == .tailOnly)
        #expect(store.parse(itemID: "drop", markdown: first + " grows.").strategy == .full)
        store.retain(itemIDs: [])
        #expect(store.parse(itemID: "keep", markdown: first + " grows again.").strategy == .full)
    }
}
