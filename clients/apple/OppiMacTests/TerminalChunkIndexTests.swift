import Foundation
import Testing
@testable import Oppi

@Suite("Terminal wrapped chunk index")
struct TerminalChunkIndexTests {
    @Test func wrappedChunksPreserveTextAndBoundVisualRows() {
        let input = "\u{1B}[32m" + (0..<12_000).map {
            String(format: "%05d ", $0) + String(repeating: "x", count: 160) + "\n"
        }.joined() + "\u{1B}[0m"
        let index = ANSIParser.TerminalChunkIndex.build(from: input, wrappedColumns: 46)
        #expect(index.chunks.count >= 750)
        #expect(index.chunks.map { ANSIParser.strip($0.rawText) }.joined() == ANSIParser.strip(input))
        #expect(index.displayedUTF16Count == 12_000 * 167)
        for chunk in index.chunks {
            #expect(chunk.rawByteCount <= 32 * 1024)
            #expect(chunk.lineColumnCounts.reduce(0) { $0 + max(1, ($1 + 45) / 46) } <= 64)
        }
        #expect(index.chunks[1].leadingSGR == "\u{1B}[32m")
        #expect(index.chunks[1].displayedStartLine == 17)
    }
}
