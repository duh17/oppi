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
            QuietWorkLineTimelineRowContentView.liveBlinkAnimation(reduceMotion: false)
                as? CABasicAnimation
        )
        #expect(animation.keyPath == "opacity")
        #expect(animation.autoreverses)
        #expect(animation.repeatCount == .infinity)
        #expect(QuietWorkLineTimelineRowContentView.liveBlinkAnimation(reduceMotion: true) == nil)
    }

    @Test func liveThinkingViewInstallsTheBlinkAnimation() throws {
        try expectLiveSummaryBlink(
            on: makeWorkLine(buckets: [], style: .words, isLive: true)
        )
    }

    @Test func liveWorkViewInstallsTheSameBlinkAsThinking() throws {
        try expectLiveSummaryBlink(
            on: makeWorkLine(
                buckets: [
                    .init(kind: .read, count: 3),
                    .init(kind: .edit, count: 1, editStats: .init(added: 32, removed: 1)),
                ],
                isLive: true
            )
        )
    }

    @Test func settledWorkViewDoesNotBlink() throws {
        let view = attachedRow(for: makeWorkLine(buckets: [.init(kind: .read, count: 3)]))
        #expect(summaryHasLiveBlink(view) == false)
    }

    private func expectLiveSummaryBlink(on workLine: QuietTimelineWorkLine) throws {
        let view = attachedRow(for: workLine)
        #expect(summaryHasLiveBlink(view) == !UIAccessibility.isReduceMotionEnabled)
    }

    private func attachedRow(for workLine: QuietTimelineWorkLine) -> QuietWorkLineTimelineRowContentView {
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(workLine: workLine)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(view)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        view.layoutIfNeeded()
        return view
    }

    private func summaryHasLiveBlink(_ view: QuietWorkLineTimelineRowContentView) -> Bool {
        summaryLabel(in: view)?.layer.animationKeys()?.isEmpty == false
    }

    private func expectEditStats(
        in view: QuietWorkLineTimelineRowContentView,
        added: String,
        removed: String
    ) throws {
        let attributed = try #require(summaryLabel(in: view)?.attributedText)
        let fullRange = NSRange(location: 0, length: attributed.length)
        var colors: [UIColor] = []
        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
            if let color = value as? UIColor { colors.append(color) }
        }
        #expect(attributed.string.contains(added))
        #expect(attributed.string.contains(removed))
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().green)))
        #expect(colors.contains(UIColor(ThemeRuntimeState.currentPalette().red)))
    }

    @Test func liveEditStatsStayGreenAndRedAfterReapply() throws {
        let workLine = makeWorkLine(
            buckets: [
                .init(kind: .read, count: 3),
                .init(kind: .edit, count: 1, editStats: .init(added: 32, removed: 1)),
            ],
            isLive: true
        )
        let view = QuietWorkLineTimelineRowContentView(
            configuration: QuietWorkLineTimelineRowConfiguration(workLine: workLine)
        )
        view.configuration = QuietWorkLineTimelineRowConfiguration(workLine: workLine)

        try expectEditStats(in: view, added: "+32", removed: "−1")
    }

    @Test func unchangedThinkingSummaryUpdatesForegroundAfterThemeChange() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        let workLine = makeWorkLine(buckets: [], style: .words)
        let configuration = QuietWorkLineTimelineRowConfiguration(workLine: workLine)

        ThemeRuntimeState.setThemeID(.dark)
        let view = QuietWorkLineTimelineRowContentView(configuration: configuration)
        let label = try #require(summaryLabel(in: view))
        let darkForeground = try #require(label.textColor)

        ThemeRuntimeState.setThemeID(.light)
        view.configuration = configuration
        let lightForeground = try #require(label.textColor)

        #expect(color(darkForeground, approximatelyEquals: UIColor(ThemePalettes.dark.fgDim)))
        #expect(color(lightForeground, approximatelyEquals: UIColor(ThemePalettes.light.fgDim)))
        #expect(color(darkForeground, approximatelyEquals: lightForeground) == false)
    }

    @Test func unchangedIconSummaryRebuildsAllThemeColorsAfterThemeChange() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        let workLine = makeWorkLine(buckets: [
            .init(kind: .read, count: 4),
            .init(kind: .edit, count: 1, editStats: .init(added: 12, removed: 3)),
        ])
        let configuration = QuietWorkLineTimelineRowConfiguration(workLine: workLine)

        ThemeRuntimeState.setThemeID(.dark)
        let view = QuietWorkLineTimelineRowContentView(configuration: configuration)
        let darkSummary = try #require(summaryLabel(in: view)?.attributedText)
        let darkIcon = try #require(firstAttachment(in: darkSummary))

        ThemeRuntimeState.setThemeID(.light)
        view.configuration = configuration
        let lightSummary = try #require(summaryLabel(in: view)?.attributedText)
        let lightIcon = try #require(firstAttachment(in: lightSummary))

        #expect(darkIcon !== lightIcon)
        #expect(color(attributedColor(in: darkSummary, for: "4"), approximatelyEquals: UIColor(ThemePalettes.dark.fgDim)))
        #expect(color(attributedColor(in: lightSummary, for: "4"), approximatelyEquals: UIColor(ThemePalettes.light.fgDim)))
        #expect(color(attributedColor(in: darkSummary, for: "+12"), approximatelyEquals: UIColor(ThemePalettes.dark.green)))
        #expect(color(attributedColor(in: lightSummary, for: "+12"), approximatelyEquals: UIColor(ThemePalettes.light.green)))
        #expect(color(attributedColor(in: darkSummary, for: "−3"), approximatelyEquals: UIColor(ThemePalettes.dark.red)))
        #expect(color(attributedColor(in: lightSummary, for: "−3"), approximatelyEquals: UIColor(ThemePalettes.light.red)))
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

private func firstAttachment(in attributed: NSAttributedString) -> NSTextAttachment? {
    attributed.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
}

private func attributedColor(in attributed: NSAttributedString, for text: String) -> UIColor? {
    let range = (attributed.string as NSString).range(of: text)
    guard range.location != NSNotFound else { return nil }
    return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
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
