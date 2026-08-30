import Foundation
import Testing
@testable import Oppi

@Suite("Thinking fold policy")
struct ThinkingFoldPolicyTests {
    @Test func collapsedMaxHeightMatchesIOSBubbleCap() {
        #expect(ThinkingFoldPolicy.collapsedMaxHeight == 200)
    }

    @Test func paintedHeightAtCapDoesNotOverflow() {
        #expect(!ThinkingFoldPolicy.overflowsCollapsedCap(paintedHeight: 0))
        #expect(!ThinkingFoldPolicy.overflowsCollapsedCap(paintedHeight: ThinkingFoldPolicy.collapsedMaxHeight))
    }

    @Test func paintedHeightAboveCapOverflows() {
        #expect(ThinkingFoldPolicy.overflowsCollapsedCap(paintedHeight: 200.5))
        #expect(ThinkingFoldPolicy.overflowsCollapsedCap(paintedHeight: 400))
    }

    @Test func policyLivesNextToMacLayoutNotOppiCore() throws {
        let appleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreURL = appleRoot.appending(path: "OppiCore/Runtime/ThinkingFoldPolicy.swift")
        let macURL = appleRoot.appending(path: "OppiMac/Views/MacSessionTimelineViews.swift")
        let macSource = try String(contentsOf: macURL, encoding: .utf8)

        #expect(!FileManager.default.fileExists(atPath: coreURL.path))
        #expect(macSource.contains("enum ThinkingFoldPolicy {"))
        #expect(macSource.contains("private struct ThinkingFoldLayout: Layout {"))
    }
}
