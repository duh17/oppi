import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Extension native blocks (UIKit)")
@MainActor
struct ExtensionNativeBlockViewsTests {
    private let linkContext = ExtensionSurfaceLinkContext(
        serverID: "server-1",
        workspaceID: "ws-1",
        sessionID: "session-parent"
    )

    @Test(arguments: ["missing", "unhandled", "handled"])
    func webLinkFallbackUsesBrowserRoutingOnlyWhenHostDoesNotHandle(host: String) throws {
        let url = try #require(URL(string: "https://example.com/extension-native-\(host)"))
        var posted: [URL] = []
        let observer = NotificationCenter.default.addObserver(forName: .webLinkTapped, object: nil, queue: .main) {
            if $0.object as? URL == url { posted.append(url) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        var hostCalled = false
        let onOpenURL: ((URL) -> Bool)? = host == "missing" ? nil : { opened in
            #expect(opened == url)
            hostCalled = true
            return host == "handled"
        }
        context(onOpenURL: onOpenURL).open(url)
        #expect(hostCalled == (host != "missing"))
        #expect(posted == (host == "handled" ? [] : [url]))
    }

    @Test func markdownWikiLinkBecomesWorkspaceFileReference() throws {
        let stack = layout(
            .blocks([.markdown(base: base("notes"), markdown: "See [[docs/foo.md|Foo]]")]),
            context: context()
        )

        let links = subviews(of: UITextView.self, in: stack).flatMap(linkURLs)
        let reference = try #require(links.lazy.compactMap(ResourceReferenceURL.parse).first)
        #expect(reference.kind == .workspaceFile)
        #expect(reference.fileCandidatePath == "docs/foo.md")
        #expect(reference.workspaceID == "ws-1")
    }

    @Test func codeBlockPaintsThroughHighlightedCodeViewWithItsLanguage() {
        let stack = layout(
            .blocks([.code(base: base("snippet"), language: "swift", text: "print(\"hi\")")]),
            context: context()
        )

        let codeViews = subviews(of: NativeCodeBlockView.self, in: stack)
        #expect(codeViews.count == 1)
        let labels = codeViews.flatMap { subviews(of: UILabel.self, in: $0) }.compactMap(\.text)
        #expect(labels.contains("swift"))
    }

    @Test func terminalScrollOffsetSurvivesReplacementWhileBlockIdIsStable() throws {
        let wide = String(repeating: "0123456789 ", count: 40)
        let stack = layout(.blocks([terminal(id: "log", line: wide)]), context: context())
        let scrollView = try #require(subviews(of: UIScrollView.self, in: stack).first { !($0 is UITextView) })
        #expect(scrollView.contentSize.width > stack.bounds.width)
        scrollView.contentOffset.x = 120

        // Same block id, updated text: the same view keeps the reader's position.
        stack.apply(.blocks([terminal(id: "log", line: wide + "tail")]), context: context())
        stack.layoutIfNeeded()
        #expect(subviews(of: UIScrollView.self, in: stack).contains { $0 === scrollView })
        #expect(scrollView.contentOffset.x == 120)

        // A different block id is a different block.
        stack.apply(.blocks([terminal(id: "other", line: wide)]), context: context())
        stack.layoutIfNeeded()
        #expect(!subviews(of: UIScrollView.self, in: stack).contains { $0 === scrollView })
    }

    @Test func linkedActivityRowOpensThroughHost() throws {
        var opened: [URL] = []
        let link = "oppi://session/child-session"
        let stack = layout(
            .blocks([activityList(rowID: "task-1", subtitle: nil, link: link)]),
            context: context { opened.append($0); return true }
        )

        try #require(control(id: "task-1", in: stack)).sendActions(for: .touchUpInside)
        // Unlinked rows are not interactive.
        #expect(control(id: "child-1", in: stack)?.isUserInteractionEnabled == false)

        #expect(opened == [URL(string: link)])
    }

    @Test func disclosureRowBuildsOutputOnlyWhenOpenAndStaysOpenAcrossSnapshots() throws {
        func snapshot(_ raw: String) -> ExtensionNativeBlockContent {
            .blocks([.activityList(base: base("jobs"), rows: [
                ExtensionUIActivityRow(
                    id: "bash-1", title: "bash-1", subtitle: "make", detail: nil,
                    state: "running", progress: nil, link: "oppi://session/ignored", children: nil,
                    blocks: [.terminal(base: base("output:bash-1"), lines: [], text: raw)]
                ),
            ])])
        }
        var opened: [URL] = []
        let stack = layout(snapshot("50%\r\u{1B}[32mdone\u{1B}[0m\n"), context: context { opened.append($0); return true })
        let row = try #require(control(id: "bash-1", in: stack))
        #expect(row.isUserInteractionEnabled)
        #expect(paintedText(in: stack).isEmpty)

        row.sendActions(for: .touchUpInside)
        stack.layoutIfNeeded()
        // The carriage return overwrote the progress text; the escape is styling, not text.
        #expect(paintedText(in: stack) == ["done"])
        #expect(opened.isEmpty)

        // A replacement snapshot for the same row updates the open output in place.
        stack.apply(snapshot("done\nnext line"), context: context())
        stack.layoutIfNeeded()
        #expect(paintedText(in: stack) == ["done\nnext line"])

        row.sendActions(for: .touchUpInside)
        stack.layoutIfNeeded()
        #expect(paintedText(in: stack).isEmpty)
    }

    @Test func textOnlyTerminalBlockDecodesPlainLinesForPreviews() throws {
        let json = #"{"type":"terminal","text":"\u001b[1mbuild\u001b[0m\n10%\r100%\n"}"#
        let block = try JSONDecoder().decode(ExtensionUINativeBlock.self, from: Data(json.utf8))
        guard case .terminal(_, let lines, let text) = block else {
            Issue.record("Expected terminal block")
            return
        }
        #expect(text == "\u{1B}[1mbuild\u{1B}[0m\n10%\r100%\n")
        #expect(lines.map { $0.map(\.text).joined() } == ["build", "100%"])
    }

    @Test func cappedViewportHugsShortContentAndCapsLongContent() {
        let host = ExtensionNativeBlockScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 1))
        let short = ExtensionNativeBlockContent.blocks([
            .text(base: base("t"), spans: [ExtensionUITextSpan(text: "One line", role: nil, traits: nil, link: nil)]),
        ])
        let long = ExtensionNativeBlockContent.blocks([
            .activityList(base: base("rows"), rows: (1 ... 20).map { index in
                ExtensionUIActivityRow(
                    id: "row-\(index)", title: "Row \(index)", subtitle: nil, detail: nil,
                    state: "inactive", progress: nil, link: nil, children: nil
                )
            }),
        ])

        update(host, content: short)
        let shortHeight = host.viewportHeight(for: 360)
        update(host, content: long)
        let longHeight = host.viewportHeight(for: 360)

        // Insets alone are 20pt; a line of text must add to them.
        #expect(shortHeight > 30)
        #expect(shortHeight < 120)
        #expect(longHeight == 200)
    }

    @Test func widgetLinesKeepTerminalHeaderAndActivityConventions() {
        typealias Presentation = ExtensionNativeBlockPresentation
        #expect(Presentation.widgetLineStyle("● Agents") == .header(title: "Agents", isActive: true))
        #expect(Presentation.widgetLineStyle("\u{1B}[2m○ Idle queue\u{1B}[0m") == .header(title: "Idle queue", isActive: false))
        #expect(Presentation.widgetLineStyle("│  ⎿ editing 2 files") == .text(isActivity: true))
        #expect(Presentation.widgetLineStyle("Runs: 21  9 kept") == .text(isActivity: false))
    }

    // MARK: - Helpers

    private func base(_ id: String) -> ExtensionUIBlockBase {
        ExtensionUIBlockBase(id: id, accessibility: nil)
    }

    private func context(onOpenURL: ((URL) -> Bool)? = nil) -> ExtensionNativeBlockContext {
        ExtensionNativeBlockContext(themeID: .dark, linkContext: linkContext, onOpenURL: onOpenURL)
    }

    private func terminal(id: String, line: String) -> ExtensionUINativeBlock {
        .terminal(base: base(id), lines: [[ExtensionUITextSpan(text: line, role: nil, traits: nil, link: nil)]], text: nil)
    }

    private func activityList(rowID: String, subtitle: String?, link: String? = nil) -> ExtensionUINativeBlock {
        .activityList(base: base("tasks"), rows: [
            ExtensionUIActivityRow(
                id: rowID,
                title: "Refactor the auth module and its session tests",
                subtitle: subtitle,
                detail: nil,
                state: "running",
                progress: nil,
                link: link,
                children: [
                    ExtensionUIActivityRow(
                        id: "child-1", title: "Find auth files", subtitle: nil, detail: nil,
                        state: "success", progress: nil, link: nil, children: nil
                    ),
                ]
            ),
        ])
    }

    private func layout(_ content: ExtensionNativeBlockContent, context: ExtensionNativeBlockContext) -> ExtensionNativeBlockStackView {
        let stack = ExtensionNativeBlockStackView(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        stack.apply(content, context: context)
        stack.layoutIfNeeded()
        return stack
    }

    private func update(_ host: ExtensionNativeBlockScrollView, content: ExtensionNativeBlockContent) {
        host.update(
            content: content,
            context: context(),
            sizing: .capped(maxHeight: 200),
            contentInsets: NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10),
            spacing: 10,
            accessibilityIdentifier: nil,
            onDoubleTap: nil
        )
    }

    /// Visible text of every painted terminal/text view, hidden containers excluded.
    private func paintedText(in root: UIView) -> [String] {
        subviews(of: ExtensionNativeTerminalView.self, in: root)
            .filter { view in
                var current: UIView? = view
                while let candidate = current, candidate !== root {
                    if candidate.isHidden { return false }
                    current = candidate.superview
                }
                return true
            }
            .flatMap { subviews(of: UITextView.self, in: $0) }
            .compactMap(\.text)
    }

    private func control(id: String, in root: UIView) -> UIControl? {
        subviews(of: UIControl.self, in: root).first {
            $0.accessibilityIdentifier == "extension.native.activity.row.\(id)"
        }
    }

    private func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) + subviews(of: type, in: child)
        }
    }

    private func linkURLs(in textView: UITextView) -> [URL] {
        var urls: [URL] = []
        let text = textView.attributedText ?? NSAttributedString()
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL {
                urls.append(url)
            } else if let raw = value as? String, let url = URL(string: raw) {
                urls.append(url)
            }
        }
        return urls
    }
}
