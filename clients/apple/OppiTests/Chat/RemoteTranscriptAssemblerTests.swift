import Testing
@testable import Oppi

@Suite("RemoteTranscriptAssembler")
struct RemoteTranscriptAssemblerTests {
    @Test func trimsFillerAndSpacingDuringNormalization() {
        let text = RemoteTranscriptAssembler.normalizedChunkText("  um   hello   ,   world  uh ")
        #expect(text == "hello, world")
    }

    @Test func dropsLeadingAcknowledgementFromFollowOnChunk() {
        let merged = RemoteTranscriptAssembler.merge(
            existing: "We should ship this today.",
            incoming: "okay let's do it"
        )
        #expect(merged == "We should ship this today. let's do it")
    }

    @Test func suppressesStandaloneAcknowledgementChunkAfterSentenceEnd() {
        let merged = RemoteTranscriptAssembler.merge(
            existing: "We should ship this today.",
            incoming: "okay"
        )
        #expect(merged == "We should ship this today.")
    }

    @Test func removesOverlappingPrefixWhenMergingChunks() {
        let merged = RemoteTranscriptAssembler.merge(
            existing: "this is a good plan",
            incoming: "a good plan for launch"
        )
        #expect(merged == "this is a good plan for launch")
    }

    @Test func allowsShortAcknowledgementWhenNotSentenceTerminated() {
        let merged = RemoteTranscriptAssembler.merge(
            existing: "yeah maybe",
            incoming: "okay let's do it"
        )
        #expect(merged == "yeah maybe okay let's do it")
    }
}
