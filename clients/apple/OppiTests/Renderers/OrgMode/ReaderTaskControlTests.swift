import Foundation
import Testing
import UIKit
@testable import Oppi

/// What the renderers stamp on a control (the source line it edits), and how a
/// text view turns that into a touch target and VoiceOver elements.
@Suite("Reader task controls")
struct ReaderTaskControlTests {
    // MARK: - Source lines

    @Test func orgBlocksKnowTheirStartLine() {
        let located = OrgParser().parseLocated("#+TODO: NEXT | DONE\n\n* NEXT Plan\nSCHEDULED: <2026-11-11 Wed>\n- [ ] a\n- [X] b\n\ntext")
        #expect(located.map(\.line) == [1, 3, 4, 5, 8])
        #expect(OrgParser().parse("#+TODO: NEXT | DONE\n* NEXT Plan") == OrgParser().parseLocated("#+TODO: NEXT | DONE\n* NEXT Plan").map(\.block))
    }

    private func controls(in blocks: [MarkdownBlock]) -> [ReaderTaskControl] {
        var found: [ReaderTaskControl] = []
        func inlines(_ list: [MarkdownInline]) {
            for case .html(let raw) in list {
                if let control = MarkdownBadge(markup: raw)?.control { found.append(control) }
            }
        }
        for block in blocks {
            switch block {
            case .heading(_, let list), .paragraph(let list): inlines(list)
            case .htmlBlock(let html): MarkdownBadge.badges(inHTMLBlock: html)?.compactMap(\.control).forEach { found.append($0) }
            default: break
            }
        }
        return found
    }

    @Test func orgControlsKeepTheOrgLineThroughMarkdown() throws {
        let source = "#+TODO: NEXT | DONE\n\n* NEXT Plan\nSCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>\n- [ ] a [0/0]\n- plain\n- [X] b\n* Notes"
        let converted = DocumentRenderPipeline.orgToMarkdown(source, offersStateControl: true, cancellationCheck: { false })
        let markdown = try #require(converted)
        let blocks = parseCommonMark(markdown)
        #expect(controls(in: blocks) == [
            ReaderTaskControl(kind: .state, line: 3),
            ReaderTaskControl(kind: .date(.scheduled), line: 3),
            ReaderTaskControl(kind: .date(.deadline), line: 3),
            // `* Notes` has no state: the undrawn marker that gives it one.
            ReaderTaskControl(kind: .state, line: 8),
        ])
        let tasks = blocks.compactMap { block -> [MarkdownBlock.TaskItem]? in
            if case .taskList(let items) = block { return items }
            return nil
        }.flatMap { $0 }
        #expect(tasks.map(\.sourceLine) == [5, nil, 7], "the plain item has no box; the Org line, not the Markdown's, is kept")
        #expect(tasks.map(\.checked) == [false, false, true])
        #expect(!String(describing: tasks).contains("oppi-line"), "the marker never reaches the reader's text")
    }

    @Test func aHeadingWithoutAStateGetsAMarkerOnlyWhereTheReaderCanSave() {
        let source = "* Notes\n- [ ] a"
        let plain = DocumentRenderPipeline.orgToMarkdown(source, cancellationCheck: { false }) ?? ""
        #expect(!plain.isEmpty && !plain.contains("marker"))
        let editable = DocumentRenderPipeline.orgToMarkdown(source, offersStateControl: true, cancellationCheck: { false }) ?? ""
        #expect(editable.contains("shape=\"marker\""))
    }

    @Test func markdownTaskItemsKnowTheirOwnLines() {
        let blocks = parseCommonMark("intro\n\n- [ ] a\n  - [x] nested\n- plain\n- [x] b")
        guard case .taskList(let items) = blocks[1] else {
            Issue.record("Expected a task list, got \(blocks[1])")
            return
        }
        #expect(items.map(\.sourceLine) == [3, nil, 6])
        guard case .taskList(let nested)? = items[0].content.last else {
            Issue.record("Expected the nested task list")
            return
        }
        #expect(nested.map(\.sourceLine) == [4])
    }

    @Test func aBadgeKeepsItsControlThroughMarkup() {
        let badge = OrgBadges.state("NEXT", isDone: false, line: 12)
        #expect(MarkdownBadge(markup: badge.markup) == badge)
        let marker = OrgBadges.addState(line: 4)
        #expect(MarkdownBadge(markup: marker.markup) == marker)
        #expect(MarkdownBadge(markup: OrgBadges.state("NEXT", isDone: false).markup)?.control == nil)
    }

    @Test func closedIsARecordNotAControl() {
        let entry = OrgPlanningEntry(kind: .closed, timestamp: OrgTimestamp(isActive: false, text: "2026-11-06 Fri 14:00"))
        #expect(OrgBadges.planning(entry, headingIsDone: true, clock: .current, headingLine: 3).control == nil)
    }

    // MARK: - Rendering

    private func rendered(_ source: String, offering: Bool = true) throws -> NSAttributedString {
        let converted = DocumentRenderPipeline.orgToMarkdown(source, offersStateControl: offering, cancellationCheck: { false })
        let markdown = try #require(converted)
        let result = NSMutableAttributedString()
        for case let .text(attributed) in FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark) {
            result.append(NSAttributedString(attributed))
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    private func controlAttachments(_ text: NSAttributedString) -> [ReaderTaskControl] {
        var found: [ReaderTaskControl] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let control = (value as? ReaderTaskControlAttachment)?.control { found.append(control) }
        }
        return found
    }

    @Test func renderedTextCarriesTheControlsAndOnlyAnEditableReaderGetsMarkers() throws {
        let source = "#+TODO: NEXT | DONE\n* NEXT Plan\nSCHEDULED: <2026-11-11 Wed>\n- [ ] a\n* Notes"
        #expect(try controlAttachments(rendered(source)) == [
            ReaderTaskControl(kind: .state, line: 2),
            ReaderTaskControl(kind: .date(.scheduled), line: 2),
            ReaderTaskControl(kind: .checkbox, line: 4),
            ReaderTaskControl(kind: .state, line: 5),
        ])
        // Without the flag there is no marker; the Org lines of the rest are kept.
        #expect(try controlAttachments(rendered(source, offering: false)).map(\.line) == [2, 2, 4])
    }

    // MARK: - Text view

    @MainActor
    private final class Handler: ReaderTaskControlHandling {
        var allowsTaskControls = true
        /// The menu a state control opens, when set; otherwise every control acts.
        var stateMenu: UIMenu?
        private(set) var touched: [ReaderTaskControl] = []
        func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction {
            if control.kind == .state, let stateMenu { return .menu(stateMenu) }
            return .action { [weak self] in self?.touched.append(control) }
        }
    }

    @MainActor
    private func textView(_ source: String, handler: Handler?, width: CGFloat = 340) throws -> (BaselineSafeTextView, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        let view = BaselineSafeTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        view.attributedText = try rendered(source)
        view.taskControlHandler = handler
        window.addSubview(view)
        window.makeKeyAndVisible()
        view.layoutIfNeeded()
        return (view, window)
    }

    @MainActor
    @Test func aCheckboxOwnsItsWholeColumnAndTouchingItRunsTheOwnerAction() throws {
        let handler = Handler()
        let (view, window) = try textView("* Plan\n- [ ] first task\n- [X] second task", handler: handler)
        _ = window
        // Walk down the checkbox column until a touch lands on the first box.
        var found: ReaderLocatedTaskControl?
        for y in stride(from: CGFloat(0), to: 300, by: 4) where found == nil {
            found = view.taskControl(at: CGPoint(x: 20, y: y))
        }
        let located = try #require(found)
        #expect(located.control == ReaderTaskControl(kind: .checkbox, line: 2))
        let rect = located.touchRect
        #expect(rect.width >= 44 && rect.height >= 44, "the touch area is at least 44 × 44 pt, got \(rect)")

        let hit = view.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil)
        let target = try #require(hit as? UIButton)
        target.performPrimaryAction()
        #expect(handler.touched == [located.control])

        // The text beside the box is not part of the control.
        let beside = CGPoint(x: rect.maxX + 40, y: rect.midY)
        #expect(!(view.hitTest(beside, with: nil) is UIButton))
    }

    @MainActor
    @Test func aReaderThatCannotSaveHasNoTouchTargetAndNoControlElements() throws {
        let (view, window) = try textView("* Plan\n- [ ] first task", handler: nil)
        _ = window
        func touchable() -> Bool {
            stride(from: CGFloat(0), to: 300, by: 4).contains { view.taskControl(at: CGPoint(x: 20, y: $0)) != nil }
        }
        #expect(!touchable())
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        #expect(!elements.contains { $0 is ReaderTaskControlElement })
        // Moving line by line still reads the checkbox: the lines are the text view's own.
        #expect(elements.contains { $0.accessibilityLabel?.contains("checkbox, not checked") == true })

        let handler = Handler()
        handler.allowsTaskControls = false
        view.taskControlHandler = handler
        #expect(!touchable(), "a reader that stopped saving shows nothing to touch")
    }

    @MainActor
    @Test func linesSpeakTheirBadgesAndEveryControlIsAButtonWithAnAction() throws {
        let handler = Handler()
        let source = "#+TODO: NEXT | DONE\n* NEXT [#A] Ship it [1/3]\nSCHEDULED: <2026-11-11 Wed>\n- [ ] first task"
        let (view, window) = try textView(source, handler: handler)
        _ = window
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        let spoken = elements.filter { !($0 is ReaderTaskControlElement) }.compactMap(\.accessibilityLabel)
        #expect(spoken.contains { $0.hasPrefix("Next, priority A, 1 of 3 done, Ship it") }, "the heading line speaks its state, got \(spoken)")
        #expect(spoken.contains { $0.hasPrefix("Scheduled ") }, "the planning line speaks its date, got \(spoken)")
        #expect(spoken.contains { $0.hasPrefix("checkbox, not checked, first task") }, "got \(spoken)")

        let buttons = elements.compactMap { $0 as? ReaderTaskControlElement }
        #expect(buttons.map(\.accessibilityIdentifier) == [
            "fileViewer.task.state.2",
            "fileViewer.task.scheduled.2",
            "fileViewer.task.checkbox.4",
        ])
        #expect(buttons.map { $0.accessibilityCustomActions?.map(\.name) } == [["Change state"], ["Change date"], ["Toggle"]])
        #expect(buttons.allSatisfy { $0.accessibilityTraits.contains(.button) })

        // Activating by VoiceOver is the same owner action as a touch.
        for button in buttons { #expect(button.accessibilityActivate()) }
        #expect(handler.touched == buttons.map(\.control))
        let lastActions = buttons.last?.accessibilityCustomActions
        let customAction = try #require(lastActions?.first)
        #expect(customAction.actionHandler?(customAction) == true)
        #expect(handler.touched.last == ReaderTaskControl(kind: .checkbox, line: 4))
    }

    @MainActor
    @Test func aPlainHeadingsStateIsNotDrawnButIsInItsTextMenuAndAVoiceOverAction() throws {
        let handler = Handler()
        let (view, window) = try textView("* Notes\nprose", handler: handler)
        _ = window
        let marker = ReaderTaskControl(kind: .state, line: 1)
        #expect(controlAttachments(view.textStorage) == [marker])
        #expect(!stride(from: CGFloat(0), to: 200, by: 4).contains { y in
            stride(from: CGFloat(0), to: 300, by: 10).contains { view.taskControl(at: CGPoint(x: $0, y: y)) != nil }
        }, "nothing on the page answers a touch")

        // VoiceOver: no button of its own, and the heading line's action is the owner's.
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        #expect(!elements.contains { $0 is ReaderTaskControlElement })
        let heading = try #require(elements.first { $0.accessibilityLabel == "Notes" }, "the heading speaks only its words")
        let action = try #require(heading.accessibilityCustomActions?.first)
        #expect(action.name == "Change state")
        #expect(action.actionHandler?(action) == true)
        #expect(handler.touched == [marker])

        // The text menu on the heading offers the state menu; the prose's does not.
        handler.stateMenu = UIMenu(children: [UIAction(title: "NEXT") { _ in }])
        let headingMenu = view.taskStateMenu(forTextIn: NSRange(location: 2, length: 2))
        #expect(headingMenu?.children.map(\.title) == ["NEXT"])
        let prose = (view.textStorage.string as NSString).range(of: "prose")
        #expect(view.taskStateMenu(forTextIn: prose) == nil)
        handler.allowsTaskControls = false
        #expect(view.taskStateMenu(forTextIn: NSRange(location: 2, length: 2)) == nil, "a reader that stopped saving offers none")
    }

    @MainActor
    @Test func linksStayLinkElementsWhenTheTextSpeaksByLine() throws {
        let (view, window) = try textView("* NEXT Plan\nRead [[https://example.com/docs][the docs]] first", handler: Handler())
        _ = window
        #expect(!view.isAccessibilityElement, "a badge makes the text a container")
        let elements = (view.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
        let links = elements.filter { $0.accessibilityTraits.contains(.link) }
        let link = try #require(links.first, "got \(elements.map(\.accessibilityLabel))")
        #expect(links.count == 1)
        #expect(link.accessibilityLabel == "the docs")

        // The element sits on the link's words, so VoiceOver's tap opens the link.
        let linkRange = (view.textStorage.string as NSString).range(of: "the docs")
        let frame = link.accessibilityFrameInContainerSpace
        let start = try #require(view.position(from: view.beginningOfDocument, offset: linkRange.location))
        let caret = view.caretRect(for: start)
        #expect(frame.contains(CGPoint(x: caret.maxX + 1, y: caret.midY)), "frame \(frame), caret \(caret)")
        #expect(view.textStorage.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)

        // Text with no badge, checkbox or control stays one element, as UIKit makes it.
        let plain = BaselineSafeTextView(usingTextLayoutManager: true)
        let url = try #require(URL(string: "https://example.com"))
        plain.attributedText = NSAttributedString(string: "Read the docs", attributes: [.link: url])
        #expect(!plain.usesSpokenLines)
    }
}
