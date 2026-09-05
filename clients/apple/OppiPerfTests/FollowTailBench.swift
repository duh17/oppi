import Foundation
import Testing
import UIKit
@testable import Oppi

/// Benchmark for expanded-tool follow-tail during streaming.
///
/// The previous oracle timed configuration apply only and ran deferred
/// layout / `followTail` after the timer. That is not the user-visible
/// cost: `apply()` schedules follow-tail, then `layoutSubviews()` measures
/// and scrolls. These tests time:
/// - `followTail` itself after text is already applied
/// - full apply-through-deferred-layout (`configuration=` + `layoutIfNeeded`)
///
/// Output format: `METRIC name=number` microseconds for autoresearch.
@Suite("FollowTailBench", .tags(.perf))
struct FollowTailBench {
    private static let medianRuns = 5
    private static let warmupRuns = 1

    /// Opt-in skip for 5000-line cases so original `boundingRect` apply-through
    /// can finish. Same source for baseline and final; set
    /// `OPPI_FOLLOW_TAIL_BENCH_NARROW=1` (or `SIMCTL_CHILD_` prefix).
    private static var skipLargeCases: Bool {
        let env = ProcessInfo.processInfo.environment
        let raw = env["OPPI_FOLLOW_TAIL_BENCH_NARROW"]
            ?? env["SIMCTL_CHILD_OPPI_FOLLOW_TAIL_BENCH_NARROW"]
        return raw == "1"
    }

    @MainActor
    @Test func follow_tail_and_apply_through_layout_matrix() {
        print("METRIC bench_narrow=\(Self.skipLargeCases ? 1 : 0)")
        // Isolated geometry first so a later apply hang still leaves METRIC lines.
        measureIsolatedGeometry(name: "geometry_unwrapped_50", lineCount: 50)
        measureIsolatedGeometry(name: "geometry_unwrapped_500", lineCount: 500)
        if !Self.skipLargeCases {
            measureIsolatedGeometry(name: "geometry_unwrapped_5000", lineCount: 5_000)
        }
        measureIsolatedGeometry(name: "geometry_wrapped_500", lineCount: 500, wrappingWidth: 180)
        measureIsolatedGeometry(name: "geometry_unicode_500", lineCount: 500, unicode: true)
        measureFollowTailHelper(name: "helper_unwrapped_50", lineCount: 50, wrapping: false)
        measureFollowTailHelper(name: "helper_unwrapped_500", lineCount: 500, wrapping: false)
        if !Self.skipLargeCases {
            measureFollowTailHelper(name: "helper_unwrapped_5000", lineCount: 5_000, wrapping: false)
        }
        measureFollowTailHelper(name: "helper_wrapped_500", lineCount: 500, wrapping: true)

        measureCase(name: "unwrapped_50", lineCount: 50, kind: .unwrappedCode)
        measureCase(name: "unwrapped_500", lineCount: 500, kind: .unwrappedCode)
        if !Self.skipLargeCases {
            measureCase(name: "unwrapped_5000", lineCount: 5_000, kind: .unwrappedCode)
        }
        measureCase(name: "wrapped_50", lineCount: 50, kind: .wrappedProse)
        measureCase(name: "wrapped_500", lineCount: 500, kind: .wrappedProse)
        measureCase(name: "unicode_500", lineCount: 500, kind: .unicodeCode)
        measureCase(name: "trailing_nl_500", lineCount: 500, kind: .trailingNewlines)
        measureDetachedApply(name: "detached_unwrapped_500", lineCount: 500)
    }

    // MARK: - Cases

    private enum ContentKind {
        case unwrappedCode
        case wrappedProse
        case unicodeCode
        case trailingNewlines

        var language: SyntaxLanguage? {
            switch self {
            case .unwrappedCode, .unicodeCode, .trailingNewlines:
                return .swift
            case .wrappedProse:
                return nil
            }
        }
    }

    private struct WindowedToolHarness {
        let window: UIWindow
        let view: ToolTimelineRowContentView
    }

    @MainActor
    private func measureCase(name: String, lineCount: Int, kind: ContentKind) {
        let prefix = makeContent(lineCount: max(1, lineCount - 1), kind: kind)
        let full = makeContent(lineCount: lineCount, kind: kind)
        let harness = makeWindowedToolView(text: prefix, language: kind.language)
        let view = harness.view
        let windowAttached = view.window === harness.window
        #expect(windowAttached)
        print("METRIC window_attached_\(name)=\(windowAttached ? 1 : 0)")

        for _ in 0 ..< Self.warmupRuns {
            applyStreamingConfig(view, text: prefix, language: kind.language)
            forceLayout(view)
            applyStreamingConfig(view, text: full, language: kind.language)
            forceLayout(view)
        }

        var followTimes: [Int] = []
        var applyTimes: [Int] = []
        followTimes.reserveCapacity(Self.medianRuns)
        applyTimes.reserveCapacity(Self.medianRuns)

        for _ in 0 ..< Self.medianRuns {
            applyStreamingConfig(view, text: prefix, language: kind.language)
            forceLayout(view)

            applyStreamingConfig(view, text: full, language: kind.language)
            followTimes.append(microseconds {
                ToolTimelineRowUIHelpers.followTail(
                    in: view.expandedScrollView,
                    contentLabel: view.expandedLabel
                )
            })

            applyStreamingConfig(view, text: prefix, language: kind.language)
            forceLayout(view)
            applyTimes.append(microseconds {
                applyStreamingConfig(view, text: full, language: kind.language)
                view.layoutIfNeeded()
            })
        }

        print("METRIC follow_tail_self_\(name)_us=\(median(followTimes))")
        print("METRIC apply_through_layout_\(name)_us=\(median(applyTimes))")
    }

    @MainActor
    private func measureDetachedApply(name: String, lineCount: Int) {
        let prefix = makeContent(lineCount: max(1, lineCount - 1), kind: .unwrappedCode)
        let full = makeContent(lineCount: lineCount, kind: .unwrappedCode)
        let harness = makeWindowedToolView(text: prefix, language: .swift)
        let view = harness.view
        let windowAttached = view.window === harness.window
        #expect(windowAttached)
        print("METRIC window_attached_\(name)=\(windowAttached ? 1 : 0)")

        for _ in 0 ..< Self.warmupRuns {
            applyStreamingConfig(view, text: prefix, language: .swift)
            forceLayout(view)
            detachFromTail(view)
            applyStreamingConfig(view, text: full, language: .swift)
            forceLayout(view)
        }

        var times: [Int] = []
        times.reserveCapacity(Self.medianRuns)
        for _ in 0 ..< Self.medianRuns {
            applyStreamingConfig(view, text: prefix, language: .swift)
            forceLayout(view)
            detachFromTail(view)
            times.append(microseconds {
                applyStreamingConfig(view, text: full, language: .swift)
                view.layoutIfNeeded()
            })
        }

        print("METRIC apply_through_layout_\(name)_us=\(median(times))")
    }

    @MainActor
    private func measureFollowTailHelper(name: String, lineCount: Int, wrapping: Bool) {
        let kind: ContentKind = wrapping ? .wrappedProse : .unwrappedCode
        let text = makeContent(lineCount: lineCount, kind: kind)
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let textView = UITextView(frame: .zero)
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.font = ToolFont.regular
        textView.textContainer.lineBreakMode = wrapping ? .byCharWrapping : .byClipping
        textView.textContainer.size = CGSize(
            width: wrapping ? 180 : 4_000,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.text = text
        scrollView.addSubview(textView)

        for _ in 0 ..< Self.warmupRuns {
            ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)
        }

        var times: [Int] = []
        times.reserveCapacity(Self.medianRuns)
        for _ in 0 ..< Self.medianRuns {
            times.append(microseconds {
                ToolTimelineRowUIHelpers.followTail(in: scrollView, contentLabel: textView)
            })
        }
        print("METRIC follow_tail_helper_\(name)_us=\(median(times))")
    }

    @MainActor
    private func measureIsolatedGeometry(
        name: String,
        lineCount: Int,
        wrappingWidth: CGFloat? = nil,
        unicode: Bool = false
    ) {
        let kind: ContentKind = unicode ? .unicodeCode : .unwrappedCode
        let text = makeContent(lineCount: lineCount, kind: kind)
        let font = ToolFont.regular
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let width = wrappingWidth ?? 4_000
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)

        var boundingTimes: [Int] = []
        var lineCountTimes: [Int] = []
        boundingTimes.reserveCapacity(Self.medianRuns)
        lineCountTimes.reserveCapacity(Self.medianRuns)

        for _ in 0 ..< Self.warmupRuns {
            _ = attributed.boundingRect(
                with: size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            _ = nativeLineCount(text)
        }

        for _ in 0 ..< Self.medianRuns {
            boundingTimes.append(microseconds {
                _ = attributed.boundingRect(
                    with: size,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
            })
            lineCountTimes.append(microseconds {
                let lines = nativeLineCount(text)
                _ = ceil(CGFloat(lines) * font.lineHeight)
            })
        }

        print("METRIC boundingRect_\(name)_us=\(median(boundingTimes))")
        print("METRIC linecount_\(name)_us=\(median(lineCountTimes))")
    }

    // MARK: - Content

    @MainActor
    private func makeContent(lineCount: Int, kind: ContentKind) -> String {
        let count = max(1, lineCount)
        switch kind {
        case .unwrappedCode:
            return (1...count).map {
                "    func process\($0)(data: [Int]) -> Result<String, Error> { .success(\"ok-\($0)\") }"
            }.joined(separator: "\n")
        case .wrappedProse:
            return (1...count).map {
                "The quick brown fox jumps over the lazy dog in paragraph \($0) with enough words to wrap in a phone viewport."
            }.joined(separator: "\n")
        case .unicodeCode:
            return (1...count).map {
                "    let value\($0) = \"你好 🎉 café naïve \($0)\""
            }.joined(separator: "\n")
        case .trailingNewlines:
            return (1...count).map {
                "    let value\($0) = \($0) // line \($0)"
            }.joined(separator: "\n") + "\n"
        }
    }

    // MARK: - View helpers

    @MainActor
    private func makeWindowedToolView(
        text: String,
        language: SyntaxLanguage?
    ) -> WindowedToolHarness {
        let view = ToolTimelineRowContentView(
            configuration: makeStreamingToolConfiguration(text: text, language: language)
        )
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            view.topAnchor.constraint(equalTo: window.topAnchor),
        ])
        window.makeKeyAndVisible()
        forceLayout(view)
        return WindowedToolHarness(window: window, view: view)
    }

    private func nativeLineCount(_ string: String) -> Int {
        let ns = string as NSString
        let length = ns.length
        guard length > 0 else { return 0 }
        var lineCount = 0
        var index = 0
        while index < length {
            ns.getLineStart(
                nil,
                end: &index,
                contentsEnd: nil,
                for: NSRange(location: index, length: 0)
            )
            lineCount += 1
        }
        var end = 0
        var contentsEnd = 0
        ns.getLineStart(
            nil,
            end: &end,
            contentsEnd: &contentsEnd,
            for: NSRange(location: length - 1, length: 0)
        )
        if contentsEnd < end {
            lineCount += 1
        }
        return lineCount
    }

    @MainActor
    private func applyStreamingConfig(
        _ view: ToolTimelineRowContentView,
        text: String,
        language: SyntaxLanguage?
    ) {
        view.configuration = makeStreamingToolConfiguration(text: text, language: language)
    }

    @MainActor
    private func makeStreamingToolConfiguration(
        text: String,
        language: SyntaxLanguage?
    ) -> ToolTimelineRowConfiguration {
        let expandedContent: ToolPresentationBuilder.ToolExpandedContent
        if let language {
            expandedContent = .code(
                text: text,
                language: language,
                startLine: 1,
                filePath: "Test.swift"
            )
        } else {
            expandedContent = .text(text: text, language: nil)
        }
        return makeTimelineToolConfiguration(
            title: "write Test.swift",
            expandedContent: expandedContent,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
    }

    @MainActor
    private func detachFromTail(_ view: ToolTimelineRowContentView) {
        let scrollView = view.expandedScrollView
        let inset = scrollView.adjustedContentInset
        view.expandedShouldAutoFollow = false
        scrollView.setContentOffset(
            CGPoint(x: -inset.left, y: -inset.top),
            animated: false
        )
    }

    @MainActor
    private func forceLayout(_ view: UIView) {
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func microseconds(_ body: () -> Void) -> Int {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.attoseconds / 1_000_000_000_000)
            + Int(elapsed.components.seconds) * 1_000_000
    }

    private func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
