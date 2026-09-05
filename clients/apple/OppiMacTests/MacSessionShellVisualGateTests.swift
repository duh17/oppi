import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Oppi

@MainActor
final class MacSessionShellVisualGateTests: XCTestCase {
    func testNormalSessionPaintsTimelineToolRowAndComposer() throws {
        let recorder = MacSessionShellGeometryRecorder()
        let image = try captureShell(
            width: 1_200,
            height: 760,
            recorder: recorder,
            hasDocument: false,
            inspectorRequested: false
        )

        addStructuralAttachment(
            image,
            name: "mac-session-shell-normal-dark-1200x760-structural"
        )
        assertCaptureBounds(image, expectedWidth: 1_200, expectedHeight: 760)
        XCTAssertEqual(recorder.layout, .timelineOnly)
        let sidebarFrame = try XCTUnwrap(recorder.sidebarFrame)
        let listFrame = try XCTUnwrap(recorder.listFrame)
        let detailFrame = try XCTUnwrap(recorder.detailFrame)
        XCTAssertNotNil(recorder.timelineFrame)
        XCTAssertNil(recorder.documentFrame)
        XCTAssertNil(recorder.inspectorFrame)
        XCTAssertLessThanOrEqual(
            sidebarFrame.maxX,
            listFrame.minX + 1,
            "The themed sidebar must not overlap the session-list controls"
        )
        XCTAssertLessThanOrEqual(
            listFrame.maxX,
            detailFrame.minX + 1,
            "List-owned search and refresh must stay out of the conversation column"
        )
    }

    func testFullShellRepaintsForLightTheme() throws {
        let dark = try captureShell(
            width: 1_200,
            height: 760,
            recorder: MacSessionShellGeometryRecorder(),
            hasDocument: false,
            inspectorRequested: false
        )
        let light = try captureShell(
            width: 1_200,
            height: 760,
            recorder: MacSessionShellGeometryRecorder(),
            hasDocument: false,
            inspectorRequested: false,
            themeID: .light
        )

        addStructuralAttachment(
            light,
            name: "mac-session-shell-normal-light-1200x760-structural"
        )
        let samplePoint = CGPoint(x: 900, y: 300)
        XCTAssertGreaterThan(
            luminance(in: light, at: samplePoint) - luminance(in: dark, at: samplePoint),
            0.35,
            "The mounted full shell must repaint its surfaces when the active theme changes"
        )
    }

    func testDocumentLayoutAtMinimumAndWideWindowSizes() throws {
        let minimumRecorder = MacSessionShellGeometryRecorder()
        let minimum = try captureShell(
            width: 980,
            height: 620,
            recorder: minimumRecorder
        )
        addStructuralAttachment(minimum, name: "mac-session-shell-document-980x620-structural")
        assertCaptureBounds(minimum, expectedWidth: 980, expectedHeight: 620)
        XCTAssertEqual(
            minimumRecorder.layout,
            .documentOnly,
            "At the 980 pt app minimum, the document should replace the constrained timeline"
        )
        XCTAssertNil(minimumRecorder.timelineFrame)
        XCTAssertNotNil(
            minimumRecorder.inspectorFrame,
            "The requested file browser must remain in the right sidebar beside a document"
        )
        let minimumDetailFrame = try XCTUnwrap(minimumRecorder.detailFrame)
        let minimumDocumentFrame = try XCTUnwrap(minimumRecorder.documentFrame)
        assertContained(
            minimumDocumentFrame,
            in: minimumDetailFrame,
            context: "minimum document"
        )

        let wideRecorder = MacSessionShellGeometryRecorder()
        let wide = try captureShell(
            width: 1_600,
            height: 800,
            recorder: wideRecorder
        )
        addStructuralAttachment(wide, name: "mac-session-shell-document-1600x800-structural")
        assertCaptureBounds(wide, expectedWidth: 1_600, expectedHeight: 800)
        XCTAssertEqual(
            wideRecorder.layout,
            .timelineAndDocument,
            "A wide shell should keep the timeline and document side by side"
        )
        XCTAssertNotNil(
            wideRecorder.inspectorFrame,
            "Wide windows should keep file navigation available beside the document"
        )
        let wideDetailFrame = try XCTUnwrap(wideRecorder.detailFrame)
        let wideTimelineFrame = try XCTUnwrap(wideRecorder.timelineFrame)
        let wideDocumentFrame = try XCTUnwrap(wideRecorder.documentFrame)
        assertContained(wideTimelineFrame, in: wideDetailFrame, context: "wide timeline")
        assertContained(wideDocumentFrame, in: wideDetailFrame, context: "wide document")
        XCTAssertLessThanOrEqual(
            wideTimelineFrame.maxX,
            wideDocumentFrame.minX + 1,
            "The timeline must not overlap the document column"
        )
        XCTAssertGreaterThanOrEqual(
            wideTimelineFrame.width,
            MacSessionShellLayoutPolicy.timelineMinimumWidth - 1
        )
        XCTAssertGreaterThanOrEqual(
            wideDocumentFrame.width,
            MacToolDocumentColumnMetrics.minWidth - 1
        )
    }

    func testDiffDocumentPaintsStructuredUnifiedChanges() throws {
        let descriptor = ToolContentDescriptor.diff(
            ToolContentDescriptor.Diff(
                lines: DiffEngine.compute(
                    old: """
                    struct ToolRow: View {
                        let title: String

                        var body: some View {
                            Text(title)
                                .padding(12)
                                .background(Color.gray)
                        }
                    }
                    """,
                    new: """
                    struct ToolRow: View {
                        let title: String

                        var body: some View {
                            Label(title, systemImage: "hammer")
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(.themeToolSuccessBg)
                        }
                    }
                    """,
                    oldStartLine: 42
                ),
                path: "clients/apple/OppiMac/Views/MacSessionTimelineViews.swift"
            )
        )
        let image = try captureDocument(
            width: 760,
            height: 560,
            path: "clients/apple/OppiMac/Views/MacSessionTimelineViews.swift",
            descriptor: descriptor,
            minimumPaintedFraction: 0.015
        )

        addStructuralAttachment(
            image,
            name: "mac-document-diff-dark-760x560-structural"
        )
        assertCaptureBounds(image, expectedWidth: 760, expectedHeight: 560)
        XCTAssertEqual(MacToolDocumentColumnPaint.surface(for: descriptor), .diff)
        XCTAssertGreaterThan(
            bodyPaintedFraction(in: image),
            0.015,
            "The structured diff body should visibly paint added and removed rows"
        )
        let changedBands = diffChangedBandMetrics(in: image)
        XCTAssertLessThan(
            changedBands.firstY,
            180,
            "Diff content should start near the top of the document instead of centering vertically"
        )
        XCTAssertLessThan(
            changedBands.totalHeight,
            150,
            "Seven changed rows should remain single-line at 760 pt instead of wrapping mid-token"
        )
        XCTAssertGreaterThan(
            changedBands.horizontalCoverage,
            0.9,
            "Changed rows should fill the viewport instead of forming a narrow centered column"
        )
    }

    func testMermaidMarkdownDocumentPaintsNativeDiagram() throws {
        let diagram = """
        flowchart LR
            stream[Live events] --> reducer{Session reducer}
            reducer -->|timeline| list[Timeline]
            reducer -->|tool output| document[Document]
            document --> verified[Visual gate]
        """
        let markdown = """
        ```mermaid
        \(diagram)
        ```
        """
        let descriptor = ToolContentDescriptor.markdown(
            ToolContentDescriptor.Markdown(text: markdown)
        )
        let image = try captureDocument(
            width: 760,
            height: 560,
            path: "docs/live-session-rendering.md",
            descriptor: descriptor,
            minimumPaintedFraction: 0.025
        )

        addStructuralAttachment(
            image,
            name: "mac-document-mermaid-native-dark-760x560-structural"
        )
        assertCaptureBounds(image, expectedWidth: 760, expectedHeight: 560)
        XCTAssertEqual(MacToolDocumentColumnPaint.surface(for: descriptor), .markdown)
        let kinds = MacMarkdownPaintDispatch.kinds(from: markdown)
        XCTAssertEqual(kinds.count, 1)
        guard case .mermaidDiagram(let parsedDiagram) = kinds.first else {
            return XCTFail("The markdown fixture must dispatch to the native Mermaid painter")
        }
        XCTAssertEqual(
            parsedDiagram.trimmingCharacters(in: .whitespacesAndNewlines),
            diagram
        )
        XCTAssertGreaterThan(
            bodyPaintedFraction(in: image),
            0.025,
            "The Mermaid document should finish rasterizing beyond its loading indicator"
        )
    }

    func testWorkspaceFileBrowserInspectorRepaintsForLightTheme() throws {
        let dark = try captureFileBrowser(themeID: .dark)
        let light = try captureFileBrowser(themeID: .light)

        addStructuralAttachment(
            dark,
            name: "mac-file-browser-inspector-dark-320x620-structural"
        )
        addStructuralAttachment(
            light,
            name: "mac-file-browser-inspector-light-320x620-structural"
        )
        assertCaptureBounds(dark, expectedWidth: 320, expectedHeight: 620)
        assertCaptureBounds(light, expectedWidth: 320, expectedHeight: 620)
        let samplePoint = CGPoint(x: 280, y: 300)
        XCTAssertGreaterThan(
            luminance(in: light, at: samplePoint) - luminance(in: dark, at: samplePoint),
            0.35,
            "The mounted file-browser inspector must repaint its surface for the active theme"
        )
    }

    func testVoicePlaybackControlPaintsIdleLoadingPlayingAndFailureStates() throws {
        let width: CGFloat = 520
        let height: CGFloat = 170
        let root = MacToolAudioPlaybackStateVisualFixture()
            .frame(width: width, height: height)
            .environment(\.theme, AppTheme.dark)
            .environment(\.themeID, ThemeID.dark)
            .tint(.themePurple)
            .preferredColorScheme(.dark)
        let image = try captureHostedView(root, width: width, height: height)

        addStructuralAttachment(
            image,
            name: "mac-voice-playback-states-dark-520x170-structural"
        )
        assertCaptureBounds(image, expectedWidth: width, expectedHeight: height)
        XCTAssertGreaterThan(
            bodyPaintedFraction(in: image),
            0.02,
            "All four real voice-control states should visibly paint"
        )
        XCTAssertEqual(
            MacToolAudioPlaybackButtonPaint.make(for: .idle).accessibilityLabel,
            "Play voice message"
        )
        XCTAssertEqual(
            MacToolAudioPlaybackButtonPaint.make(for: .loading).accessibilityLabel,
            "Stop voice message"
        )
        XCTAssertEqual(
            MacToolAudioPlaybackButtonPaint.make(for: .playing).systemImage,
            "stop.fill"
        )
        XCTAssertTrue(
            MacToolAudioPlaybackButtonPaint.make(for: .failed("Unavailable")).isFailure
        )
    }

    func testContentSizedCodeAtExactTextWidthDoesNotCreateHorizontalScroller() throws {
        let code = "echo boundary"
        let attributedCode = MacSyntaxHighlighter.attributedCode(
            code,
            language: .shell
        )
        let width = unwrappedCodeWidth(attributedCode)
        let root = MacReviewCommentTextView(
            text: code,
            attributedText: attributedCode,
            source: MacReviewCommentSource(kind: .timelineText),
            fillsColumn: false,
            heightBehavior: .fitContent(maxHeight: 360)
        )
        .frame(width: width)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .preferredColorScheme(.dark)

        try withHostedView(root, width: width, height: 100) { host, _ in
            host.layoutSubtreeIfNeeded()
            let scrollView = try XCTUnwrap(descendantViews(in: host).first {
                $0 is NSScrollView
                    && $0.identifier?.rawValue == "mac.reviewComment.text"
            } as? NSScrollView)
            let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
            let textContainer = try XCTUnwrap(textView.textContainer)
            let layoutManager = try XCTUnwrap(textView.layoutManager)
            layoutManager.ensureLayout(for: textContainer)
            let requiredWidth = ceil(
                layoutManager.usedRect(for: textContainer).width
                    + textView.textContainerInset.width * 2
            )

            XCTAssertEqual(scrollView.frame.width, width, accuracy: 0.5)
            XCTAssertEqual(scrollView.contentView.bounds.width, requiredWidth, accuracy: 0.5)
            XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
            XCTAssertFalse(
                scrollView.hasHorizontalScroller,
                "TextKit line-fragment padding is already present in usedRect and must not force overflow"
            )
        }
    }

    func testContentSizedCodeOverHeightCapUsesVerticalScrollerAndClipWidth() throws {
        let code = (1...40)
            .map { String(format: "echo line %02d", $0) }
            .joined(separator: "\n")
        let width: CGFloat = 240
        let maximumHeight: CGFloat = 80
        let root = MacReviewCommentTextView(
            text: code,
            attributedText: MacSyntaxHighlighter.attributedCode(
                code,
                language: .shell
            ),
            source: MacReviewCommentSource(kind: .timelineText),
            fillsColumn: false,
            heightBehavior: .fitContent(maxHeight: maximumHeight)
        )
        .frame(width: width)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .preferredColorScheme(.dark)

        try withHostedView(root, width: width, height: 140) { host, _ in
            host.layoutSubtreeIfNeeded()
            let scrollView = try XCTUnwrap(descendantViews(in: host).first {
                $0 is NSScrollView
                    && $0.identifier?.rawValue == "mac.reviewComment.text"
            } as? NSScrollView)
            let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)

            scrollView.scrollerStyle = .legacy
            scrollView.invalidateIntrinsicContentSize()
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()

            XCTAssertEqual(scrollView.frame.height, maximumHeight, accuracy: 0.5)
            XCTAssertTrue(scrollView.hasVerticalScroller)
            XCTAssertFalse(scrollView.hasHorizontalScroller)
            XCTAssertGreaterThan(textView.frame.height, scrollView.contentView.bounds.height)
            XCTAssertEqual(textView.frame.width, scrollView.contentView.bounds.width, accuracy: 0.5)
        }
    }

    func testPlainFencedCodeMarkdownUsesContentSizedViewports() throws {
        let shortCode = "echo ready"
        let longCode = [
            "printf 'first line\\n'",
            "tools/fruitstand reminders add \"A deliberately long reminder title that must scroll horizontally instead of widening its ordered-list parent\" --list Personal",
            "printf 'last line\\n'",
        ].joined(separator: "\n")
        let markdown = """
        ## Safe sequence
        1. Verify the short command:
           ```bash
           \(shortCode)
           ```
        2. Run the longer command without collapsing its body:
           ```bash
           printf 'first line\\n'
           tools/fruitstand reminders add "A deliberately long reminder title that must scroll horizontally instead of widening its ordered-list parent" --list Personal
           printf 'last line\\n'
           ```
        3. Continue after both complete.
        """
        let width: CGFloat = 520
        let height: CGFloat = 420
        let root = ScrollView {
            MacMarkdownDocumentView(markdown: markdown)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(width: width, height: height)
        .background(AppTheme.dark.bg.primary)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .tint(.themeBlue)
        .preferredColorScheme(.dark)

        let image = try withHostedView(root, width: width, height: height) { host, _ in
            host.layoutSubtreeIfNeeded()
            let codeScrollViews = descendantViews(in: host)
                .compactMap { $0 as? NSScrollView }
                .filter {
                    $0.identifier?.rawValue == "mac.reviewComment.text"
                        && $0.documentView is MacReviewCommentTextViewBridge
                }
            XCTAssertEqual(codeScrollViews.count, 2)

            let shortViewport = try XCTUnwrap(codeScrollViews.first {
                ($0.documentView as? NSTextView)?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines) == shortCode
            })
            let longViewport = try XCTUnwrap(codeScrollViews.first {
                ($0.documentView as? NSTextView)?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines) == longCode
            })

            XCTAssertGreaterThanOrEqual(shortViewport.frame.height, 30)
            XCTAssertLessThanOrEqual(shortViewport.frame.height, 60)
            XCTAssertFalse(
                shortViewport.hasHorizontalScroller,
                "A short code fence must not paint an empty horizontal scrollbar track"
            )
            XCTAssertEqual(
                shortViewport.documentView?.frame.width ?? 0,
                shortViewport.contentView.bounds.width,
                accuracy: 0.5,
                "A fitting code document should exactly fill its clip width"
            )

            XCTAssertGreaterThanOrEqual(
                longViewport.frame.height,
                64,
                "A multiline fence must paint all short lines instead of collapsing to scroll chrome"
            )
            XCTAssertLessThanOrEqual(longViewport.frame.height, 120)
            XCTAssertTrue(
                longViewport.hasHorizontalScroller,
                "Only the deliberately overflowing line should enable horizontal scrolling"
            )
            XCTAssertLessThanOrEqual(
                longViewport.horizontalScroller?.frame.height ?? 0,
                20,
                "The horizontal scroller must remain normal Mac chrome"
            )
            XCTAssertGreaterThan(
                longViewport.documentView?.frame.width ?? 0,
                longViewport.contentView.bounds.width,
                "An overflowing code document must be wider than its clip viewport"
            )

            for viewport in codeScrollViews {
                let frame = host.convert(viewport.bounds, from: viewport)
                XCTAssertGreaterThanOrEqual(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                XCTAssertLessThanOrEqual(viewport.frame.height, 360)
            }
            return try snapshot(host)
        }

        addStructuralAttachment(
            image,
            name: "mac-markdown-ordered-fenced-code-dark-520x420-structural"
        )
        assertCaptureBounds(image, expectedWidth: width, expectedHeight: height)
    }

    private func captureShell(
        width: CGFloat,
        height: CGFloat,
        recorder: MacSessionShellGeometryRecorder,
        hasDocument: Bool = true,
        inspectorRequested: Bool = true,
        themeID: ThemeID = .dark
    ) throws -> NSImage {
        let store = makeStore()
        let root = MacSessionShellVisualFixture(
            store: store,
            recorder: recorder,
            hasDocument: hasDocument,
            inspectorRequested: inspectorRequested
        )
            .frame(width: width, height: height)
            .environment(\.theme, themeID.appTheme)
            .environment(\.themeID, themeID)
            .tint(.themeBlue)
            .preferredColorScheme(themeID.preferredColorScheme)

        return try captureHostedView(
            root,
            width: width,
            height: height,
            themeID: themeID
        )
    }

    private func captureDocument(
        width: CGFloat,
        height: CGFloat,
        path: String,
        descriptor: ToolContentDescriptor,
        minimumPaintedFraction: Double
    ) throws -> NSImage {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        ThemeRuntimeState.setThemeID(.dark)
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        let plan = FileViewerPlan.workspaceFile(
            workspaceID: "visual-workspace",
            path: path
        )
        let root = MacToolDocumentColumn(
            plan: plan,
            descriptor: descriptor,
            isLoading: false,
            error: nil,
            close: {}
        )
        .frame(width: width, height: height)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .tint(.themeBlue)
        .preferredColorScheme(.dark)

        return try captureHostedView(
            root,
            width: width,
            height: height,
            waitUntil: { self.bodyPaintedFraction(in: $0) >= minimumPaintedFraction }
        )
    }

    private func captureFileBrowser(themeID: ThemeID) throws -> NSImage {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let workspace = Workspace(
            id: "visual-file-browser",
            name: "Oppi",
            description: nil,
            icon: .symbol("folder"),
            hostMount: nil,
            createdAt: now,
            updatedAt: now
        )
        let root = MacWorkspaceFileBrowserView(
            workspace: workspace,
            worktreeId: WorkspaceWorktree.mainId,
            openPlan: .constant(nil)
        )
        .frame(width: 320, height: 620)
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .tint(.themeBlue)
        .preferredColorScheme(themeID.preferredColorScheme)

        return try captureHostedView(
            root,
            width: 320,
            height: 620,
            themeID: themeID
        )
    }

    private func captureHostedView<Content: View>(
        _ root: Content,
        width: CGFloat,
        height: CGFloat,
        themeID: ThemeID = .dark,
        waitUntil: ((NSImage) -> Bool)? = nil
    ) throws -> NSImage {
        try withHostedView(
            root,
            width: width,
            height: height,
            themeID: themeID
        ) { host, _ in
            var image = try snapshot(host)
            guard let waitUntil else { return image }

            let deadline = Date().addingTimeInterval(2)
            while !waitUntil(image), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                image = try snapshot(host)
            }
            return image
        }
    }

    private func withHostedView<Content: View, Result>(
        _ root: Content,
        width: CGFloat,
        height: CGFloat,
        themeID: ThemeID = .dark,
        operation: (NSHostingView<Content>, NSWindow) throws -> Result
    ) throws -> Result {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(
            named: themeID.preferredColorScheme == .light ? .aqua : .darkAqua
        )
        window.backgroundColor = NSColor(themeID.appTheme.bg.primary)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return try operation(host, window)
    }

    private func snapshot<Content>(_ host: NSHostingView<Content>) throws -> NSImage {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MacSessionShellVisualGateError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func descendantViews(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendantViews(in: $0) }
    }

    private func unwrappedCodeWidth(_ attributedCode: NSAttributedString) -> CGFloat {
        let textStorage = NSTextStorage(attributedString: attributedCode)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        textContainer.lineFragmentPadding = 4
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).width + 16)
    }


    private func luminance(in image: NSImage, at point: CGPoint) -> CGFloat {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else {
            XCTFail("Expected a bitmap-backed visual-gate image")
            return 0
        }
        let x = min(
            max(Int(point.x / image.size.width * CGFloat(bitmap.pixelsWide)), 0),
            bitmap.pixelsWide - 1
        )
        let y = min(
            max(Int(point.y / image.size.height * CGFloat(bitmap.pixelsHigh)), 0),
            bitmap.pixelsHigh - 1
        )
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            XCTFail("Expected an sRGB sample from the full-shell image")
            return 0
        }
        return 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
    }

    private func makeStore() -> MacSessionTraceStore {
        let store = MacSessionTraceStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "visual-shell",
            workspaceId: "visual-workspace",
            workspaceName: "Oppi",
            status: .ready,
            createdAt: now,
            lastActivity: now,
            model: "openai/gpt-5.6-sol",
            messageCount: 12,
            tokens: TokenUsage(input: 48_200, output: 3_400),
            cost: 2.31,
            firstMessage: "Inspect the live Mac session shell",
            thinkingLevel: "high",
            runtime: .oppi
        )
        store.select(MacSelectedSessionTarget(
            workspaceId: "visual-workspace",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        ))
        return store
    }

    private func assertCaptureBounds(
        _ image: NSImage,
        expectedWidth: CGFloat,
        expectedHeight: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(image.size.width, expectedWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(image.size.height, expectedHeight, accuracy: 1, file: file, line: line)
    }

    private func assertContained(
        _ frame: CGRect,
        in bounds: CGRect,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 1, "\(context) escaped left", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 1, "\(context) escaped right", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 1, "\(context) escaped bottom", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 1, "\(context) escaped top", file: file, line: line)
    }

    private func addStructuralAttachment(_ image: NSImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Counts document-body pixels that visibly differ from the live themed
    /// surface. Polling this paint signal lets async Mermaid rasterization
    /// finish without a blind sleep while keeping the visual gate deterministic.
    private func bodyPaintedFraction(in image: NSImage) -> Double {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = bitmap.bitmapData,
              bitmap.bitsPerSample == 8,
              bitmap.samplesPerPixel >= 3,
              !bitmap.isPlanar
        else {
            return 0
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let sampleCount = min(bitmap.samplesPerPixel, bytesPerPixel)
        let horizontalInset = max(1, Int(CGFloat(width) * 24 / image.size.width))
        let verticalInset = max(1, Int(CGFloat(height) * 72 / image.size.height))
        guard width > horizontalInset * 2, height > verticalInset * 2 else { return 0 }

        let baseX = width - max(1, horizontalInset / 2)
        let baseY = height / 2
        let baseOffset = baseY * bitmap.bytesPerRow + baseX * bytesPerPixel
        let base = (0..<sampleCount).map { data[baseOffset + $0] }
        let step = max(1, Int(CGFloat(width) / image.size.width * 2))
        let differenceThreshold = 18 * 18
        var painted = 0
        var sampled = 0

        for y in stride(from: verticalInset, to: height - verticalInset, by: step) {
            for x in stride(from: horizontalInset, to: width - horizontalInset, by: step) {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                var distance = 0
                for component in 0..<sampleCount {
                    let delta = Int(data[offset + component]) - Int(base[component])
                    distance += delta * delta
                }
                if distance > differenceThreshold {
                    painted += 1
                }
                sampled += 1
            }
        }
        return sampled == 0 ? 0 : Double(painted) / Double(sampled)
    }

    private func diffChangedBandMetrics(in image: NSImage) -> (
        horizontalCoverage: Double,
        firstY: CGFloat,
        totalHeight: CGFloat
    ) {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = bitmap.bitmapData,
              bitmap.bitsPerSample == 8,
              bitmap.samplesPerPixel >= 3,
              !bitmap.isPlanar
        else {
            return (0, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        }

        guard let surfaceColor = NSColor(AppTheme.dark.bg.primary).usingColorSpace(.sRGB) else {
            return (0, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        }
        let targetColors = [AppTheme.dark.diff.addedBg, AppTheme.dark.diff.removedBg]
            .compactMap { NSColor($0).usingColorSpace(.sRGB) }
            .map { color in
                let alpha = color.alphaComponent
                return [
                    Int(((color.redComponent * alpha + surfaceColor.redComponent * (1 - alpha)) * 255).rounded()),
                    Int(((color.greenComponent * alpha + surfaceColor.greenComponent * (1 - alpha)) * 255).rounded()),
                    Int(((color.blueComponent * alpha + surfaceColor.blueComponent * (1 - alpha)) * 255).rounded()),
                ]
            }
        guard targetColors.count == 2 else {
            return (0, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
        }

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let bytesPerPixel = max(1, bitmap.bitsPerPixel / 8)
        let bodyTop = max(1, Int(CGFloat(height) * 64 / image.size.height))
        let colorThreshold = 8 * 8
        var minChangedX = width
        var maxChangedX = -1
        var firstChangedY: Int?
        var changedScanlines = 0

        for y in bodyTop..<height {
            var matches = 0
            for x in 0..<width {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                let isChangedBand = targetColors.contains { target in
                    let red = Int(data[offset]) - target[0]
                    let green = Int(data[offset + 1]) - target[1]
                    let blue = Int(data[offset + 2]) - target[2]
                    return red * red + green * green + blue * blue <= colorThreshold
                }
                if isChangedBand {
                    matches += 1
                    minChangedX = min(minChangedX, x)
                    maxChangedX = max(maxChangedX, x)
                }
            }
            if matches > width / 10 {
                firstChangedY = firstChangedY ?? y
                changedScanlines += 1
            }
        }

        let horizontalCoverage = maxChangedX >= minChangedX
            ? Double(maxChangedX - minChangedX + 1) / Double(width)
            : 0
        let pixelsPerPoint = CGFloat(height) / image.size.height
        return (
            horizontalCoverage,
            firstChangedY.map { CGFloat($0) / pixelsPerPoint } ?? .greatestFiniteMagnitude,
            pixelsPerPoint > 0 ? CGFloat(changedScanlines) / pixelsPerPoint : .greatestFiniteMagnitude
        )
    }
}

@MainActor
private final class MacSessionShellGeometryRecorder {
    var layout: MacSessionShellColumnLayout?
    var sidebarFrame: CGRect?
    var listFrame: CGRect?
    var detailFrame: CGRect?
    var timelineFrame: CGRect?
    var documentFrame: CGRect?
    var inspectorFrame: CGRect?
}

private struct MacSessionShellVisualFixture: View {
    let store: MacSessionTraceStore
    let recorder: MacSessionShellGeometryRecorder
    let hasDocument: Bool
    let inspectorRequested: Bool
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var composerHeight = MacSessionTimelineOverlap.defaultComposerHeight
    @State private var searchQuery = ""
    @State private var selectedSessionID: String? = "visual-shell"
    @FocusState private var sessionFocus: KeybindingFocus?

    private let coordinateSpaceName = "mac-session-shell-visual-fixture"
    private let plan = FileViewerPlan.workspaceFile(
        workspaceID: "visual-workspace",
        path: "Sources/SessionShell.swift"
    )
    private let descriptor = ToolContentDescriptor.file(
        ToolContentDescriptor.File(
            text: "struct SessionShell {\n    let isPolished = true\n}",
            filePath: "Sources/SessionShell.swift",
            fileType: .code(language: .swift),
            language: .swift,
            startLine: 1,
            attachments: []
        )
    )

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                HStack(spacing: 8) {
                    Image(systemName: "house")
                        .foregroundStyle(.themeFg)
                        .frame(width: 18)
                    Text("Home")
                        .foregroundStyle(.themeFg)
                }
            }
            .themedListSurface()
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(coordinateSpaceName))
            } action: { recorder.sidebarFrame = $0 }
        } content: {
            MacHomeSessionList(
                targets: store.selectedTarget.map { [$0] } ?? [],
                searchQuery: $searchQuery,
                isSearching: false,
                searchMatches: nil,
                runtimeSessions: [],
                isLoadingWorkspaceSessions: false,
                workspaceSessionError: nil,
                sessionActionError: { _ in nil },
                isStoppingSession: { _ in false },
                isDeletingSession: { _ in false },
                selectedSessionID: $selectedSessionID,
                refresh: {},
                stopTarget: { _ in },
                deleteTarget: { _ in },
                selectTarget: { _ in }
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(coordinateSpaceName))
            } action: { recorder.listFrame = $0 }
        } detail: {
            GeometryReader { proxy in
                let layout = MacSessionShellLayoutPolicy.columns(
                    availableWidth: proxy.size.width,
                    hasDocument: hasDocument
                )
                sessionColumns(for: layout)
                    .background(.themeBg)
                    .onGeometryChange(for: CGRect.self) { geometry in
                        geometry.frame(in: .named(coordinateSpaceName))
                    } action: { frame in
                        recorder.layout = layout
                        recorder.detailFrame = frame
                    }
                    .overlay(alignment: .trailing) {
                        if MacSessionShellLayoutPolicy.shouldPresentInspector(
                            requested: inspectorRequested,
                            hasDocument: hasDocument
                        ) {
                            Color.clear
                                .frame(width: 320)
                                .onGeometryChange(for: CGRect.self) { geometry in
                                    geometry.frame(in: .named(coordinateSpaceName))
                                } action: { recorder.inspectorFrame = $0 }
                        }
                    }
            }
        }
        .coordinateSpace(name: coordinateSpaceName)
        .background(.themeBg)
    }

    @ViewBuilder
    private func sessionColumns(for layout: MacSessionShellColumnLayout) -> some View {
        switch layout {
        case .timelineOnly:
            timelineColumn
        case .documentOnly:
            documentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .timelineAndDocument:
            HSplitView {
                timelineColumn
                documentColumn
                    .frame(
                        minWidth: MacToolDocumentColumnMetrics.minWidth,
                        idealWidth: MacToolDocumentColumnMetrics.idealWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
            }
        }
    }

    private var timelineColumn: some View {
        MacSessionTimelineView(
            isLoading: false,
            lastError: nil,
            items: normalTimelineItems,
            sessionID: store.selectedTarget?.sessionId,
            workspaceID: store.selectedTarget?.workspaceId,
            toolOutputStore: store.toolOutputStore,
            loadFullToolOutput: { _ in },
            bottomContentInset: MacSessionTimelineOverlap.bottomContentInset(
                composerHeight: composerHeight
            ),
            isBusy: false,
            store: store,
            sessionFocus: $sessionFocus
        )
        .frame(
            minWidth: MacSessionShellLayoutPolicy.timelineMinimumWidth,
            maxWidth: .infinity,
            maxHeight: .infinity
        )
        .overlay(alignment: .bottom) {
            MacSessionComposerBar(store: store, sessionFocus: $sessionFocus)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    composerHeight = $0
                }
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(coordinateSpaceName))
        } action: { recorder.timelineFrame = $0 }
    }

    private var normalTimelineItems: [ChatItem] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            .userMessage(
                id: "visual-user",
                text: "Make the Mac timeline match iOS and keep every theme semantic.",
                timestamp: now
            ),
            .assistantMessage(
                id: "visual-assistant",
                text: "The compact row, document viewer, and composer now share the active palette.",
                timestamp: now.addingTimeInterval(1)
            ),
            .toolCall(
                id: "visual-tool",
                tool: "read",
                argsSummary: "Color+Theme.swift",
                outputPreview: "Theme tokens verified",
                outputByteCount: 21,
                isError: false,
                isDone: true
            ),
        ]
    }

    private var documentColumn: some View {
        MacToolDocumentColumn(
            plan: plan,
            descriptor: descriptor,
            isLoading: false,
            error: nil,
            close: {}
        )
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(coordinateSpaceName))
        } action: { recorder.documentFrame = $0 }
    }
}

private struct MacToolAudioPlaybackStateVisualFixture: View {
    private let phases: [(label: String, phase: MacToolAudioPlaybackPhase)] = [
        ("Ready", .idle),
        ("Loading", .loading),
        ("Playing", .playing),
        ("Retry", .failed("Voice message failed to load")),
    ]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(theme.accent.purple)
                Text("Voice message")
                    .font(.headline)
                Text("4.2s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.text.secondary)
                Spacer()
            }
            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, state in
                    VStack(spacing: 7) {
                        MacToolAudioPlaybackButtonLabel(phase: state.phase)
                        Text(state.label)
                            .font(.caption2)
                            .foregroundStyle(theme.text.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(theme.bg.primary)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.text.tertiary.opacity(0.3), lineWidth: 1)
        }
        .padding(12)
    }
}

private enum MacSessionShellVisualGateError: Error {
    case noBitmap
}
