import Foundation
import Testing
import UIKit
@testable import Oppi

/// What a person sees in the workspace editor when lines wrap: where wrapped
/// rows start, and whether line numbers sit on the first row of their
/// paragraph. Everything is measured through UIKit's own geometry (caret
/// rects) and the gutter's drawn pixels, in a real window with the production
/// editor, so it holds however the editor produces them.
@Suite("Code editor wrap indent and gutter", .serialized)
@MainActor
struct CodeEditorWrapAndGutterTests {
    // MARK: - Fixtures

    private func makeEditor(
        path: String,
        text: String,
        wraps: Bool = true,
        highlightsSyntax: Bool = true,
        size: CGSize = CGSize(width: 390, height: 844)
    ) throws -> (WorkspaceFileEditorViewController, UIWindow) {
        let defaults = try #require(UserDefaults(suiteName: "editor-wrap-gutter-\(UUID().uuidString)"))
        let preferences = CodeEditorPreferences(defaults: defaults)
        preferences.keybindings = .standard
        preferences.wrapsText = wraps
        preferences.wrapsCode = wraps
        preferences.highlightsSyntax = highlightsSyntax
        preferences.showsLineNumbers = true
        let session = try #require(WorkspaceFileEditSession(
            identity: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: path),
            disk: WorkspaceFileDiskSnapshot(bytes: Data(text.utf8), etag: "\"sha256-\(String(repeating: "a", count: 64))\""),
            maxBytes: 4_000_000,
            transport: WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .notSent }),
            draftStore: WorkspaceFileDraftStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("editor-wrap-gutter-\(UUID().uuidString)")
            ),
            idleDelay: .seconds(600)
        ))
        let controller = WorkspaceFileEditorViewController(session: session, themeID: .dark, preferences: preferences) { _ in UIViewController() }
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.updatePropertiesIfNeeded()
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func gutter(of textView: CodeEditorTextView) throws -> CodeEditorGutterView {
        try #require(textView.subviews.compactMap { $0 as? CodeEditorGutterView }.first)
    }

    private func offset(ofLine line: Int, in text: String) -> Int {
        var location = 0
        for (index, content) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == line { return location }
            location += content.utf16.count + 1
        }
        return location
    }

    private func caret(_ textView: UITextView, at offset: Int) throws -> CGRect {
        let position = try #require(textView.position(from: textView.beginningOfDocument, offset: offset))
        return textView.caretRect(for: position)
    }

    /// Offset where the second row of the paragraph starting at `start` begins.
    private func secondRowStart(_ textView: CodeEditorTextView, paragraphStart start: Int) throws -> Int {
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        let location = try #require(content.location(content.documentRange.location, offsetBy: start))
        let fragment = try #require(layout.textLayoutFragment(for: location))
        let rows = fragment.textLineFragments
        try #require(rows.count > 1, "the line should wrap onto a second row")
        return start + rows[1].characterRange.location
    }

    /// Asserts the second row of the line at `start` begins at the x of the
    /// character `prefix` UTF-16 units into the line.
    private func expectWrappedRowStarts(
        _ textView: CodeEditorTextView, lineStart start: Int, textAfter prefix: Int, _ label: String
    ) throws {
        let secondX = try caret(textView, at: secondRowStart(textView, paragraphStart: start)).minX
        let textX = try caret(textView, at: start + prefix).minX
        #expect(abs(secondX - textX) < 0.5, "\(label): second row x \(secondX), text starts at \(textX)")
    }

    // MARK: - Wrapped row indent

    private static let markdown = [
        ("# Heading that is long enough to wrap onto a second row on a phone screen", 0),
        ("", 0),
        ("Plain paragraph long enough to wrap onto a second row on a phone screen, surely.", 0),
        ("- Bullet item long enough to wrap onto a second row on a phone screen, surely.", 2),
        ("1. Numbered item long enough to wrap onto a second row on a phone screen, surely.", 3),
        ("10. Two digit item long enough to wrap onto a second row on a phone screen.", 4),
        ("- [ ] Task item long enough to wrap onto a second row on a phone screen, surely.", 6),
        ("  - Nested item long enough to wrap onto a second row on a phone screen, surely.", 4),
        ("> Quote long enough to wrap onto a second row on a phone screen, for sure, yes.", 2),
        ("    Indented code-ish line long enough to wrap onto a second row on a phone.", 4),
    ]

    @Test func markdownWrappedRowsStartAtTheLinesTextOnFirstPaint() throws {
        let text = Self.markdown.map(\.0).joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "AGENTS.md", text: text)
        defer { hideTestWindow(window) }
        // No waiting: the first layout already has the final indents.
        for (index, (line, prefix)) in Self.markdown.enumerated() where !line.isEmpty {
            try expectWrappedRowStarts(
                controller.textView, lineStart: offset(ofLine: index, in: text), textAfter: prefix, "markdown line \(index + 1)"
            )
        }
    }

    @Test func codeWrappedRowsAlignWithTheirOwnIndentationWithSyntaxHighlightingOff() async throws {
        let long = "let value = compute(argument, anotherArgument, yetAnotherArgument, finalArgument)"
        let text = ["func run() {", "\(long)", "    \(long)", "        \(long)", "}"].joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "run.swift", text: text, highlightsSyntax: false)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        for (line, indent) in [(1, 0), (2, 4), (3, 8)] {
            try expectWrappedRowStarts(textView, lineStart: offset(ofLine: line, in: text), textAfter: indent, "swift line \(line + 1)")
        }

        // Indenting a line later re-wraps it under its new indentation.
        textView.selectedRange = NSRange(location: offset(ofLine: 1, in: text), length: 0)
        textView.insertText("    ")
        let start = offset(ofLine: 1, in: text)
        var aligned = false
        for _ in 0..<40 where !aligned {
            window.layoutIfNeeded()
            let secondX = try caret(textView, at: secondRowStart(textView, paragraphStart: start)).minX
            aligned = try abs(secondX - caret(textView, at: start + 4).minX) < 0.5
            if !aligned { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(aligned, "an indented line wraps under its own first character without Syntax Highlighting")
    }

    // MARK: - Wrap default

    @Test func wrapDefaultsFollowTheFileKindAndAStoredChoiceWins() throws {
        func preferences(_ configure: (UserDefaults) -> Void = { _ in }) throws -> CodeEditorPreferences {
            let name = "editor-wrap-default-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            configure(defaults)
            return CodeEditorPreferences(defaults: defaults)
        }
        let key = "\(AppIdentifiers.subsystem).editor.wrapLines"

        let fresh = try preferences()
        #expect(fresh.wrapsLines(for: CodeEditorWrapKind(grammar: CodeEditorHighlightEngine.grammar(forPath: "AGENTS.md"))))
        #expect(fresh.wrapsLines(for: CodeEditorWrapKind(grammar: CodeEditorHighlightEngine.grammar(forPath: "notes.txt"))))
        #expect(!fresh.wrapsLines(for: CodeEditorWrapKind(grammar: CodeEditorHighlightEngine.grammar(forPath: "main.swift"))))
        #expect(!fresh.wrapsLines(for: CodeEditorWrapKind(grammar: CodeEditorHighlightEngine.grammar(forPath: "data.json"))))

        // The one setting from before wrapping followed the kind still rules both.
        let wasOff = try preferences { $0.set(false, forKey: key) }
        #expect(!wasOff.wrapsLines(for: .text) && !wasOff.wrapsLines(for: .code))
        let wasOn = try preferences { $0.set(true, forKey: key) }
        #expect(wasOn.wrapsLines(for: .text) && wasOn.wrapsLines(for: .code))

        // A new choice for one kind leaves the other alone.
        fresh.setWrapsLines(true, for: .code)
        #expect(fresh.wrapsLines(for: .text) && fresh.wrapsLines(for: .code))
        fresh.setWrapsLines(false, for: .text)
        #expect(!fresh.wrapsLines(for: .text) && fresh.wrapsLines(for: .code))
    }

    @Test func openingAFileWrapsProseAndLeavesCodeUnwrappedByDefault() throws {
        let text = String(repeating: "word ", count: 80)
        for (path, wraps) in [("notes.md", true), ("notes.txt", true), ("main.swift", false)] {
            let defaults = try #require(UserDefaults(suiteName: "editor-wrap-open-\(UUID().uuidString)"))
            let session = try #require(WorkspaceFileEditSession(
                identity: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: path),
                disk: WorkspaceFileDiskSnapshot(bytes: Data(text.utf8), etag: "\"sha256-\(String(repeating: "a", count: 64))\""),
                maxBytes: 100_000,
                transport: WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .notSent }),
                draftStore: WorkspaceFileDraftStore(
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent("editor-wrap-open-\(UUID().uuidString)")
                ),
                idleDelay: .seconds(600)
            ))
            let controller = WorkspaceFileEditorViewController(
                session: session, themeID: .dark, preferences: CodeEditorPreferences(defaults: defaults)
            ) { _ in UIViewController() }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.loadViewIfNeeded()
            controller.updatePropertiesIfNeeded()
            window.layoutIfNeeded()
            defer { hideTestWindow(window) }
            let firstLine = try #require(controller.textView.fragmentFrame(containing: 0))
            #expect((firstLine.width <= controller.textView.bounds.width) == wraps, "\(path) wraps: \(wraps)")
        }
    }

    // MARK: - Gutter

    /// A vertical run of drawn pixels in the gutter: one number.
    private struct Ink {
        /// Content-space y of the run's top and bottom edge; digits sit on the baseline.
        let top: CGFloat
        let bottom: CGFloat
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// Runs the gutter's own `draw` into an image and reads the numbers back.
    private func drawnNumbers(_ gutter: CodeEditorGutterView) throws -> [Ink] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: gutter.bounds.size, format: format).image { _ in
            gutter.draw(gutter.bounds)
        }
        let cgImage = try #require(image.cgImage)
        let data = try #require(cgImage.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        let step = cgImage.bitsPerPixel / 8
        let width = cgImage.width
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            (0..<3).map { Int(bytes[y * cgImage.bytesPerRow + x * step + $0]) }
        }
        let background = pixel(1, 1)
        // The divider runs down the right edge.
        let inkWidth = width - 8
        var runs: [Ink] = []
        var current: (top: Int, bottom: Int, minX: Int, maxX: Int)?
        func close() {
            guard let run = current else { return }
            runs.append(Ink(
                top: gutter.frame.minY + CGFloat(run.top) / 2, bottom: gutter.frame.minY + CGFloat(run.bottom + 1) / 2,
                minX: CGFloat(run.minX) / 2, maxX: CGFloat(run.maxX + 1) / 2
            ))
            current = nil
        }
        for y in 0..<cgImage.height {
            var minX = Int.max
            var maxX = -1
            for x in 0..<inkWidth where zip(pixel(x, y), background).contains(where: { abs($0 - $1) > 24 }) {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            if maxX < 0 {
                close()
            } else if let run = current {
                current = (run.top, y, min(run.minX, minX), max(run.maxX, maxX))
            } else {
                current = (y, y, minX, maxX)
            }
        }
        close()
        return runs
    }

    /// Row geometry of the paragraphs near the viewport. The glyphs render at the
    /// text layout fragment's frame plus the container inset, so that is the
    /// truth; `caretRect` is not: it is snapped to device pixels, 2 pt taller than
    /// the row, and starts about 1 pt above it.
    private struct Rows {
        /// Content-space top and baseline of each paragraph's first row, by line.
        var firstRows: [Int: (top: CGFloat, baseline: CGFloat)] = [:]
        var rowHeight: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
    }

    private func rows(_ textView: CodeEditorTextView, lineStarts: [Int]) throws -> Rows {
        let gutter = try gutter(of: textView)
        let layout = try #require(textView.textLayoutManager)
        let content = try #require(layout.textContentManager)
        var result = Rows()
        result.top = gutter.frame.minY
        result.bottom = gutter.frame.maxY
        let probe = try #require(textView.closestPosition(to: CGPoint(x: textView.bounds.midX, y: result.top + 1)))
        let probeOffset = textView.offset(from: textView.beginningOfDocument, to: probe)
        var line = max(0, (lineStarts.lastIndex(where: { $0 <= probeOffset }) ?? 0) - 1)
        while line < lineStarts.count {
            let location = try #require(content.location(content.documentRange.location, offsetBy: lineStarts[line]))
            let fragment = try #require(layout.textLayoutFragment(for: location))
            let top = fragment.layoutFragmentFrame.minY + textView.textContainerInset.top
            if top > result.bottom { break }
            // A paragraph TextKit has not laid out has no rows: above the viewport.
            guard let row = fragment.textLineFragments.first else { line += 1; continue }
            result.rowHeight = row.typographicBounds.height
            result.firstRows[line] = (top, top + row.typographicBounds.minY + row.glyphOrigin.y)
            // UIKit's own baseline for the row agrees with the fragment's.
            layout.enumerateTextSegments(in: try #require(fragment.rangeInElement), type: .standard, options: []) { _, frame, baseline, _ in
                #expect(abs(frame.minY + textView.textContainerInset.top + baseline - (top + row.typographicBounds.minY + row.glyphOrigin.y)) < 0.01)
                return false
            }
            line += 1
        }
        return result
    }

    private func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        var location = 0
        for unit in text.utf16 {
            location += 1
            if unit == 0x0A { starts.append(location) }
        }
        return starts
    }

    /// The gutter shows a number on the first row of every paragraph that starts
    /// in view, nothing anywhere else, and a number at the top when the
    /// paragraph there started above the screen.
    private func expectGutterMatchesRows(
        _ controller: WorkspaceFileEditorViewController, text: String, _ label: String
    ) throws {
        let textView = controller.textView
        let gutter = try gutter(of: textView)
        let geometry = try rows(textView, lineStarts: lineStarts(of: text))
        let inks = try drawnNumbers(gutter)
        let height = geometry.rowHeight
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: CodeEditorGutterView.numberFont(for: try #require(textView.font))]).width

        // Every paragraph whose first row is fully in the band has its number on that row.
        var straddler: (line: Int, baseline: CGFloat)?
        for (line, row) in geometry.firstRows.sorted(by: { $0.key < $1.key }) {
            if row.top < geometry.top { straddler = (line, row.baseline); continue }
            guard row.top + height <= geometry.bottom else { continue }
            let digits = String(line + 1).count
            let match = inks.first { abs($0.bottom - row.baseline) < 1.0 }
            #expect(match != nil, "\(label): line \(line + 1) has no number on its first row (baseline \(row.baseline - geometry.top) in the band; numbers at \(inks.map { $0.bottom - geometry.top }))")
            if let match {
                #expect(abs((match.maxX - match.minX) - CGFloat(digits) * digitWidth) < digitWidth, "\(label): line \(line + 1) has the wrong number of digits")
            }
        }
        // A number at any other height is a number on no row.
        for ink in inks {
            // The band's bottom edge cuts a number whose row is half out of view.
            if ink.bottom >= geometry.bottom - 0.5 { continue }
            if geometry.firstRows.values.contains(where: { abs($0.baseline - ink.bottom) < 1.0 }) { continue }
            #expect(straddler != nil && ink.top < geometry.top + height * 1.5, "\(label): a number at \(ink.bottom - geometry.top) sits on no paragraph's first row")
            // A pinned number sits on a row of the paragraph that started above.
            if let straddler, height > 0 {
                let remainder = abs(ink.bottom - straddler.baseline).truncatingRemainder(dividingBy: height)
                #expect(min(remainder, height - remainder) < 1.0, "\(label): the pinned number is off its paragraph's row grid")
            }
        }
        // The first row on screen always carries a number.
        if let first = inks.first {
            #expect(first.top < geometry.top + height * 1.5, "\(label): the top of the gutter is empty until \(first.top - geometry.top)")
        } else {
            Issue.record("\(label): the gutter draws no numbers")
        }
    }

    private static let wrappedLines: [String] = (0..<600).map { index in
        "\(index + 1): " + String(repeating: "lorem ipsum ", count: (index * 37) % 70 + 1)
    }

    @Test func gutterNumbersStayOnTheirFirstRowsAfterJumpsInAWrappedDocument() async throws {
        let text = Self.wrappedLines.joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "notes.md", text: text)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        for fraction in [0.35, 0.8, 0.15, 0.6, 0.95, 0.5, 0.0] {
            let maxY = max(0, textView.contentSize.height - textView.bounds.height)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: maxY * fraction), animated: false)
            window.layoutIfNeeded()
            try expectGutterMatchesRows(controller, text: text, "jump to \(fraction)")
            // TextKit replaces estimated heights on a later pass and moves the rows.
            try await Task.sleep(for: .milliseconds(60))
            window.layoutIfNeeded()
            try expectGutterMatchesRows(controller, text: text, "jump to \(fraction), a layout pass later")
        }
    }

    @Test func gutterFollowsScrollingRotationAndEditsInAWrappedDocument() async throws {
        let text = Self.wrappedLines.joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "notes.md", text: text)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        textView.setContentOffset(CGPoint(x: 0, y: textView.contentSize.height * 0.4), animated: false)
        window.layoutIfNeeded()
        for step in 0..<6 {
            textView.setContentOffset(CGPoint(x: 0, y: textView.contentOffset.y + 137), animated: false)
            window.layoutIfNeeded()
            try expectGutterMatchesRows(controller, text: text, "scroll step \(step)")
        }

        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        window.layoutIfNeeded()
        try expectGutterMatchesRows(controller, text: text, "landscape")
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        window.layoutIfNeeded()
        try expectGutterMatchesRows(controller, text: text, "portrait again")

        // A line break typed in view renumbers every line below it.
        let probe = try #require(textView.closestPosition(to: CGPoint(x: textView.bounds.midX, y: gutter(of: textView).frame.minY + 200)))
        textView.selectedRange = NSRange(location: textView.offset(from: textView.beginningOfDocument, to: probe), length: 0)
        textView.insertText("\n")
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        window.layoutIfNeeded()
        try expectGutterMatchesRows(controller, text: textView.text, "after a line break")
    }

    @Test func aParagraphTallerThanTheScreenKeepsItsNumberAtTheTop() async throws {
        let giant = "giant " + String(repeating: "paragraph that wraps over and over ", count: 400)
        let text = ["first", giant, "third", "fourth"].joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "notes.md", text: text)
        defer { hideTestWindow(window) }
        let textView = controller.textView
        let start = try caret(textView, at: offset(ofLine: 1, in: text)).minY
        for depth in [300.0, 900.0, 2_000.0] {
            textView.setContentOffset(CGPoint(x: 0, y: start + depth), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            window.layoutIfNeeded()
            let inks = try drawnNumbers(gutter(of: textView))
            let top = try gutter(of: textView).frame.minY
            #expect(inks.count == 1, "only the giant paragraph is on screen; numbers at \(inks.map { $0.bottom - top })")
            #expect((inks.first?.top ?? .infinity) < top + (textView.font?.lineHeight ?? 18) * 1.5, "its number is pinned at the top, \(depth) pt in")
        }
    }

    @Test func lineNumbersShowWithSyntaxHighlightingOff() throws {
        let text = Self.wrappedLines.prefix(40).joined(separator: "\n")
        let (controller, window) = try makeEditor(path: "notes.md", text: text, highlightsSyntax: false)
        defer { hideTestWindow(window) }
        try expectGutterMatchesRows(controller, text: text, "syntax highlighting off")
    }
}
