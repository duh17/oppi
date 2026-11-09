import Foundation
import Testing
@testable import Oppi
// swiftlint:disable todo - Org-mode headline keyword examples, not unfinished work

// Org features an agent notebook leans on: planning lines and timestamps,
// custom `#+TODO:` states, progress cookies, links between files, and
// property drawers kept out of the reading view.

@Suite("Org notebook compatibility")
struct OrgNotebookCompatibilityTests {
    let parser = OrgParser()

    // MARK: - Planning lines and timestamps

    @Test func planningLineUnderHeadingParsesAsMetadata() {
        let blocks = parser.parse("""
        * TODO Ship
        SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri 17:00>
        CLOSED: [2026-11-06 Fri 14:00]
        """)
        #expect(blocks.count == 3)
        #expect(blocks[1] == .planning([
            OrgPlanningEntry(kind: .scheduled, timestamp: OrgTimestamp(isActive: true, text: "2026-11-11 Wed")),
            OrgPlanningEntry(kind: .deadline, timestamp: OrgTimestamp(isActive: true, text: "2026-11-13 Fri 17:00")),
        ]))
        // Only the line directly under the heading is planning.
        guard case .paragraph = blocks[2] else {
            Issue.record("Expected the second line to stay a paragraph, got \(blocks[2])")
            return
        }
    }

    @Test func closedTimestampIsInactiveAndKeepsRepeater() {
        let blocks = parser.parse("""
        * DONE Water plants
        CLOSED: [2026-11-06 Fri 14:00] SCHEDULED: <2026-11-12 Thu +1w>
        """)
        #expect(blocks[1] == .planning([
            OrgPlanningEntry(kind: .closed, timestamp: OrgTimestamp(isActive: false, text: "2026-11-06 Fri 14:00")),
            OrgPlanningEntry(kind: .scheduled, timestamp: OrgTimestamp(isActive: true, text: "2026-11-12 Thu +1w")),
        ]))
    }

    @Test(arguments: [
        "CLOSED: yesterday",
        "SCHEDULED: <2026-11-11 Wed> and then some prose",
        "DEADLINE: soon",
    ])
    func proseThatLooksLikePlanningStaysAParagraph(line: String) {
        let blocks = parser.parse("* Heading\n\(line)")
        guard case .paragraph = blocks[1] else {
            Issue.record("Expected paragraph for \(line), got \(blocks[1])")
            return
        }
    }

    @Test func planningKeywordOutsideAHeadingIsAParagraph() {
        let blocks = parser.parse("Intro\n\nSCHEDULED: <2026-11-11 Wed>")
        for block in blocks {
            if case .planning = block { Issue.record("Planning line without a heading: \(blocks)") }
        }
    }

    @Test func timestampsInTextParseActiveAndInactive() {
        let blocks = parser.parse("Meet <2026-11-11 Wed> or [2026-11-06 Fri 14:00] but not <2026-13> or [just text].")
        #expect(blocks == [.paragraph([
            .text("Meet "),
            .timestamp(OrgTimestamp(isActive: true, text: "2026-11-11 Wed")),
            .text(" or "),
            .timestamp(OrgTimestamp(isActive: false, text: "2026-11-06 Fri 14:00")),
            .text(" but not <2026-13> or [just text]."),
        ])])
    }

    // MARK: - #+TODO keywords

    @Test func customTodoSequenceMakesWaitAndCancelledKeywords() {
        let blocks = parser.parse("""
        #+TODO: TODO NEXT WAIT | DONE CANCELLED
        * WAIT Device check
        * CANCELLED Old idea
        * NEXT Ship
        """)
        let keywords = blocks.compactMap { block -> String? in
            if case let .heading(_, keyword, _, _, _) = block { return keyword }
            return nil
        }
        #expect(keywords == ["WAIT", "CANCELLED", "NEXT"])
    }

    @Test func todoDeclarationAppliesToHeadingsAboveIt() {
        let blocks = parser.parse("* WAIT Early\n#+TODO: WAIT | DONE")
        guard case let .heading(_, keyword, _, title, _) = blocks[0] else {
            Issue.record("Expected heading")
            return
        }
        #expect(keyword == "WAIT")
        #expect(title == [.text("Early")])
    }

    @Test func declarationReplacesTheDefaultKeywords() {
        let blocks = parser.parse("#+TODO: QUEUED | SHIPPED\n* TODO Not a keyword here\n* SHIPPED Out")
        guard case let .heading(_, first, _, _, _) = blocks[1],
              case let .heading(_, second, _, _, _) = blocks[2] else {
            Issue.record("Expected two headings")
            return
        }
        #expect(first == nil)
        #expect(second == "SHIPPED")
    }

    @Test func declarationQuotedInASourceBlockIsNotASetting() {
        let blocks = parser.parse("#+BEGIN_SRC org\n#+TODO: A | B\n#+END_SRC\n* A x\n* TODO y")
        let keywords = blocks.compactMap { block -> String? in
            if case let .heading(_, keyword, _, _, _) = block { return keyword ?? "none" }
            return nil
        }
        #expect(keywords == ["none", "TODO"])
    }

    @Test func withoutDeclarationWaitIsPlainTitleText() {
        let blocks = parser.parse("* WAIT Device check")
        guard case let .heading(_, keyword, _, _, _) = blocks[0] else {
            Issue.record("Expected heading")
            return
        }
        #expect(keyword == nil)
    }

    @Test func declarationSplitsActiveAndDoneAroundTheBar() throws {
        let keywords = try #require(OrgTodoKeywords(declaration: "TODO NEXT WAIT(w@/!) | DONE CANCELLED(c@)"))
        #expect(keywords.active == ["TODO", "NEXT", "WAIT"])
        #expect(keywords.done == ["DONE", "CANCELLED"])
    }

    @Test func declarationWithoutBarEndsInADoneState() throws {
        let keywords = try #require(OrgTodoKeywords(declaration: "TODO DONE"))
        #expect(keywords.active == ["TODO"])
        #expect(keywords.done == ["DONE"])
    }

    // MARK: - Progress cookies

    @Test func progressCookiesParseInHeadingsAndListItems() {
        let blocks = parser.parse("""
        * Release [2/5] and [40%]
        - [ ] Step [0/2]
        """)
        guard case let .heading(_, _, _, title, _) = blocks[0],
              case let .list(_, items) = blocks[1] else {
            Issue.record("Expected heading and list, got \(blocks)")
            return
        }
        #expect(title == [.text("Release "), .progress("2/5"), .text(" and "), .progress("40%")])
        #expect(items[0].checkbox == .unchecked)
        #expect(items[0].content == [.text("Step "), .progress("0/2")])
    }

    @Test(arguments: ["[1]", "[a/b]", "[2/5", "[X]"])
    func bracketsThatAreNotCookiesStayText(text: String) {
        #expect(parser.parse("see \(text) here") == [.paragraph([.text("see \(text) here")])])
    }

    // MARK: - Conversion

    /// Friday 2026-11-06, noon UTC, read in US English.
    static let clock: OrgBadges.Clock = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12))!
        return OrgBadges.Clock(now: now, calendar: calendar)
    }()

    private func convert(_ source: String, documentPath: String? = nil) -> [MarkdownBlock] {
        OrgToMarkdownConverter.convert(parser.parse(source), documentPath: documentPath, clock: Self.clock)
    }

    private func badges(_ inlines: [MarkdownInline]) -> [MarkdownBadge] {
        inlines.compactMap { inline in
            guard case let .html(raw) = inline else { return nil }
            return MarkdownBadge(markup: raw)
        }
    }

    private func badges(_ block: MarkdownBlock) -> [MarkdownBadge] {
        switch block {
        case let .heading(_, inlines), let .paragraph(inlines): badges(inlines)
        case let .htmlBlock(html): MarkdownBadge.badges(inHTMLBlock: html) ?? []
        default: []
        }
    }

    private func headingInlines(_ block: MarkdownBlock) -> [MarkdownInline] {
        guard case let .heading(_, inlines) = block else { return [] }
        return inlines
    }

    @Test func headingLeadsWithOneBarAndTrailsItsTags() {
        let blocks = convert("""
        #+TODO: TODO NEXT WAIT | DONE CANCELLED
        * NEXT [#A] Ship Org [1/3] rendering :oppi:ios:
        """)
        #expect(blocks.count == 1, "the #+TODO directive is not rendered")
        let next = MarkdownBadge(text: "NEXT", label: "Next", tone: .accent)
        let priority = MarkdownBadge(text: "#A", label: "priority A", tone: .neutral)
        let progress = MarkdownBadge(text: "1/3", label: "1 of 3 done", tone: .neutral)
        let oppi = MarkdownBadge(text: "oppi", label: "tag oppi", tone: .quiet, shape: .capsule)
        let ios = MarkdownBadge(text: "ios", label: "tag ios", tone: .quiet, shape: .capsule)
        // The cookie moves into the bar and leaves no double space behind.
        #expect(headingInlines(blocks[0]) == [
            .html(next.markup), .html(priority.markup), .html(progress.markup),
            .text(" "), .text("Ship Org rendering"),
            .text(" "), .html(oppi.markup), .text(" "), .html(ios.markup),
        ])
    }

    @Test(arguments: [
        ("TODO", MarkdownBadge.Tone.accent, false),
        ("NEXT", .accent, false),
        ("WAIT", .warning, false),
        ("HOLD", .warning, false),
        ("DONE", .success, true),
        ("CANCELLED", .muted, true),
    ])
    func stateToneFollowsItsClassAndDoneTitlesAreStruck(
        keyword: String, tone: MarkdownBadge.Tone, struck: Bool
    ) {
        let blocks = convert("#+TODO: TODO NEXT WAIT HOLD | DONE CANCELLED\n* \(keyword) Task")
        #expect(badges(blocks[0]).map(\.tone) == [tone])
        #expect(headingInlines(blocks[0]).last == (struck ? .strikethrough([.text("Task")]) : .text("Task")))
    }

    @Test func customDoneStateFollowsTheDeclaration() {
        let blocks = convert("#+TODO: QUEUED | SHIPPED\n* SHIPPED Out\n* QUEUED Next")
        #expect(badges(blocks[0]).map(\.tone) == [.success])
        #expect(badges(blocks[1]).map(\.tone) == [.accent])
    }

    @Test(arguments: [("1/3", MarkdownBadge.Tone.neutral, "1 of 3 done"), ("3/3", .success, "3 of 3 done"),
                      ("40%", .neutral, "40 percent done"), ("100%", .success, "100 percent done")])
    func progressReadsAsWordsAndCompleteReadsAsDone(cookie: String, tone: MarkdownBadge.Tone, label: String) {
        let badge = badges(convert("* Release [\(cookie)]")[0]).first
        #expect(badge?.tone == tone)
        #expect(badge?.label == label)
    }

    @Test func planningLineIsABarOfDatesAndAPassedDeadlineWarns() throws {
        let blocks = convert("* TODO Ship\nSCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-05 Thu 17:00>")
        let bar = badges(blocks[1])
        #expect(bar.map(\.tone) == [.neutral, .danger])
        #expect(bar.map(\.symbol) == ["calendar", "exclamationmark.triangle.fill"])
        #expect(bar[0].text == "Wed, Nov 11")
        #expect(bar[0].label == "Scheduled Wednesday, November 11, 2026")
        #expect(bar[1].label.hasPrefix("Deadline Thursday, November 5, 2026 at 5:00"))
        #expect(bar[1].label.hasSuffix(", overdue"))
    }

    @Test(arguments: [
        "* DONE Ship\nDEADLINE: <2026-11-01 Sun>",
        "* TODO Ship\nDEADLINE: <2026-11-06 Fri>",
        "* TODO Ship\nDEADLINE: <2026-11-06 Fri 18:00>",
    ])
    func deadlineWarnsOnlyWhenOpenAndPassed(source: String) {
        let bar = badges(convert(source)[1])
        #expect(bar.map(\.tone) == [.neutral], "done headings, and a deadline later today, never warn")
    }

    @Test func repeaterAndAnotherYearShow() {
        let bar = badges(convert("* TODO Ship\nSCHEDULED: <2026-11-12 Thu +1w> DEADLINE: <2027-01-04 Mon>")[1])
        #expect(bar[0].text == "Thu, Nov 12 ↻1w")
        #expect(bar[0].label.hasSuffix("repeats every 1 week"))
        #expect(bar[1].text.contains("2027"))
    }

    @Test func listItemCookieIsTheSameBadgeAsAHeadingCookie() {
        let blocks = convert("* Release [0/2]\n- Item [0/2]")
        guard case let .unorderedList(items) = blocks[1] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(badges(items[0][0]) == badges(blocks[0]))
    }

    @Test func badgesSurviveTheMarkdownRoundTrip() throws {
        // A lone planning entry is a line of one tag, which CommonMark reads
        // as an HTML block rather than a paragraph.
        let source = """
        #+TODO: TODO "Q&A"<1> | DONE
        * "Q&A"<1> [#B] Say hi [1/2] :a_b:
        CLOSED: [2026-11-06 Fri 14:00]
        """
        let blocks = convert(source)
        let parsed = parseCommonMark(MarkdownBlockSerializer.serialize(blocks))
        #expect(parsed.count == 2)
        #expect(badges(parsed[0]) == badges(blocks[0]))
        #expect(badges(parsed[1]) == badges(blocks[1]))
        guard case .htmlBlock = parsed[1] else {
            Issue.record("Expected the lone planning entry as an HTML block, got \(parsed[1])")
            return
        }
    }

    @Test func propertiesDrawerStaysOutOfTheReadingView() {
        let blocks = convert("""
        * Heading
        :PROPERTIES:
        :ID: abc
        :EFFORT: 2h
        :END:
        Body
        """)
        #expect(blocks.count == 2)
        #expect(blocks[1] == .paragraph([.text("Body")]))
    }

    @Test func otherDrawersStillShowTheirEntries() {
        let blocks = convert(":LOGBOOK:\n:note: tried it\n:END:")
        guard case let .codeBlock(language, code) = blocks[0] else {
            Issue.record("Expected code block, got \(blocks)")
            return
        }
        #expect(language == "logbook")
        #expect(code.contains("tried it"))
    }

    // MARK: - Links

    private func linkDestinations(
        _ source: String,
        documentPath: String? = OrgNotebookFixture.projectPath
    ) -> [String] {
        let blocks = convert(source, documentPath: documentPath)
        guard case let .paragraph(inlines) = blocks.last else { return [] }
        return inlines.compactMap { inline in
            if case let .link(_, destination) = inline { return destination }
            return nil
        }
    }

    @Test(arguments: [
        ("[[file:x.org]]", "x.org"),
        ("[[file:../notes/x.org]]", "../notes/x.org"),
        ("[[file:notes/x.org::*Heading][label]]", "notes/x.org#title=Heading"),
        ("[[file:notes/x.org::*Two%20words]]", "notes/x.org#title=Two%2520words"),
        ("[[file:notes/x.org::#release-notes]]", "notes/x.org#custom=release-notes"),
        ("[[file:notes/x.org::42]]", "notes/x.org"),
        ("[[file:notes/x.org::*]]", "notes/x.org"),
        ("[[file:~/notebook/x.org]]", "~/notebook/x.org"),
        ("[[file:/abs/x.org]]", "/abs/x.org"),
        ("[[./x.org]]", "./x.org"),
        ("[[../x.org][up]]", "../x.org"),
        ("[[~/x.org]]", "~/x.org"),
        ("[[https://example.com][web]]", "https://example.com"),
    ])
    func fileAndWebLinksGoToTheReaderHandlers(source: String, destination: String) {
        #expect(linkDestinations(source) == [destination])
    }

    @Test func linksToTheDocumentItselfNeedItsNameAndAMatchingTarget() {
        let source = """
        * Ship Org rendering
        :PROPERTIES:
        :ID: abc-123
        :CUSTOM_ID: ship
        :END:
        See [[*Ship Org rendering]], [[id:abc-123]], [[#ship]], [[*Missing]], [[id:zzz]] and [[#nope]].
        """
        #expect(linkDestinations(source) == [
            "oppi-heading:#title=Ship%20Org%20rendering", "oppi-heading:#id=abc-123", "oppi-heading:#custom=ship",
        ])
        #expect(linkDestinations(source, documentPath: nil).isEmpty)
    }

    @Test(arguments: ["[[id:other]]", "[[*Nowhere]]", "[[#nowhere]]", "[[Fuzzy search]]", "[[file:]]", "[[file://host/x]]", "[[elisp:(ignore)]]"])
    func linksNothingCanOpenRenderTheirLabelAsText(source: String) {
        let blocks = convert("* Heading\n\(source)")
        #expect(blocks[1] == .paragraph([.text(source.dropFirst(2).dropLast(2).description)]))
    }

    @Test func descriptionBecomesTheLabelOfAnUnresolvableLink() {
        #expect(convert("[[id:other][Other note]]") == [.paragraph([.text("Other note")])])
    }

    @Test(arguments: ["my notes/release (final).org", "my notes/<draft>.org"])
    func serializedPathWithSpacesStillParsesAsOneDestination(path: String) {
        let markdown = MarkdownBlockSerializer.serialize(convert("[[file:\(path)][notes]]"))
        let parsed = parseCommonMark(markdown)
        guard case let .paragraph(inlines) = parsed[0],
              case let .link(_, destination) = inlines[0] else {
            Issue.record("Expected a link, got \(parsed)")
            return
        }
        #expect(destination == path)
    }

    // MARK: - Through the reader's pipeline

    private func readerLinks(_ source: String) throws -> [ResourceReference] {
        let markdown = DocumentRenderPipeline.orgToMarkdown(source, documentPath: OrgNotebookFixture.projectPath)
        let segments = FlatSegment.build(
            from: parseCommonMark(markdown),
            themeID: .dark,
            serverID: "server-1",
            workspaceID: "workspace-1",
            sourceDirectory: OrgNotebookFixture.sourceDirectory
        )
        return segments.flatMap { segment -> [ResourceReference] in
            guard case let .text(attributed) = segment else { return [] }
            return attributed.runs.compactMap(\.link).compactMap(ResourceReferenceURL.parse)
        }
    }

    @Test func fixtureFileLinksOpenRelativeToTheDocument() throws {
        let links = try readerLinks(OrgNotebookFixture.project)
        let paths = links.compactMap(\.fileCandidatePath)
        // The checklist link and the release notes: links to the document
        // itself stay in the reader, as heading fragments.
        #expect(paths == [
            "/Users/alex/notebook/notes/release.org",
            "/Users/alex/notebook/notes/release.org",
        ])
        #expect(links.allSatisfy { $0.kind == .hostFile })
        #expect(links.map(\.headingAnchor) == [.title("Checklist"), nil], "the checklist link names its heading")
    }

    private func readerText(_ source: String) -> NSAttributedString {
        let markdown = DocumentRenderPipeline.orgToMarkdown(source, documentPath: OrgNotebookFixture.projectPath)
        let result = NSMutableAttributedString()
        for case let .text(attributed) in FlatSegment.build(from: parseCommonMark(markdown), themeID: .dark) {
            result.append(NSAttributedString(attributed))
            result.append(NSAttributedString(string: "\n"))
        }
        return result
    }

    private func badgeAttachments(_ text: NSAttributedString) -> [MarkdownBadgeAttachment] {
        var found: [MarkdownBadgeAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let badge = value as? MarkdownBadgeAttachment { found.append(badge) }
        }
        return found
    }

    @Test func fixtureReadsWithoutMetadataLeakingIntoBody() {
        let text = readerText(OrgNotebookFixture.project).string
        for leaked in ["SCHEDULED", "CLOSED", "DEADLINE", ":ID:", ":PROPERTIES:", "#+TODO", "2026-11-13", "2026-11-06", "oppi-badge", ":oppi:"] {
            #expect(!text.contains(leaked), "\(leaked) leaked into the reading view")
        }
    }

    @MainActor
    @Test func textViewSpeaksBadgesAsWordsWhereTheySit() {
        let textView = BaselineSafeTextView(usingTextLayoutManager: true)
        textView.attributedText = readerText("#+TODO: NEXT | DONE\n* NEXT [#A] Ship [1/3] :oppi:")
        #expect(textView.accessibilityLabel?.hasPrefix("Next, priority A, 1 of 3 done, Ship, tag oppi") == true)
    }

    @MainActor
    @Test func readerDrawsTheHeadingBarAsJoinedSegmentsThatSpeakInWords() throws {
        let palette = ThemeID.dark.palette
        let text = readerText("#+TODO: TODO NEXT | DONE\n* NEXT [#A] Ship [1/3] :oppi:\nSCHEDULED: <2026-11-11 Wed>")
        let attachments = badgeAttachments(text)
        #expect(attachments.prefix(4).map(\.accessibilityLabel) == ["Next", "priority A", "1 of 3 done", "tag oppi"])
        #expect(attachments.last?.accessibilityLabel?.hasPrefix("Scheduled ") == true)
        // Each segment after the first starts with the arrow of the one before;
        // only a bar's last segment ends in its own arrow. Tags stand alone.
        #expect(attachments.map(\.style.joinFill) == [nil, palette.ui.blue, palette.ui.bgHighlight, nil, nil])
        #expect(attachments.map(\.style.endsInArrow) == [false, false, true, false, true])
        #expect(attachments.map(\.style.isCapsule) == [false, false, false, true, false])
    }
}

