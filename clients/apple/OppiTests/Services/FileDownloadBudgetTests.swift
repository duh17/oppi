import Foundation
import Testing
@testable import Oppi

@Suite("File download budget")
struct FileDownloadBudgetTests {
    @Test func downloadsUpToTheLimitAndRefusesOneByteMore() {
        let limit = FileDownloadBudget.maxBytes
        #expect(FileDownloadBudget.refusal(byteCount: limit, availableBytes: nil) == nil)
        #expect(FileDownloadBudget.refusal(byteCount: limit + 1, availableBytes: nil) == .overLimit(byteCount: limit + 1))
        // Over the limit wins over space: more room does not make it fit.
        #expect(FileDownloadBudget.refusal(byteCount: limit + 1, availableBytes: .max) == .overLimit(byteCount: limit + 1))
    }

    @Test func needsRoomForTheDownloadAndOneCopyOfIt() {
        let size: Int64 = 300_000_000
        #expect(FileDownloadBudget.refusal(byteCount: size, availableBytes: size * 2) == nil)
        #expect(
            FileDownloadBudget.refusal(byteCount: size, availableBytes: size * 2 - 1)
                == .notEnoughSpace(neededBytes: size * 2, availableBytes: size * 2 - 1)
        )
    }

    @Test func anUnknownSizeStarts() {
        #expect(FileDownloadBudget.refusal(byteCount: nil, availableBytes: 0) == nil)
    }
}
