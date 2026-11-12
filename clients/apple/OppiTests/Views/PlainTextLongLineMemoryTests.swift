import Testing
import UIKit
@testable import Oppi

/// A text file that is one long line (a log or minified data saved as .txt)
/// opens without holding hundreds of megabytes. TextKit 2 drew the whole line
/// as one view about 60,000 points tall: a 180 KB line held over 200 MB while
/// open, and over 400 MB once scrolled to the end.
@MainActor
@Suite("Plain text long line memory", .serialized)
struct PlainTextLongLineMemoryTests {
    nonisolated private static let oneLine = String(
        repeating: "The quick brown fox jumps over the lazy dog near the riverbank. ",
        count: 2_800
    )

    @Test("a 180 KB single-line text file stays under 100 MB of growth while open and scrolled", .timeLimit(.minutes(1)))
    func singleLineStaysBounded() async throws {
        let before = try #require(AppDiagnosticsService.currentFootprintMB())
        let controller = FullScreenCodeViewController(
            content: .plainText(content: Self.oneLine, filePath: "line.txt"),
            presentationMode: .embedded(onDismiss: {})
        )
        // A window in the scene, so Core Animation commits and draws the text.
        let window = makeSceneWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            hideTestWindow(window)
            window.rootViewController = nil
        }
        controller.view.frame = window.bounds
        var found: UITextView?
        let mounted = await waitForMainActorCondition(timeout: .seconds(10)) {
            window.layoutIfNeeded()
            found = Self.textView(in: window)
            return found != nil
        }
        try #require(mounted, "the reader showed the text")
        let textView = try #require(found)
        try #require(textView.text == Self.oneLine)

        var grown = 0
        for fraction in [0.0, 0.5, 1.0] {
            textView.contentOffset.y = max(0, textView.contentSize.height - textView.bounds.height) * fraction
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(50))
                window.layoutIfNeeded()
            }
            grown = max(grown, (AppDiagnosticsService.currentFootprintMB() ?? before) - before)
        }
        #expect(textView.contentSize.height > 20_000, "the whole line wraps into the text view")
        #expect(grown < 100, "footprint grew \(grown) MB")
    }

    private static func textView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isScrollEnabled { return textView }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
