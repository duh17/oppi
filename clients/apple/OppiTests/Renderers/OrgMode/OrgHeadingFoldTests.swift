import Foundation
import Testing
import UIKit
@testable import Oppi

/// Heading folds: what a folded heading hides, and how a tap or VoiceOver
/// reaches the fold.
@Suite("Org heading folding")
struct OrgHeadingFoldTests {
    /// Words stand for the blocks, so a test reads which are shown.
    private static let outline = """
    * Alpha
    alpha body
    ** Alpha one
    one body
    *** Alpha one deep
    deep body
    ** Alpha two
    two body
    * Beta
    beta body
    * Gamma
    """

    // Source lines of the headings above.
    private let alpha = 1, alphaOne = 3, alphaOneDeep = 5, alphaTwo = 7, beta = 9, gamma = 11

    private func shown(folding folded: Set<Int>, _ source: String = outline) throws -> String {
        let markdown = DocumentRenderPipeline.orgToMarkdown(
            source,
            foldingHeadings: .init(folded: folded),
            cancellationCheck: { false }
        )
        return try #require(markdown)
    }

    private func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.compactMap { inline -> String? in
            if case .text(let string) = inline { return string }
            return nil
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func visibleBodies(_ markdown: String) -> [String] {
        parseCommonMark(markdown).compactMap { block in
            if case .paragraph(let inlines) = block, plainText(inlines).hasSuffix("body") { return plainText(inlines) }
            return nil
        }
    }

    private func visibleHeadings(_ markdown: String) -> [String] {
        parseCommonMark(markdown).compactMap { block in
            if case .heading(_, let inlines) = block { return plainText(inlines) }
            return nil
        }
    }

    private func folds(_ markdown: String) -> [ReaderTaskControl] {
        var found: [ReaderTaskControl] = []
        for block in parseCommonMark(markdown) {
            guard case .heading(_, let inlines) = block else { continue }
            for case .html(let raw) in inlines {
                if let control = MarkdownBadge(markup: raw)?.control, control.isFold { found.append(control) }
            }
        }
        return found
    }

    // MARK: - What a fold hides

    @Test func nothingIsFoldedByDefault() throws {
        let markdown = try shown(folding: [])
        #expect(visibleBodies(markdown).count == 5)
        #expect(visibleHeadings(markdown).count == 6)
        #expect(folds(markdown) == [
            ReaderTaskControl(kind: .fold(isExpanded: true), line: alpha),
            ReaderTaskControl(kind: .fold(isExpanded: true), line: alphaOne),
            ReaderTaskControl(kind: .fold(isExpanded: true), line: alphaOneDeep),
            ReaderTaskControl(kind: .fold(isExpanded: true), line: alphaTwo),
            ReaderTaskControl(kind: .fold(isExpanded: true), line: beta),
        ], "Gamma has nothing under it, so no chevron")
    }

    @Test func aFoldStopsAtTheNextHeadingOfTheSameLevel() throws {
        // `Alpha one` (level 2) hides its deeper heading and body, not `Alpha two`.
        let markdown = try shown(folding: [alphaOne])
        #expect(visibleBodies(markdown) == ["alpha body", "two body", "beta body"])
        #expect(visibleHeadings(markdown) == ["Alpha", "Alpha one", "Alpha two", "Beta", "Gamma"])
        #expect(folds(markdown).first { $0.line == alphaOne }?.kind == .fold(isExpanded: false))
        #expect(folds(markdown).first { $0.line == alpha }?.kind == .fold(isExpanded: true))
    }

    @Test func aFoldStopsAtTheNextHeadingOfAHigherLevel() throws {
        // `Alpha two` is the last level-2 heading: it ends where `Beta` (level 1) starts.
        let markdown = try shown(folding: [alphaTwo])
        #expect(visibleBodies(markdown) == ["alpha body", "one body", "deep body", "beta body"])
        #expect(visibleHeadings(markdown) == ["Alpha", "Alpha one", "Alpha one deep", "Alpha two", "Beta", "Gamma"])
    }

    @Test func aTopLevelFoldHidesEveryLevelBelowIt() throws {
        let markdown = try shown(folding: [alpha])
        #expect(visibleBodies(markdown) == ["beta body"])
        #expect(visibleHeadings(markdown) == ["Alpha", "Beta", "Gamma"])
        // The hidden headings offer no fold while they are hidden.
        #expect(folds(markdown).map(\.line) == [alpha, beta])
    }

    @Test func aFoldKeptOnAHiddenHeadingReturnsWhenItsParentOpens() throws {
        let markdown = try shown(folding: [alpha, alphaOne])
        #expect(visibleHeadings(markdown) == ["Alpha", "Beta", "Gamma"])
        let reopened = try shown(folding: [alphaOne])
        #expect(visibleBodies(reopened) == ["alpha body", "two body", "beta body"])
    }

    @Test func aHeadingWithNothingUnderItDoesNotFold() throws {
        let markdown = try shown(folding: [gamma])
        #expect(visibleBodies(markdown).count == 5)
        #expect(!folds(markdown).contains { $0.line == gamma })
    }

    @Test func skippedLevelsAndTextBeforeTheFirstHeadingFoldAsOrgReadsThem() throws {
        let source = "preamble\n*** Deep start\ndeep text\n* Top\ntop text\n** Sub\nsub text"
        let markdown = try shown(folding: [2, 6], source)
        #expect(markdown.contains("preamble"))
        #expect(!markdown.contains("deep text"), "a level-3 heading ends at the level-1 heading after it")
        #expect(markdown.contains("top text"))
        #expect(!markdown.contains("sub text"))
    }

    @Test func aDocumentThatDoesNotFoldCarriesNoChevron() throws {
        let converted = DocumentRenderPipeline.orgToMarkdown(Self.outline, cancellationCheck: { false })
        let markdown = try #require(converted)
        #expect(folds(markdown).isEmpty)
    }

    // MARK: - Text view

    @MainActor
    private final class Owner: ReaderTaskControlHandling {
        var allowsTaskControls = false
        var allowsFolding = true
        private(set) var touched: [ReaderTaskControl] = []
        func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction {
            .action { [weak self] in self?.touched.append(control) }
        }
    }

    @MainActor
    private func textView(_ source: String, owner: Owner, folded: Set<Int> = []) throws -> (BaselineSafeTextView, UIWindow) {
        let markdown = try shown(folding: folded, source)
        let text = NSMutableAttributedString()
        for case let .text(attributed) in FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark) {
            text.append(NSAttributedString(attributed))
            text.append(NSAttributedString(string: "\n"))
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 700))
        let view = BaselineSafeTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.frame = CGRect(x: 0, y: 0, width: 340, height: 600)
        view.attributedText = text
        view.taskControlHandler = owner
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return (view, window)
    }

    @MainActor
    private func point(of text: String, in view: BaselineSafeTextView) throws -> CGPoint {
        let range = (view.textStorage.string as NSString).range(of: text)
        let position = view.position(from: view.beginningOfDocument, offset: range.location + 1)
        let start = try #require(position)
        let caret = view.caretRect(for: start)
        return CGPoint(x: caret.maxX + 2, y: caret.midY)
    }

    @MainActor
    @Test func aTapOnTheHeadingsWordsFoldsItAndATapOnItsBodyDoesNot() throws {
        let owner = Owner()
        let (view, window) = try textView("* Alpha\nalpha body\n* Beta", owner: owner)
        _ = window
        let fold = ReaderTaskControl(kind: .fold(isExpanded: true), line: 1)
        #expect(try view.foldControl(at: point(of: "Alpha", in: view)) == fold)
        #expect(try view.foldControl(at: point(of: "alpha body", in: view)) == nil)
        #expect(try view.foldControl(at: point(of: "Beta", in: view)) == nil, "Beta has nothing under it")
        #expect(view.activateTaskControl(fold))
        #expect(owner.touched == [fold])
    }

    @MainActor
    @Test func aLinkInAFoldableHeadingStillOpens() throws {
        let owner = Owner()
        let (view, window) = try textView("* See [[https://example.com][the docs]] now\nbody", owner: owner)
        _ = window
        #expect(try view.foldControl(at: point(of: "the docs", in: view)) == nil)
        #expect(try view.foldControl(at: point(of: "now", in: view)) != nil)
    }

    @MainActor
    @Test func aHeadingSpeaksItsWordsAndStateAndTheFoldActionIsTheTap() throws {
        let owner = Owner()
        let (view, window) = try textView("* Alpha\nalpha body\n** Inner\ninner body", owner: owner, folded: [3])
        _ = window
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? ReaderTaskControlElement }
        #expect(elements.map(\.accessibilityIdentifier) == ["fileViewer.heading.fold.1", "fileViewer.heading.fold.3"])
        #expect(elements.map(\.accessibilityLabel) == ["Alpha", "Inner"], "the chevron adds no words to the line")
        #expect(elements.map(\.accessibilityValue) == ["Expanded", "Collapsed"])
        #expect(elements.map { $0.accessibilityCustomActions?.map(\.name) } == [["Collapse"], ["Expand"]])
        #expect(elements.allSatisfy { $0.accessibilityTraits.contains(.header) && $0.accessibilityTraits.contains(.button) })

        let first = try #require(elements.first)
        #expect(first.accessibilityActivate())
        let action = try #require(first.accessibilityCustomActions?.first)
        #expect(action.actionHandler?(action) == true)
        #expect(owner.touched == [first.control, first.control], "VoiceOver reaches the owner action a tap does")
    }

    @MainActor
    @Test func aReaderThatCannotSaveStillFoldsButOffersNoEditControls() throws {
        let owner = Owner()
        let (view, window) = try textView("#+TODO: NEXT | DONE\n* NEXT Plan\n- [ ] a", owner: owner)
        _ = window
        #expect(view.allowsTaskControls, "folding alone makes the heading live")
        let ids = (view.accessibilityElements ?? []).compactMap { ($0 as? ReaderTaskControlElement)?.accessibilityIdentifier }
        #expect(ids == ["fileViewer.heading.fold.2"], "no state or checkbox button while edits are off")
        #expect(view.taskStateMenu(forTextIn: NSRange(location: 2, length: 2)) == nil)
    }
}
