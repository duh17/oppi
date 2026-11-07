import Testing
@testable import Oppi

/// The list gaps the owner approved second: nesting by indentation,
/// multi-line items, description lists, the `[-]` partial checkbox, and a
/// list's kind coming from its first item rather than its last. Every case
/// here failed before the fix landed.
@Suite("Org list nesting, continuation, and description items")
struct OrgListNestingTests {
    let parser = OrgParser()

    // MARK: - Nesting by indent

    @Test func nestedListBecomesAChildOfItsParentItemNotASibling() {
        let blocks = parser.parse("""
        - Top
          - Nested child
            - Grandchild
        - Back at the top
        """)
        #expect(blocks.count == 1, "indentation must not flatten the nested items into siblings")
        guard case let .list(_, items) = blocks[0] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(items.count == 2, "only the two top-level items belong at this level")
        guard case let .list(_, nested) = items[0].children.first else {
            Issue.record("Expected a nested list under the first item, got \(items[0].children)")
            return
        }
        #expect(nested.count == 1)
        #expect(nested[0].content == [.text("Nested child")])
        guard case let .list(_, grandchildren) = nested[0].children.first else {
            Issue.record("Expected a grandchild list, got \(nested[0].children)")
            return
        }
        #expect(grandchildren.map(\.content) == [[.text("Grandchild")]])
        #expect(items[1].content == [.text("Back at the top")])
    }

    // MARK: - Multi-line items (continuation lines)

    @Test func continuationLineJoinsTheItemItIndentsUnder() {
        let blocks = parser.parse("""
        - Item one
          continuation of item one
        - Item two
        """)
        guard case let .list(_, items) = blocks[0] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(items.count == 2, "a continuation line must not become its own sibling item")
        guard case .paragraph(let inlines)? = items[0].children.first else {
            Issue.record("Expected a continuation paragraph, got \(items[0].children)")
            return
        }
        #expect(inlines == [.text("continuation of item one")])
    }

    @Test func continuationThenNestedListBothBelongToTheSameItem() {
        let blocks = parser.parse("""
        - Item
          a continuation line
          - nested after the continuation
        """)
        guard case let .list(_, items) = blocks[0], items.count == 1 else {
            Issue.record("Expected one item, got \(blocks)")
            return
        }
        #expect(items[0].children.count == 2)
        guard case .paragraph = items[0].children[0] else {
            Issue.record("Expected the continuation paragraph first, got \(items[0].children[0])")
            return
        }
        guard case .list = items[0].children[1] else {
            Issue.record("Expected the nested list second, got \(items[0].children[1])")
            return
        }
    }

    // MARK: - Description lists

    @Test func descriptionListSplitsTermFromDescription() {
        let blocks = parser.parse("- Term :: Description of the term")
        guard case let .list(_, items) = blocks[0] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(items[0].term == [.text("Term")])
        #expect(items[0].content == [.text("Description of the term")])
    }

    @Test func descriptionListTermRendersAsStrongText() {
        let blocks = parser.parse("- Term :: Description")
        let converted = OrgToMarkdownConverter.convert(blocks)
        guard case .unorderedList(let items) = converted[0], case .paragraph(let inlines) = items[0][0] else {
            Issue.record("Expected an unordered list item, got \(converted)")
            return
        }
        #expect(inlines.first == .strong([.text("Term")]))
        #expect(plainText(from: inlines) == "Term: Description")
    }

    @Test func itemWithoutASeparatorHasNoTerm() {
        let blocks = parser.parse("- Plain item")
        guard case let .list(_, items) = blocks[0] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(items[0].term == nil)
    }

    // MARK: - `[-]` partial checkbox

    @Test func partialCheckboxIsNeitherCheckedNorPlainUnchecked() {
        let markdown = DocumentRenderPipeline.orgToMarkdown("- [-] Partial task")
        let parsed = parseCommonMark(markdown)
        guard case .taskList(let items)? = parsed.first else {
            Issue.record("Expected a task list, got \(parsed)")
            return
        }
        #expect(items[0].isPartial)
        #expect(!items[0].checked, "a partial box is not drawn as done")
        guard case .paragraph(let inlines)? = items[0].content.first else {
            Issue.record("Expected a paragraph, got \(items[0].content)")
            return
        }
        #expect(plainText(from: inlines) == "Partial task", "the partial marker must not leak into the shown text")
    }

    @Test func partialCheckboxSerializesAsAnOrdinaryUncheckedBoxGfmUnderstands() {
        // GFM's task-list extension has no `[-]`: a partial item goes out as
        // an ordinary `[ ]` so it still parses back as a task list at all.
        let blocks: [MarkdownBlock] = [
            .taskList([.init(checked: false, content: [.paragraph([.text("task")])], isPartial: true)]),
        ]
        let markdown = MarkdownBlockSerializer.serialize(blocks)
        #expect(markdown.contains("- [ ] task"))
        #expect(!markdown.contains("[-]"))
    }

    // MARK: - List kind comes from the first item

    @Test func listKindComesFromTheFirstItemNotTheLast() {
        // As in Org, items at one indent are one list whatever their bullets.
        for (source, kind) in [
            ("- first unordered\n- second unordered\n1. then ordered", OrgListKind.unordered),
            ("1. first ordered\n2) second ordered\n- then a dash", OrgListKind.ordered),
        ] {
            let blocks = parser.parse(source)
            guard blocks.count == 1, case let .list(listKind, items) = blocks[0] else {
                Issue.record("Expected one list, got \(blocks)")
                continue
            }
            #expect(listKind == kind)
            #expect(items.count == 3)
        }
    }

    // MARK: - Indentation

    @Test func tabsNestAtEmacsTabStops() {
        // A tab reaches column 8, past the two-space child's bullet, so the
        // tab-indented item is that child's child, not a dedent out of it.
        let blocks = parser.parse("- parent\n  - two-space child\n\t- tab grandchild\n- sibling")
        guard blocks.count == 1, case let .list(_, items) = blocks[0], items.count == 2,
              case let .list(_, children)? = items[0].children.first, children.count == 1,
              case let .list(_, grandchildren)? = children[0].children.first else {
            Issue.record("Expected parent > child > grandchild, got \(blocks)")
            return
        }
        #expect(grandchildren.map(\.content) == [[.text("tab grandchild")]])
    }

    @Test func indentedStarIsABulletAndTogglesLikeOne() {
        let source = "- [ ] parent\n  * [ ] star child\n* Heading"
        let blocks = parser.parse(source)
        guard case let .list(_, items) = blocks[0], case let .list(_, children)? = items[0].children.first else {
            Issue.record("Expected a nested star list, got \(blocks)")
            return
        }
        #expect(children.map(\.bullet) == ["*"])
        #expect(children[0].checkbox == .unchecked)
        #expect(blocks.count == 2, "the column-0 star is still a heading")
        #expect(TaskSourceEdit.toggleCheckbox(in: source, line: 2, dialect: .org) == "- [ ] parent\n  * [X] star child\n* Heading")
    }

    // MARK: - Blocks inside an item

    @Test func blocksInsideAnItemStayBlocksAndTheItemsStayOneList() {
        let blocks = parser.parse("""
        - item one
          #+begin_src sh
          echo *hi*

          echo [x](y)
          #+end_src
        - item two
          | a | b |
        - item three
        """)
        guard blocks.count == 1, case let .list(_, items) = blocks[0], items.count == 3 else {
            Issue.record("Expected one three-item list, got \(blocks)")
            return
        }
        #expect(items[0].children == [.codeBlock(language: "sh", code: "echo *hi*\n\necho [x](y)")])
        guard case .table? = items[1].children.first else {
            Issue.record("Expected a table under item two, got \(items[1].children)")
            return
        }
    }

    @Test func checkboxesInANumberedListKeepTheirStateAndLine() {
        let parsed = parseCommonMark(DocumentRenderPipeline.orgToMarkdown("1. [X] done\n2. [ ] open"))
        guard case .taskList(let items)? = parsed.first else {
            Issue.record("Expected a task list, got \(parsed)")
            return
        }
        #expect(items.map(\.checked) == [true, false])
        #expect(items.map(\.sourceLine) == [1, 2])
    }

    @Test func orderedListStaysOrderedWithBothMarkerStyles() {
        let blocks = parser.parse("""
        1. period style
        2) paren style
        """)
        guard case let .list(kind, items) = blocks[0] else {
            Issue.record("Expected a list, got \(blocks)")
            return
        }
        #expect(kind == .ordered)
        #expect(items.count == 2)
    }

    // MARK: - Checkbox toggling still works on nested and multi-line items

    @Test func nestedCheckboxTogglesItsOwnLineOnly() {
        let source = """
        - [ ] Parent
          - [ ] Child one
          - [X] Child two
        """
        let located = parser.parseLocated(source)
        let mdBlocks = OrgToMarkdownConverter.convert(located: located, offersStateControl: true)
        let markdown = MarkdownBlockSerializer.serialize(mdBlocks)
        let parsed = parseCommonMark(markdown)

        guard case .taskList(let items)? = parsed.first,
              case .taskList(let nested)? = items[0].content.last else {
            Issue.record("Expected a nested task list, got \(parsed)")
            return
        }
        // Lines are 1-based: parent is line 1, the two children lines 2 and 3.
        #expect(items[0].sourceLine == 1)
        #expect(nested.map(\.sourceLine) == [2, 3])

        guard let childOneLine = nested[0].sourceLine else {
            Issue.record("Expected the first child's source line")
            return
        }
        let toggled = TaskSourceEdit.toggleCheckbox(in: source, line: childOneLine, dialect: .org)
        #expect(toggled == """
        - [ ] Parent
          - [X] Child one
          - [X] Child two
        """)
    }

    @Test func checkboxInsideAQuoteShowsNoReaderMarkup() {
        // cmark-gfm makes no task list inside a block quote, so the quoted box
        // stays literal text and must carry no line or partial marker.
        let parsed = parseCommonMark(DocumentRenderPipeline.orgToMarkdown("""
        - [ ] outside
        #+begin_quote
        - [-] quoted
        #+end_quote
        """))
        guard case .blockQuote(let inner)? = parsed.last, case .unorderedList(let items)? = inner.first,
              case .paragraph(let inlines)? = items.first?.first else {
            Issue.record("Expected a quoted list, got \(parsed)")
            return
        }
        #expect(plainText(from: inlines) == "[ ] quoted")
        #expect(!inlines.contains { if case .html = $0 { return true }; return false }, "\(inlines)")
    }

    @Test func multiLineItemCheckboxStillToggles() {
        let source = """
        - [ ] Task
          a continuation line
        """
        let located = parser.parseLocated(source)
        let mdBlocks = OrgToMarkdownConverter.convert(located: located, offersStateControl: true)
        let markdown = MarkdownBlockSerializer.serialize(mdBlocks)
        let parsed = parseCommonMark(markdown)

        guard case .taskList(let items)? = parsed.first else {
            Issue.record("Expected a task list, got \(parsed)")
            return
        }
        #expect(items[0].sourceLine == 1)
        let toggled = TaskSourceEdit.toggleCheckbox(in: source, line: 1, dialect: .org)
        #expect(toggled == """
        - [X] Task
          a continuation line
        """)
    }
}
