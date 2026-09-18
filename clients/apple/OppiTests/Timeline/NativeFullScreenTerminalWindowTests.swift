import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Native full-screen terminal sidecar windows")
struct NativeFullScreenTerminalWindowTests {
    @Test func terminalBodyPaintsFirstWindowWithoutWaitingForTheRest() async throws {
        let first = "\u{1B}[32m" + String(repeating: "green line\n", count: 20_000)
        let rest = "still green without a local SGR prefix\n"
        #expect(first.utf8.count > 128 * 1024)

        let body = NativeFullScreenTerminalBody(
            content: first,
            command: "bash",
            stream: nil,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil
        )
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        body.frame = host.bounds
        host.addSubview(body)
        host.layoutIfNeeded()

        let firstPaint = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            return diagnostics.retainedSourceUTF8Count == first.utf8.count
                && diagnostics.chunkCount > 1
                && diagnostics.mountedUTF16Count > 0
        }
        #expect(firstPaint)
        let before = try #require(body.virtualizationDiagnosticsForTesting())
        #expect(before.retainedSourceUTF8Count == first.utf8.count)
        #expect(before.retainedSourceUTF8Count < (first + rest).utf8.count)
        let trailing = try #require(body.virtualizedTrailingSGRForTesting())
        #expect(!trailing.isEmpty)
        let firstChunkCount = before.chunkCount

        body.appendOutputWindow(rest)
        let appended = await waitForMainActorCondition(timeout: .seconds(3)) {
            host.layoutIfNeeded()
            guard let diagnostics = body.virtualizationDiagnosticsForTesting() else { return false }
            return diagnostics.retainedSourceUTF8Count == (first + rest).utf8.count
                && diagnostics.chunkCount > firstChunkCount
        }
        #expect(appended)
        let leading = try #require(body.virtualizedChunkLeadingSGRForTesting())
        #expect(leading.count > firstChunkCount)
        #expect(leading[firstChunkCount] == trailing)
        #expect(body.virtualizedTrailingSGRForTesting() == trailing)
    }
}
