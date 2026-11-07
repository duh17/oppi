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

    private func convert(_ source: String, documentPath: String? = nil) -> [MarkdownBlock] {
        OrgToMarkdownConverter.convert(parser.parse(source), documentPath: documentPath)
    }

    private func headingInlines(_ block: MarkdownBlock) -> [MarkdownInline] {
        guard case let .heading(_, inlines) = block else { return [] }
        return inlines
    }

    @Test func doneStatesRenderAsDoneAndOpenStatesAsBold() {
        let blocks = convert("""
        #+TODO: TODO NEXT WAIT | DONE CANCELLED
        * NEXT Ship
        * CANCELLED Old idea
        """)
        #expect(blocks.count == 2, "the #+TODO directive is not rendered")
        #expect(headingInlines(blocks[0]) == [.strong([.text("NEXT")]), .text(" "), .text("Ship")])
        #expect(headingInlines(blocks[1]) == [
            .emphasis([.text("CANCELLED")]), .text(" "), .strikethrough([.text("Old idea")]),
        ])
    }

    @Test func customDoneStateFollowsTheDeclaration() {
        let blocks = convert("#+TODO: QUEUED | SHIPPED\n* SHIPPED Out\n* QUEUED Next")
        #expect(headingInlines(blocks[0]).first == .emphasis([.text("SHIPPED")]))
        #expect(headingInlines(blocks[1]).first == .strong([.text("QUEUED")]))
    }

    @Test func planningLineIsOneQuietParagraphNotBodyText() {
        let blocks = convert("* TODO Ship\nSCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri 17:00>")
        #expect(blocks[1] == .paragraph([
            .emphasis([.text("Scheduled 2026-11-11 Wed  ·  Deadline 2026-11-13 Fri 17:00")]),
        ]))
    }

    @Test func progressCookieRendersAsCodeSpan() {
        let blocks = convert("* Release [2/5]")
        #expect(headingInlines(blocks[0]) == [.text("Release "), .code("[2/5]")])
    }

    @Test func cookieBeforeTagsKeepsTwoCodeSpans() {
        let markdown = MarkdownBlockSerializer.serialize(convert("* Release [2/5] :oppi:"))
        let parsed = parseCommonMark(markdown)
        guard case let .heading(_, inlines) = parsed[0] else {
            Issue.record("Expected heading, got \(parsed)")
            return
        }
        #expect(inlines.compactMap { inline -> String? in
            if case let .code(code) = inline { return code }
            return nil
        } == ["[2/5]", "  :oppi:"])
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
        ("[[file:notes/x.org::*Heading][label]]", "notes/x.org"),
        ("[[file:notes/x.org::42]]", "notes/x.org"),
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
        :END:
        See [[*Ship Org rendering]], [[id:abc-123]], [[*Missing]] and [[id:zzz]].
        """
        #expect(linkDestinations(source) == ["oppi.org", "oppi.org"])
        #expect(linkDestinations(source, documentPath: nil).isEmpty)
    }

    @Test(arguments: ["[[id:other]]", "[[*Nowhere]]", "[[Fuzzy search]]", "[[file:]]", "[[file://host/x]]", "[[elisp:(ignore)]]"])
    func linksNothingCanOpenRenderTheirLabelAsText(source: String) {
        let blocks = convert("* Heading\n\(source)")
        #expect(blocks[1] == .paragraph([.text(source.dropFirst(2).dropLast(2).description)]))
    }

    @Test func descriptionBecomesTheLabelOfAnUnresolvableLink() {
        #expect(convert("[[id:other][Other note]]") == [.paragraph([.text("Other note")])])
    }

    @Test func serializedPathWithSpacesStillParsesAsOneDestination() {
        let markdown = MarkdownBlockSerializer.serialize(
            convert("[[file:my notes/release (final).org][notes]]")
        )
        let parsed = parseCommonMark(markdown)
        guard case let .paragraph(inlines) = parsed[0],
              case let .link(_, destination) = inlines[0] else {
            Issue.record("Expected a link, got \(parsed)")
            return
        }
        #expect(destination == "my notes/release (final).org")
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
        // Checklist link, own-ID link, release notes, and the self link.
        #expect(paths == [
            "/Users/alex/notebook/projects/oppi.org",
            "/Users/alex/notebook/notes/release.org",
            "/Users/alex/notebook/notes/release.org",
            "/Users/alex/notebook/projects/oppi.org",
        ])
        #expect(links.allSatisfy { $0.kind == .hostFile })
    }

    @Test func fixtureReadsWithoutMetadataLeakingIntoBody() {
        let markdown = DocumentRenderPipeline.orgToMarkdown(
            OrgNotebookFixture.project, documentPath: OrgNotebookFixture.projectPath
        )
        for leaked in ["SCHEDULED:", "CLOSED:", "DEADLINE:", ":ID:", ":PROPERTIES:", "#+TODO", "<2026", "[2026"] {
            #expect(!markdown.contains(leaked), "\(leaked) leaked into the reading view")
        }
        #expect(markdown.contains("*Scheduled 2026-11-11 Wed  ·  Deadline 2026-11-13 Fri 17:00*"))
        #expect(markdown.contains("**WAIT** Device check `[40%]`"))
        #expect(markdown.contains("*DONE* ~~Draft the brief~~"))
        #expect(markdown.contains("*CANCELLED* ~~Retire the old extension~~"))
    }
}
