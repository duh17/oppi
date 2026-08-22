import UIKit
import Testing
@testable import Oppi

@Suite("QuietWorkLineRowContent")
@MainActor
struct QuietWorkLineRowContentTests {
    private let timestamp = Date(timeIntervalSince1970: 0)

    private func makeWorkLine(
        buckets: [QuietWorkBucket],
        style: AppPreferences.ChatDisplay.WorkStripStyle = .icons,
        isLive: Bool = false
    ) -> QuietTimelineWorkLine {
        QuietTimelineWorkLine(
            id: "quiet-work-line:test",
            turnID: "test",
            sourceItemIDs: ["test"],
            buckets: buckets,
            displayStyle: style,
            isExpanded: false,
            isLive: isLive,
            liveStartedAt: isLive ? timestamp : nil
        )
    }

    @Test func activitySymbolsFollowTheFourBuckets() {
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "read") == "magnifyingglass")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "write") == "pencil")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "edit") == "arrow.left.arrow.right")
        #expect(QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "bash") == "wrench.fill")
        #expect(
            QuietWorkLineTimelineRowContentView.symbolName(forActivityKind: "mermaid")
                == "wrench.fill"
        )
    }

    @Test func accessibilityAlwaysUsesWordsSummary() {
        let workLine = makeWorkLine(buckets: [
            .init(kind: .read, count: 4),
            .init(kind: .tooling, count: 7),
            .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
        ])

        #expect(
            QuietWorkLineTimelineRowContentView.accessibilitySummary(for: workLine, now: timestamp)
                == "read 4 files  run 7 tools  edit +12 −3"
        )
    }

    @Test func iconsAndWordsStylesShareStableWordsAccessibilityLabel() throws {
        let workLine = makeWorkLine(buckets: [
            .init(kind: .read, count: 1),
            .init(kind: .tooling, count: 2),
        ])
        let wordsView = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: workLine,
                style: .words
            )
        )
        let iconsView = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: workLine,
                style: .icons
            )
        )

        let wordsLabel = try #require(summaryLabel(in: wordsView))
        let iconsLabel = try #require(summaryLabel(in: iconsView))
        #expect(wordsLabel.text == "read 1 file  run 2 tools")
        #expect(iconsLabel.attributedText?.string.filter { $0 == "\u{fffc}" }.count == 2)
        #expect(accessibilityButton(in: wordsView)?.accessibilityLabel == "read 1 file  run 2 tools")
        #expect(accessibilityButton(in: iconsView)?.accessibilityLabel == "read 1 file  run 2 tools")
    }

    @Test func liveThinkingOnlyStatusBlinksUnlessReduceMotionIsEnabled() throws {
        let workLine = makeWorkLine(buckets: [], style: .words, isLive: true)
        #expect(workLine.isThinkingOnly)
        #expect(workLine.wordsSummary(now: Date(timeIntervalSince1970: 7)) == "Thinking… · 7s")

        let animation = try #require(
            QuietWorkLineTimelineRowContentView.thinkingBlinkAnimation(reduceMotion: false)
                as? CABasicAnimation
        )
        #expect(animation.keyPath == "opacity")
        #expect(animation.autoreverses)
        #expect(animation.repeatCount == .infinity)
        #expect(QuietWorkLineTimelineRowContentView.thinkingBlinkAnimation(reduceMotion: true) == nil)
    }

    @Test func liveThinkingViewInstallsTheBlinkAnimation() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(buckets: [], style: .words, isLive: true)
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()

        let hasAnimation = try #require(summaryLabel(in: view)).layer.animationKeys()?.isEmpty == false
        #expect(hasAnimation == !UIAccessibility.isReduceMotionEnabled)
    }

    @Test func iconEditStatsUseSeparatePositiveAndNegativeColors() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(buckets: [
                    .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
                ])
            )
        )
        let attributed = try #require(summaryLabel(in: view)?.attributedText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        var colors: [UIColor] = []
        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
            if let color = value as? UIColor { colors.append(color) }
        }

        #expect(attributed.string.contains("+12"))
        #expect(attributed.string.contains("−3"))
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().green)))
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().red)))
    }

    @Test func wordsEditStatsUseSeparatePositiveAndNegativeColors() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(
                    buckets: [
                        .init(kind: .read, count: 4),
                        .init(kind: .edit, count: 1, editStats: .init(added: 48, removed: 20)),
                    ],
                    style: .words
                ),
                style: .words
            )
        )
        let attributed = try #require(summaryLabel(in: view)?.attributedText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        var colors: [UIColor] = []
        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
            if let color = value as? UIColor { colors.append(color) }
        }

        #expect(attributed.string == "read 4 files  edit +48 −20")
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().green)))
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().red)))
    }

    @Test func settingsPreviewUsesAgreedSampleCounts() {
        let sample = WorkStripPreviewCard.sampleWorkLine
        #expect(
            sample.wordsSummary(now: Date(timeIntervalSince1970: 7))
                == "read 4 files  run 7 tools  write 1 file  edit +12 −3 · 7s"
        )
    }

    @Test func durationSitsOnTheTrailingLabel() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: QuietTimelineWorkLine(
                    id: "quiet-work-line:test",
                    turnID: "test",
                    sourceItemIDs: ["test"],
                    buckets: [.init(kind: .tooling, count: 1)],
                    displayStyle: .words,
                    isExpanded: false,
                    isLive: false,
                    liveStartedAt: Date(timeIntervalSince1970: 1_000),
                    intervalEndedAt: Date(timeIntervalSince1970: 1_012)
                )
            )
        )
        #expect(try #require(summaryLabel(in: view)).text == "run 1 tool")
        #expect(try #require(durationLabel(in: view)).text == "12s")
        #expect(try #require(durationLabel(in: view)).isHidden == false)
    }

    @Test func collapsedStripFillDiffersFromUserMessageBubble() throws {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(
                workLine: makeWorkLine(buckets: [.init(kind: .tooling, count: 1)])
            )
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()

        let chip = try #require(chipView(in: view))
        let userFill = UIColor(ThemeRuntimeState.currentPalette().userMessageBg)
        var alpha: CGFloat = 1
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        #expect(chip.backgroundColor?.getRed(&red, green: &green, blue: &blue, alpha: &alpha) == true)
        #expect(alpha < 1)
        #expect(chip.layer.borderWidth > 0)
        #expect(chip.layer.borderColor != nil)
        #expect(color(chip.backgroundColor, approximatelyEquals: userFill) == false)
    }
}

@MainActor
private func chipView(in view: QuietWorkLineTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "chipView" }?.value as? UIView
}

@MainActor
private func summaryLabel(in view: QuietWorkLineTimelineRowContentView) -> UILabel? {
    Mirror(reflecting: view).children.first { $0.label == "summaryLabel" }?.value as? UILabel
}

@MainActor
private func durationLabel(in view: QuietWorkLineTimelineRowContentView) -> UILabel? {
    Mirror(reflecting: view).children.first { $0.label == "durationLabel" }?.value as? UILabel
}

@MainActor
private func accessibilityButton(in view: QuietWorkLineTimelineRowContentView) -> UIButton? {
    Mirror(reflecting: view).children.first { $0.label == "button" }?.value as? UIButton
}

private func color(_ lhs: UIColor?, approximatelyEquals rhs: UIColor, tolerance: CGFloat = 0.01) -> Bool {
    guard let lhs else { return false }

    var lr: CGFloat = 0
    var lg: CGFloat = 0
    var lb: CGFloat = 0
    var la: CGFloat = 0
    var rr: CGFloat = 0
    var rg: CGFloat = 0
    var rb: CGFloat = 0
    var ra: CGFloat = 0

    guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
          rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else {
        return lhs.cgColor == rhs.cgColor
    }

    return abs(lr - rr) <= tolerance &&
        abs(lg - rg) <= tolerance &&
        abs(lb - rb) <= tolerance &&
        abs(la - ra) <= tolerance
}
