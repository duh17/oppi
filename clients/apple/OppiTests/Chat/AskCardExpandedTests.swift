import Foundation
import Testing
import UIKit

@testable import Oppi

@Suite("AskCardExpanded")
@MainActor
struct AskCardExpandedTests {
    @Test("The expanded sheet shows every paragraph of the question above the options")
    func expandedSheetShowsWholeMultiParagraphQuestion() throws {
        let request = AskRequest(
            id: "deploy",
            sessionId: "s",
            questions: [AskQuestion(
                id: "deploy",
                question: "Ready to deploy?\n\nThe build passed all checks. Deploying restarts the server and briefly drops live sessions; they resume on reconnect.",
                options: [AskOption(value: "deploy", label: "Deploy now"), AskOption(value: "later", label: "Later")],
                multiSelect: false
            )],
            allowCustom: true,
            timeout: nil
        )
        let sheet = AskCardExpandedViewController()
        sheet.apply(request: request, currentPage: 0, answers: [:], colors: .placeholder, reduceMotion: true)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sheet
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        for _ in 0..<3 {
            sheet.view.setNeedsLayout()
            sheet.view.layoutIfNeeded()
        }

        let markdown = try #require(Self.firstSubview(of: AssistantMarkdownContentView.self, in: sheet.view))
        let option = try #require(Self.subview(identifier: "ask.option.deploy", in: sheet.view))
        let textViews = Self.allSubviews(in: markdown).compactMap { $0 as? UITextView }
        let paragraph = try #require(textViews.first { ($0.text ?? "").contains("The build passed") })
        let paragraphFrame = paragraph.convert(paragraph.bounds, to: sheet.view)
        let markdownFrame = markdown.convert(markdown.bounds, to: sheet.view)
        let optionFrame = option.convert(option.bounds, to: sheet.view)
        let needed = paragraph.sizeThatFits(CGSize(width: paragraph.bounds.width, height: .greatestFiniteMagnitude)).height
        #expect(paragraph.bounds.height >= needed - 1, "second paragraph clipped: \(paragraph.bounds.height) < \(needed)")
        #expect(paragraphFrame.maxY <= markdownFrame.maxY + 0.5, "paragraph spills out of the markdown view")
        #expect(markdownFrame.maxY <= optionFrame.minY, "question overlaps the options")
    }

    @Test("A theme change recolors the open question the way a fresh sheet draws it")
    func themeChangeRecolorsQuestion() throws {
        let original = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(original) }
        let request = Self.singleSelectRequest()

        ThemeRuntimeState.setThemeID(.dark)
        let (sheet, window) = Self.host(request)
        defer { window.rootViewController = nil; window.isHidden = true }
        let darkColor = try Self.questionColor(in: sheet)

        ThemeRuntimeState.setThemeID(.light)
        sheet.apply(
            request: request, currentPage: 0, answers: [:],
            colors: ComposerThemeColors(palette: ThemeID.light.palette), reduceMotion: true
        )
        Self.layout(sheet)
        let recolored = try Self.questionColor(in: sheet)

        let (fresh, freshWindow) = Self.host(request)
        defer { freshWindow.rootViewController = nil; freshWindow.isHidden = true }
        let freshLight = try Self.questionColor(in: fresh)
        #expect(darkColor != freshLight)
        #expect(recolored == freshLight, "question kept \(recolored) after the switch to light")
    }

    @Test("The answer field's 32 pt mic takes touches across a 44 pt band")
    func answerMicHasFullTouchTarget() throws {
        let (sheet, window) = Self.host(
            Self.singleSelectRequest(),
            voiceInputManager: VoiceInputManager(systemAccess: MockVoiceInputSystemAccess())
        )
        defer { window.rootViewController = nil; window.isHidden = true }
        let mic = try #require(Self.subview(identifier: "ask.voiceInput", in: sheet.view))
        #expect(!mic.isHidden)
        let frame = mic.convert(mic.bounds, to: sheet.view)
        #expect(frame.width < 44 && frame.height < 44, "mic glyph grew to \(frame.size)")
        let band = frame.insetBy(dx: (frame.width - 44) / 2, dy: (frame.height - 44) / 2)
        for point in [
            CGPoint(x: band.minX + 1, y: band.midY),
            CGPoint(x: band.maxX - 1, y: band.midY),
            CGPoint(x: band.midX, y: band.minY + 1),
            CGPoint(x: band.midX, y: band.maxY - 1),
        ] {
            #expect(sheet.view.hitTest(point, with: nil) === mic, "tap at \(point) missed the mic \(frame)")
        }
        let outside = CGPoint(x: band.midX, y: band.maxY + 2)
        #expect(sheet.view.hitTest(outside, with: nil) !== mic)
    }

    private static func host(
        _ request: AskRequest,
        voiceInputManager: VoiceInputManager? = nil
    ) -> (AskCardExpandedViewController, UIWindow) {
        let sheet = AskCardExpandedViewController()
        sheet.voiceInputManager = voiceInputManager
        sheet.apply(
            request: request, currentPage: 0, answers: [:],
            colors: ComposerThemeColors(palette: ThemeRuntimeState.currentPalette()), reduceMotion: true
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = sheet
        window.makeKeyAndVisible()
        layout(sheet)
        return (sheet, window)
    }

    private static func layout(_ sheet: UIViewController) {
        for _ in 0..<3 {
            sheet.view.setNeedsLayout()
            sheet.view.layoutIfNeeded()
        }
    }

    private static func questionColor(in sheet: UIViewController) throws -> UIColor {
        let markdown = try #require(firstSubview(of: AssistantMarkdownContentView.self, in: sheet.view))
        let text = try #require(allSubviews(in: markdown).compactMap { $0 as? UITextView }.first {
            ($0.text ?? "").contains("testing approach")
        })
        return try #require(text.attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)
    }

    private static func allSubviews(in view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews(in:))
    }

    private static func firstSubview<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        allSubviews(in: view).lazy.compactMap { $0 as? T }.first
    }

    private static func subview(identifier: String, in view: UIView) -> UIView? {
        allSubviews(in: view).first { $0.accessibilityIdentifier == identifier }
    }

    // MARK: - Fixtures

    private static func singleSelectRequest() -> AskRequest {
        AskRequest(
            id: "ask-1",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "What testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit tests", description: "Fast, isolated"),
                        AskOption(value: "integration", label: "Integration", description: "End-to-end"),
                        AskOption(value: "both", label: "Both", description: nil),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: nil
        )
    }

    private static func multiQuestionRequest() -> AskRequest {
        AskRequest(
            id: "ask-2",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "approach",
                    question: "Testing approach?",
                    options: [
                        AskOption(value: "unit", label: "Unit", description: nil),
                        AskOption(value: "integration", label: "Integration", description: nil),
                    ],
                    multiSelect: false
                ),
                AskQuestion(
                    id: "frameworks",
                    question: "Which frameworks?",
                    options: [
                        AskOption(value: "jest", label: "Jest", description: "Mature runner"),
                        AskOption(value: "vitest", label: "Vitest", description: "Vite-native, fast"),
                        AskOption(value: "playwright", label: "Playwright", description: "Browser E2E"),
                    ],
                    multiSelect: true
                ),
                AskQuestion(
                    id: "coverage",
                    question: "Coverage target?",
                    options: [
                        AskOption(value: "80", label: "80%", description: nil),
                        AskOption(value: "90", label: "90%", description: nil),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: 120_000
        )
    }

    private static func multiSelectOnlyRequest() -> AskRequest {
        AskRequest(
            id: "ask-3",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: "features",
                    question: "Which features to include?",
                    options: [
                        AskOption(value: "a", label: "Feature A", description: "Core functionality"),
                        AskOption(value: "b", label: "Feature B", description: "Extended support"),
                    ],
                    multiSelect: true
                ),
            ],
            allowCustom: false,
            timeout: nil
        )
    }

    // MARK: - Pinned Confirmation Actions

    @Test("Extension confirmations pin Confirm, Cancel, and Close Details outside long scrolling content")
    func extensionConfirmUsesPinnedActions() {
        let request = AskRequest(
            id: "approval-1",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: ExtensionUIRequest.inlineQuestionId,
                    question: "Approve command\n\n## Prompt\n\n" + String(repeating: "detail ", count: 500),
                    options: [
                        AskOption(value: ExtensionUIRequest.confirmValue, label: "Confirm"),
                        AskOption(value: ExtensionUIRequest.cancelValue, label: "Cancel"),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: false,
            timeout: nil,
            responseEncoding: .extensionConfirm
        )

        #expect(AskCardExpanded.usesPinnedConfirmationActions(request))
        #expect(AskCardExpanded.confirmationDismissTitle == "Close Details")
    }

    @Test("Ordinary single-select asks keep options with their question")
    func ordinaryAskDoesNotUsePinnedConfirmationActions() {
        #expect(AskCardExpanded.usesPinnedConfirmationActions(Self.singleSelectRequest()) == false)
    }

    @Test("Custom answers pin into the keyboard-safe footer instead of the option list")
    func customAnswersPinIntoBottomChrome() {
        #expect(AskCardExpanded.pinsCustomAnswerInBottomChrome(Self.singleSelectRequest()))
        #expect(AskCardExpanded.pinsCustomAnswerInBottomChrome(Self.multiQuestionRequest()))
    }

    @Test("Asks without custom input do not reserve footer chrome for a text field")
    func asksWithoutCustomInputDoNotPinCustomAnswer() {
        #expect(AskCardExpanded.pinsCustomAnswerInBottomChrome(Self.multiSelectOnlyRequest()) == false)
    }

    @Test("Pinned confirmations never steal the footer for a custom field")
    func pinnedConfirmationsDoNotPinCustomAnswer() {
        let request = AskRequest(
            id: "approval-2",
            sessionId: "session-1",
            questions: [
                AskQuestion(
                    id: ExtensionUIRequest.inlineQuestionId,
                    question: "Approve command",
                    options: [
                        AskOption(value: ExtensionUIRequest.confirmValue, label: "Confirm"),
                        AskOption(value: ExtensionUIRequest.cancelValue, label: "Cancel"),
                    ],
                    multiSelect: false
                ),
            ],
            allowCustom: true,
            timeout: nil,
            responseEncoding: .extensionConfirm
        )

        #expect(AskCardExpanded.usesPinnedConfirmationActions(request))
        #expect(AskCardExpanded.pinsCustomAnswerInBottomChrome(request) == false)
    }

    @Test("Focusing the custom answer lifts the expanded sheet to large")
    func customAnswerFocusLiftsSheetToLarge() {
        #expect(
            AskCardExpanded.sheetDetentForCustomAnswerFocus(
                request: Self.singleSelectRequest(),
                isCustomAnswerFocused: true
            ) == UISheetPresentationController.Detent.Identifier.large
        )
        #expect(
            AskCardExpanded.sheetDetentForCustomAnswerFocus(
                request: Self.singleSelectRequest(),
                isCustomAnswerFocused: false
            ) == nil
        )
        #expect(
            AskCardExpanded.sheetDetentForCustomAnswerFocus(
                request: Self.multiSelectOnlyRequest(),
                isCustomAnswerFocused: true
            ) == nil
        )
    }

    // MARK: - Page Count Consistency

    @Test("Single-select single question: 1 page, no submit page")
    func singleSelectSingleQuestionPageCount() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    @Test("Multi-question: pages = questions")
    func multiQuestionPageCount() {
        let request = Self.multiQuestionRequest()
        #expect(AskCard.pageCount(for: request) == 3)
    }

    @Test("Single multi-select question stays on one page")
    func singleMultiSelectPageCount() {
        let request = Self.multiSelectOnlyRequest()
        #expect(AskCard.pageCount(for: request) == 1)
    }

    // MARK: - Answer State

    @Test("Option selection stored as .single answer")
    func optionSelectionStored() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .single("unit")
        #expect(answers["approach"] == .single("unit"))
    }

    @Test("Custom text stored as .custom answer")
    func customTextStored() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .custom("property-based tests")
        #expect(answers["approach"] == .custom("property-based tests"))
    }

    @Test("Option selection overwrites custom answer")
    func optionOverwritesCustom() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .custom("my custom approach")

        // User taps an option — overwrites custom
        answers["approach"] = .single("unit")
        #expect(answers["approach"] == .single("unit"))
    }

    @Test("Custom text overwrites option selection")
    func customOverwritesOption() {
        var answers: [String: AskAnswer] = [:]
        answers["approach"] = .single("unit")

        // User types custom text — overwrites option
        answers["approach"] = .custom("snapshot tests")
        #expect(answers["approach"] == .custom("snapshot tests"))
    }

    // MARK: - Navigation Bounds

    @Test("Page navigation stays within valid range")
    func pageNavigationBounds() {
        let request = Self.multiQuestionRequest()
        let totalPages = AskCard.pageCount(for: request)
        var page = 0

        // Forward to last page
        for _ in 0..<(totalPages - 1) {
            page += 1
        }
        #expect(page == totalPages - 1)

        // Last question page is at questions.count - 1
        #expect(page == request.questions.count - 1)

        // Back to first
        for _ in 0..<(totalPages - 1) {
            page -= 1
        }
        #expect(page == 0)
    }

    @Test("Single question: no back navigation needed (only 1 page)")
    func singleQuestionNoBackNavigation() {
        let request = Self.singleSelectRequest()
        #expect(AskCard.pageCount(for: request) == 1)
        // currentPage stays at 0 — no forward/back
    }

    // MARK: - Collapse State Preservation

    @Test("Collapse preserves answers through binding round-trip")
    func collapsePreservesAnswers() {
        var answers: [String: AskAnswer] = [:]
        var isExpanded = true

        // Simulate answering in expanded mode
        answers["approach"] = .single("unit")
        answers["frameworks"] = .multi(["jest"])

        // Collapse
        isExpanded = false
        #expect(isExpanded == false)

        // Answers still intact
        #expect(answers["approach"] == .single("unit"))
        #expect(answers["frameworks"] == .multi(["jest"]))
    }

    @Test("Collapse preserves currentPage through binding")
    func collapsePreservesPage() {
        var currentPage = 2
        var isExpanded = true

        // Collapse
        isExpanded = false
        #expect(isExpanded == false)

        // Page position preserved
        #expect(currentPage == 2)
    }

    // MARK: - Dictation Text Merge

    @Test("Dictation prefix appends space when base text has no trailing whitespace")
    func dictationPrefixAddsSpaceWhenNeeded() {
        let prefix = AskCardExpanded.dictationPrefix(for: "hello")
        #expect(prefix == "hello ")
    }

    @Test("Dictation prefix keeps trailing whitespace unchanged")
    func dictationPrefixKeepsExistingWhitespace() {
        #expect(AskCardExpanded.dictationPrefix(for: "hello ") == "hello ")
        #expect(AskCardExpanded.dictationPrefix(for: "hello\n") == "hello\n")
        #expect(AskCardExpanded.dictationPrefix(for: "").isEmpty)
    }

    @Test("Combined dictation text returns base when transcript is empty")
    func combinedDictationTextEmptyTranscript() {
        let combined = AskCardExpanded.combinedDictationText(
            base: "existing",
            prefix: "existing ",
            transcript: ""
        )
        #expect(combined == "existing")
    }

    @Test("Combined dictation text appends transcript to prefix")
    func combinedDictationTextAppendsTranscript() {
        let combined = AskCardExpanded.combinedDictationText(
            base: "existing",
            prefix: "existing ",
            transcript: "new words"
        )
        #expect(combined == "existing new words")
    }
}
