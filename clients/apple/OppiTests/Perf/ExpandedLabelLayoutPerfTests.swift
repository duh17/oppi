import Testing
import SwiftUI
import UIKit
@testable import Oppi

/// Measures UILabel vs UITextView layout cost for large attributed strings
/// in a viewport-capped scroll view — the exact pattern used by tool row
/// expanded content in the chat timeline.
///
/// The hypothesis: UILabel computes full text layout (CoreText shaping for
/// ALL lines) upfront, while UITextView with TextKit defers layout for
/// off-screen content. For a 300-line file in a 500pt viewport showing
/// ~30 lines, UITextView should be dramatically faster.
@Suite("Expanded Label Layout Perf")
@MainActor
struct ExpandedLabelLayoutPerfTests {

    // MARK: - Fixture

    /// Build a realistic syntax-highlighted attributed string for N lines of Swift.
    private static func highlightedCode(lineCount: Int) -> NSAttributedString {
        let source = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: lineCount)
        return ToolRowTextRenderer.makeCodeAttributedText(
            text: source,
            language: .swift,
            startLine: 1
        )
    }

    private static func measureMs(_ block: () -> Void) -> Int {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        let end = DispatchTime.now().uptimeNanoseconds
        return Int((end &- start) / 1_000_000)
    }

    // MARK: - UILabel Layout

    /// Measure UILabel.sizeThatFits for a large attributed string.
    /// This is what happens during cell sizing in the collection view.
    @Test("UILabel layout 100 lines")
    func labelLayout100() {
        let attributed = Self.highlightedCode(lineCount: 100)
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed

        let ms = Self.measureMs {
            _ = label.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        // Just record — no assertion yet, we're gathering data.
        print("UILabel sizeThatFits 100 lines: \(ms)ms")
        #expect(ms >= 0) // always passes, here for recording
    }

    @Test("UILabel layout 300 lines")
    func labelLayout300() {
        let attributed = Self.highlightedCode(lineCount: 300)
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed

        let ms = Self.measureMs {
            _ = label.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UILabel sizeThatFits 300 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UILabel layout 500 lines")
    func labelLayout500() {
        let attributed = Self.highlightedCode(lineCount: 500)
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed

        let ms = Self.measureMs {
            _ = label.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UILabel sizeThatFits 500 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UILabel layout 1000 lines")
    func labelLayout1000() {
        let attributed = Self.highlightedCode(lineCount: 1000)
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed

        let ms = Self.measureMs {
            _ = label.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UILabel sizeThatFits 1000 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    // MARK: - UITextView Layout (non-scrollable, inside scroll view)

    /// Measure UITextView.sizeThatFits in the same configuration.
    /// UITextView with isScrollEnabled=false should compute full layout
    /// (similar to UILabel). But it might still benefit from TextKit
    /// internal optimizations.
    @Test("UITextView layout 100 lines")
    func textViewLayout100() {
        let attributed = Self.highlightedCode(lineCount: 100)
        let tv = Self.makeTextView()
        tv.attributedText = attributed

        let ms = Self.measureMs {
            _ = tv.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UITextView sizeThatFits 100 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UITextView layout 300 lines")
    func textViewLayout300() {
        let attributed = Self.highlightedCode(lineCount: 300)
        let tv = Self.makeTextView()
        tv.attributedText = attributed

        let ms = Self.measureMs {
            _ = tv.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UITextView sizeThatFits 300 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UITextView layout 500 lines")
    func textViewLayout500() {
        let attributed = Self.highlightedCode(lineCount: 500)
        let tv = Self.makeTextView()
        tv.attributedText = attributed

        let ms = Self.measureMs {
            _ = tv.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UITextView sizeThatFits 500 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UITextView layout 1000 lines")
    func textViewLayout1000() {
        let attributed = Self.highlightedCode(lineCount: 1000)
        let tv = Self.makeTextView()
        tv.attributedText = attributed

        let ms = Self.measureMs {
            _ = tv.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("UITextView sizeThatFits 1000 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    // MARK: - UITextView in viewport (scrollable)

    /// The real win: UITextView with isScrollEnabled=true inside a fixed
    /// viewport. Only visible text gets laid out.
    @Test("UITextView scrollable viewport 300 lines")
    func textViewScrollableViewport300() {
        let attributed = Self.highlightedCode(lineCount: 300)
        let tv = Self.makeScrollableTextView()
        tv.attributedText = attributed

        // Simulate viewport: 500pt tall, text view fills it
        tv.frame = CGRect(x: 0, y: 0, width: 380, height: 500)

        let ms = Self.measureMs {
            tv.layoutIfNeeded()
        }
        print("UITextView scrollable viewport 300 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UITextView scrollable viewport 500 lines")
    func textViewScrollableViewport500() {
        let attributed = Self.highlightedCode(lineCount: 500)
        let tv = Self.makeScrollableTextView()
        tv.attributedText = attributed

        tv.frame = CGRect(x: 0, y: 0, width: 380, height: 500)

        let ms = Self.measureMs {
            tv.layoutIfNeeded()
        }
        print("UITextView scrollable viewport 500 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("UITextView scrollable viewport 1000 lines")
    func textViewScrollableViewport1000() {
        let attributed = Self.highlightedCode(lineCount: 1000)
        let tv = Self.makeScrollableTextView()
        tv.attributedText = attributed

        tv.frame = CGRect(x: 0, y: 0, width: 380, height: 500)

        let ms = Self.measureMs {
            tv.layoutIfNeeded()
        }
        print("UITextView scrollable viewport 1000 lines: \(ms)ms")
        #expect(ms >= 0)
    }

    // MARK: - Full cell configure simulation

    /// Simulate the complete cell configure path: build attributed string +
    /// set on label + size. This is the end-to-end cost during scroll.
    @Test("Full configure UILabel 300 lines (cached)")
    func fullConfigureLabel300Cached() {
        // Pre-build the attributed string (simulates cache hit).
        let attributed = Self.highlightedCode(lineCount: 300)

        let label = UILabel()
        label.numberOfLines = 0

        let ms = Self.measureMs {
            label.attributedText = attributed
            _ = label.sizeThatFits(CGSize(width: 380, height: CGFloat.greatestFiniteMagnitude))
        }
        print("Full configure UILabel 300 lines (cached): \(ms)ms")
        #expect(ms >= 0)
    }

    @Test("Full configure UITextView scrollable 300 lines (cached)")
    func fullConfigureTextView300Cached() {
        let attributed = Self.highlightedCode(lineCount: 300)

        let tv = Self.makeScrollableTextView()
        tv.frame = CGRect(x: 0, y: 0, width: 380, height: 500)

        let ms = Self.measureMs {
            tv.attributedText = attributed
            tv.layoutIfNeeded()
        }
        print("Full configure UITextView scrollable 300 lines (cached): \(ms)ms")
        #expect(ms >= 0)
    }

    // MARK: - Helpers

    private static func makeTextView() -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.backgroundColor = .clear
        return tv
    }

    private static func makeScrollableTextView() -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = true
        tv.isSelectable = false
        tv.textContainerInset = UIEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.textContainer.widthTracksTextView = true
        tv.backgroundColor = .clear
        return tv
    }
}
