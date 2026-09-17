import SwiftUI
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Tool timeline row full-screen activation")
struct ToolTimelineRowFullScreenActivationTests {
    private struct HostHarness {
        let window: UIWindow
        let host: UIViewController
    }

    @Test("bash output activation opens full screen instead of copying")
    func bashOutputActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .bash(command: "echo hi", output: "hi", unwrapped: true),
                copyCommandText: "echo hi",
                copyOutputText: "hi",
                isExpanded: true
            ),
            host: host,
            activate: { $0.performOutputActivation() }
        )
        #expect(host.presentedViewController == nil)
        guard case .terminal = opened.payload.content else {
            Issue.record("Expected terminal reader payload")
            return
        }
        harness.window.isHidden = true
    }

    @Test("eligible current-file activation uses navigation action without presenting output")
    func currentFileActivationUsesNavigationAction() {
        let harness = makeHostHarness()
        let host = harness.host
        var activationCount = 0
        var configuration = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: "", filePath: "docs/current.md"),
            copyOutputText: nil,
            toolNamePrefix: "write",
            isExpanded: true
        )
        configuration.currentFileOpenIntent = .init(path: "docs/current.md")
        configuration.openCurrentFile = { activationCount += 1 }
        let view = ToolTimelineRowContentView(configuration: configuration)

        host.view.addSubview(view)
        view.frame = host.view.bounds
        host.view.layoutIfNeeded()
        view.performExpandedActivation()

        #expect(activationCount == 1)
        #expect(host.presentedViewController == nil)
        let menu = view.contextMenu(for: .expanded)
        #expect(menu?.children.map(\.title) == ["Open Current File"])
        #expect(view.accessibilityCustomActions?.first?.name == "Open Current File")

        harness.window.isHidden = true
    }

    @Test("expanded code activation opens full screen")
    func expandedCodeActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .code(text: "struct App {}", language: .swift, startLine: 1, filePath: "App.swift"),
                copyCommandText: "read App.swift",
                copyOutputText: "struct App {}",
                toolNamePrefix: "read",
                isExpanded: true
            ),
            host: host,
            activate: { $0.performExpandedActivation() }
        )
        #expect(host.presentedViewController == nil)
        guard case .code(let text, _, let filePath, _) = opened.payload.content else {
            Issue.record("Expected code reader payload")
            return
        }
        #expect(text.contains("struct App"))
        #expect(filePath == "App.swift")
        harness.window.isHidden = true
    }

    @Test("expanded markdown activation opens full screen")
    func expandedMarkdownActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .markdown(text: "# Header\n\nBody"),
                copyOutputText: "# Header\n\nBody",
                toolNamePrefix: "read",
                isExpanded: true
            ),
            host: host,
            activate: { $0.performExpandedActivation() }
        )
        #expect(host.presentedViewController == nil)
        guard case .markdown(let text, _, _) = opened.payload.content else {
            Issue.record("Expected markdown reader payload")
            return
        }
        #expect(text.contains("# Header"))
        harness.window.isHidden = true
    }

    @Test("thinking overflow activation does not pageSheet-present")
    func thinkingOverflowActivationOpensReaderWithoutPresenting() throws {
        let harness = makeHostHarness()
        let host = harness.host
        var opened: ChatReaderPayload?
        var configuration = ThinkingTimelineRowConfiguration(
            isDone: true,
            previewText: "",
            fullText: Array(repeating: "line", count: 320).joined(separator: "\n")
        )
        configuration.openFullScreen = { opened = $0 }
        let view = ThinkingTimelineRowContentView(configuration: configuration)
        host.view.addSubview(view)
        _ = fittedTimelineSize(for: view, width: 360)
        host.view.layoutIfNeeded()

        view.showFullScreen()

        #expect(host.presentedViewController == nil)
        let payload = try #require(opened)
        guard case .document(let content, _) = payload.kind else {
            Issue.record("Expected document reader payload")
            harness.window.isHidden = true
            return
        }
        guard case .thinking = content else {
            Issue.record("Expected thinking reader payload")
            harness.window.isHidden = true
            return
        }
        harness.window.isHidden = true
    }

    @Test("collapsed image activation does not pageSheet-present")
    func collapsedImageActivationOpensReaderWithoutPresenting() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let image = try #require(Self.makeTestPNG())
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                collapsedImageBase64: image.pngData()?.base64EncodedString(),
                collapsedImageMimeType: "image/png",
                isExpanded: false
            ),
            host: host,
            activate: { view in
                #expect(view.presentCollapsedImagePreviewIfAvailable())
            }
        )
        #expect(host.presentedViewController == nil)
        guard case .image = opened.payload.kind else {
            Issue.record("Expected image reader payload")
            harness.window.isHidden = true
            return
        }
        harness.window.isHidden = true
    }

    @Test("chat reader destination uses embedded back chrome")
    func chatReaderDestinationUsesEmbeddedBackChrome() throws {
        let store = ChatReaderPayloadStore()
        let target = store.store(
            ChatReaderPayload(content: .plainText(content: "note", filePath: "note.txt"))
        )
        #expect(store.payload(for: target.id) != nil)

        let destination = ChatReaderDestinationView(target: target, store: store)
        let controller = try #require(destination.debugMakeControllerForTesting())
        controller.loadViewIfNeeded()
        let navigation = try #require(controller.children.first as? UINavigationController)
        #expect(
            navigation.topViewController?.navigationItem.leftBarButtonItem?.accessibilityIdentifier
                == "fullscreen-code.back"
        )
    }

    @Test("chat reader image destination uses embedded back chrome")
    func chatReaderImageDestinationUsesEmbeddedBackChrome() throws {
        let image = try #require(Self.makeTestPNG())
        let store = ChatReaderPayloadStore()
        let target = store.store(.image(image))
        let viewer = EmbeddedImageViewerView(image: image)
        let controller = viewer.debugMakeControllerForTesting()
        controller.loadViewIfNeeded()
        let navigation = try #require(controller as? UINavigationController)
        let imageController = try #require(navigation.topViewController as? FullScreenImageViewController)
        imageController.loadViewIfNeeded()
        #expect(
            imageController.navigationItem.leftBarButtonItem?.accessibilityIdentifier
                == "fullscreen-image.back"
        )
        #expect(store.payload(for: target.id) != nil)
    }

    @Test("expanded large markdown activation opens full screen")
    func expandedLargeMarkdownActivationOpensFullScreen() throws {
        let denseParagraph = String(
            repeating: "Dense markdown body with **strong**, *emphasis*, and `inline code`. ",
            count: 128
        )
        let largeMarkdown = (0..<8).map { index in
            "## Section \(index)\n\n\(denseParagraph)"
        }.joined(separator: "\n\n")
        #expect(largeMarkdown.utf8.count > 64 * 1024)

        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .markdown(text: largeMarkdown),
                copyOutputText: largeMarkdown,
                toolNamePrefix: "web_fetch",
                isExpanded: true
            ),
            host: host,
            activate: { $0.performExpandedActivation() }
        )
        #expect(host.presentedViewController == nil)
        guard case .markdown(let text, _, _) = opened.payload.content else {
            Issue.record("Expected markdown reader payload")
            return
        }
        #expect(text.utf8.count > 64 * 1024)
        harness.window.isHidden = true
    }

    @Test("streaming markdown full screen content carries markdown render hint")
    func streamingMarkdownFullScreenContentCarriesMarkdownRenderHint() throws {
        let markdown = "# Streaming plan\n\nBody"
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: markdown),
            copyOutputText: markdown,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .markdown(text: markdown),
            isDone: false
        )
        let sourceStream = SourceTraceStream(
            text: markdown,
            filePath: nil,
            isDone: false,
            finalContent: nil
        )

        let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: configuration,
            outputCopyText: configuration.copyOutputText,
            interactionPolicy: interactionPolicy,
            terminalStream: nil,
            sourceStream: sourceStream
        )

        guard case .liveSource(let snapshot, _) = fullScreenContent else {
            Issue.record("Expected .liveSource for streaming markdown content")
            return
        }
        guard case .markdown(let content, _, _)? = snapshot.finalContent else {
            Issue.record("Expected streaming markdown to carry a markdown render hint")
            return
        }
        #expect(content == markdown)
        #expect(!snapshot.isDone)
    }

    @Test("done markdown full screen content keeps tool file path")
    func doneMarkdownFullScreenContentKeepsToolFilePath() throws {
        let path = ".internal/reports/design-fixes-2026-09-07/motion/REPORT.md"
        let body = "[[.internal/reports/design-fixes-2026-09-07/motion/env-off-beta.png|env-off-beta]]"
        var configuration = makeTimelineToolConfiguration(
            expandedContent: .markdown(text: body, filePath: path),
            copyOutputText: body,
            toolNamePrefix: "read",
            isExpanded: true,
            isDone: true
        )
        configuration.workspaceID = "workspace-1"
        configuration.serverBaseURL = URL(string: "https://example.test")
        configuration.fetchWorkspaceFile = { _, _ in Data() }

        let content = ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: configuration,
            outputCopyText: body,
            terminalStream: nil
        )

        guard case .markdown(let text, let filePath, let workspaceContext) = content else {
            Issue.record("Expected done markdown full-screen content, got \(String(describing: content))")
            return
        }
        #expect(text == body)
        #expect(filePath == path)
        #expect(workspaceContext?.workspaceID == "workspace-1")
        #expect(workspaceContext?.serverBaseURL.absoluteString == "https://example.test")
    }

    @Test("streaming HTML full screen content carries HTML render hint")
    func streamingHTMLFullScreenContentCarriesHTMLRenderHint() throws {
        let html = "<h1>Streaming</h1>"
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .code(text: html, language: .html, startLine: 1, filePath: "report.html"),
            copyOutputText: html,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .code(text: html, language: .html, startLine: 1, filePath: "report.html"),
            isDone: false
        )
        let sourceStream = SourceTraceStream(
            text: html,
            filePath: "report.html",
            isDone: false,
            finalContent: nil
        )

        let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: configuration,
            outputCopyText: configuration.copyOutputText,
            interactionPolicy: interactionPolicy,
            terminalStream: nil,
            sourceStream: sourceStream
        )

        guard case .liveSource(let snapshot, _) = fullScreenContent else {
            Issue.record("Expected .liveSource for streaming HTML content")
            return
        }
        guard case .html(let content, let filePath)? = snapshot.finalContent else {
            Issue.record("Expected streaming HTML to carry an HTML render hint")
            return
        }
        #expect(content == html)
        #expect(filePath == "report.html")
        #expect(!snapshot.isDone)
    }

    @Test("done delimited table full screen content uses the table viewer")
    func doneDelimitedTableFullScreenContentUsesTableViewer() throws {
        let csv = "date,route\n2026-09-01,Lake"
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .delimitedTable(text: csv, filePath: "rides.csv"),
            copyOutputText: csv,
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: true
        )

        let content = ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: configuration,
            outputCopyText: csv,
            terminalStream: nil
        )

        guard case .delimitedTable(let text, let filePath) = content else {
            Issue.record("Expected delimited-table full-screen content, got \(String(describing: content))")
            return
        }
        #expect(text == csv)
        #expect(filePath == "rides.csv")
    }

    @Test("expanded delimited table activation opens full screen")
    func expandedDelimitedTableActivationOpensFullScreen() throws {
        let csv = "date,route\n2026-09-01,Lake"
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .delimitedTable(text: csv, filePath: "rides.csv"),
                copyOutputText: csv,
                toolNamePrefix: "write",
                isExpanded: true
            ),
            host: host,
            activate: { view in
                #expect(view.expandedTapCopyGestureEnabledForTesting)
                view.performExpandedActivation()
            }
        )
        #expect(host.presentedViewController == nil)
        guard case .delimitedTable(let text, let filePath) = opened.payload.content else {
            Issue.record("Expected delimited-table reader payload")
            return
        }
        #expect(text == csv)
        #expect(filePath == "rides.csv")
        harness.window.isHidden = true
    }

    @Test("expanded text activation opens full screen")
    func expandedTextActivationOpensFullScreen() throws {
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .text(text: "Saved to journal: 2026-03-07.md", language: nil),
                copyOutputText: "Saved to journal: 2026-03-07.md",
                toolNamePrefix: "recall",
                isExpanded: true
            ),
            host: host,
            activate: { $0.performExpandedActivation() }
        )
        #expect(host.presentedViewController == nil)
        harness.window.isHidden = true
    }

    @Test("expanded edit diff shows highlighted lines in the full-screen body")
    func expandedEditDiffShowsVisibleFullScreenBody() async throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }

        let lines = [
            DiffLine(kind: .removed, text: "let value = 1", oldLineNumber: 1, newLineNumber: nil),
            DiffLine(kind: .added, text: "let value = 2", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(kind: .added, text: "let extra = 3", oldLineNumber: nil, newLineNumber: 2),
        ]
        let harness = makeHostHarness()
        let host = harness.host
        let opened = try activateReader(
            configuration: makeTimelineToolConfiguration(
                expandedContent: .diff(
                    lines: lines,
                    path: "/Users/chenda/workspace/oppi/clients/apple/scripts/sim-slim.sh"
                ),
                copyOutputText: DiffEngine.formatUnified(lines),
                toolNamePrefix: "edit",
                editAdded: 2,
                editRemoved: 1,
                isExpanded: true,
                isDone: true
            ),
            host: host,
            activate: { $0.performExpandedActivation() }
        )
        #expect(host.presentedViewController == nil)

        let presented = FullScreenCodeViewController(
            content: opened.payload.content,
            presentationMode: .embedded(onDismiss: {})
        )
        host.present(presented, animated: false)
        presented.loadViewIfNeeded()
        presented.view.frame = host.view.bounds
        presented.view.layoutIfNeeded()
        let body = try #require(presented.installedBodyViewForTesting as? NativeFullScreenDiffBody)
        let textView = try #require(timelineAllTextViews(in: body).first)

        let visible = await waitForMainActorCondition(timeout: .seconds(2)) {
            presented.view.layoutIfNeeded()
            body.layoutIfNeeded()
            textView.layoutIfNeeded()
            let rendered = timelineRenderedText(of: textView)
            let visibleFrame = textView.convert(textView.bounds, to: presented.view)
                .intersection(presented.view.bounds)
            return rendered.contains("let value = 2")
                && (rendered.contains("let value = 1") || rendered.contains("- let value = 1"))
                && textView.bounds.width > 100
                && textView.bounds.height > 40
                && visibleFrame.width > 100
                && visibleFrame.height > 40
        }
        #expect(visible)

        host.dismiss(animated: false)
        harness.window.isHidden = true
    }

    @Test("payload holder keeps a valid document after the store drops it")
    func payloadHolderKeepsValidDocumentAfterStoreDrop() {
        let store = ChatReaderPayloadStore()
        let holder = ChatReaderPayloadHolder()
        let target = store.store(Self.makeEditDiffReaderPayload())

        guard case .diff(let first) = holder.resolve(from: store, target: target)?.content else {
            Issue.record("Expected held diff payload")
            return
        }
        #expect(first.copyText.contains("let value = 2"))

        store.remove(target)
        #expect(store.payload(for: target.id) == nil)

        guard case .diff(let held) = holder.resolve(from: store, target: target)?.content else {
            Issue.record("Empty path after a valid payload store miss")
            return
        }
        #expect(held.copyText.contains("let value = 2"))
        #expect(held.lines.contains(where: { $0.text == "let extra = 3" }))
    }

    @Test("hosted destination shows a stored diff instead of empty chrome")
    func hostedDestinationShowsStoredDiffInsteadOfEmptyChrome() async throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }

        let payload = Self.makeEditDiffReaderPayload()
        let host = try makeHostedChatReader(payload: payload)
        defer { host.window.isHidden = true }

        let visible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
        }
        #expect(visible, "valid stored diff payload must render in the hosted destination")
        #expect(!chatReaderShowsUnavailableChrome(in: host.controller.view))
    }

    @Test("hosted destination keeps a valid diff after the store drops the payload")
    func hostedDestinationKeepsValidDiffAfterStoreDrop() async throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }

        let payload = Self.makeEditDiffReaderPayload()
        let host = try makeHostedChatReader(payload: payload)
        defer { host.window.isHidden = true }

        let visible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
        }
        #expect(visible, "valid stored diff payload must render before the store miss")

        host.store.remove(host.target)
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let stillVisible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
                && !chatReaderShowsUnavailableChrome(in: host.controller.view)
        }
        #expect(stillVisible, "empty chrome after a valid payload store miss is a bug")
    }

    @Test("hosted destination keeps a valid markdown document after the store drops the payload")
    func hostedDestinationKeepsValidMarkdownAfterStoreDrop() async throws {
        let markdown = """
        # Build 50 changelog

        Full-screen readers must keep their document body even if the
        navigation payload store is cleared after open.
        """
        let host = try makeHostedChatReader(
            payload: ChatReaderPayload(
                content: .markdown(
                    content: markdown,
                    filePath: ".internal/release-notes/testflight-build-50-changelog.md"
                )
            )
        )
        defer { host.window.isHidden = true }

        let visible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsMarkdownBody(in: host.controller.view, containing: "Build 50 changelog")
        }
        #expect(visible, "valid stored markdown payload must render before the store miss")

        host.store.remove(host.target)
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let stillVisible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsMarkdownBody(in: host.controller.view, containing: "Build 50 changelog")
                && !chatReaderShowsUnavailableChrome(in: host.controller.view)
        }
        #expect(stillVisible, "empty chrome after a valid document payload store miss is a bug")
    }

    @Test("production activate-to-navigation keeps the diff across a stacked store miss")
    func productionActivateToNavigationKeepsDiffAcrossStackedStoreMiss() async throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }

        // At 39db5c7b9 ChatReaderPageView re-queried store.payload(for:) on every
        // render, so a covering disappear that dropped the store entry left empty chrome.
        let host = try makeProductionChatReaderStack()
        defer { host.window.isHidden = true }

        let target = try activateProductionDiffReader(on: host)
        #expect(host.navigation.containsChatReader(target))
        #expect(host.store.payload(for: target.id) != nil)
        #expect(host.controller.presentedViewController == nil)

        let visible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
        }
        #expect(visible, "timeline activate must push a visible navigationDestination reader")

        host.store.remove(target)
        #expect(host.navigation.containsChatReader(target), "store-miss must not pop the stacked reader")
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let stillVisible = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
                && !chatReaderShowsUnavailableChrome(in: host.controller.view)
        }
        #expect(stillVisible, "covering store-miss while still stacked must not blank the on-screen reader")
    }

    @Test("true navigation pop releases the store and covering keeps a stacked payload")
    func trueNavigationPopReleasesStoreAndCoveringKeepsStackedPayload() async throws {
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff)
        defer { FullScreenReaderPreferencesStore.shared.resetPreferences(for: .diff) }

        let host = try makeProductionChatReaderStack()
        defer { host.window.isHidden = true }

        let first = try activateProductionDiffReader(on: host)
        let appeared = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return chatReaderShowsDiffBody(in: host.controller.view, containing: "let value = 2")
        }
        #expect(appeared)
        #expect(host.store.payload(for: first.id) != nil)

        let second = host.store.store(
            ChatReaderPayload(content: .plainText(content: "cover", filePath: "cover.txt")),
            retaining: host.navigation.containsChatReader
        )
        host.navigation.openChatReader(second)
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let coveringKept = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return host.store.payload(for: first.id) != nil
                && host.store.payload(for: second.id) != nil
                && host.navigation.containsChatReader(first)
                && host.navigation.containsChatReader(second)
        }
        #expect(coveringKept, "covering disappear must not release a still-stacked payload")

        host.navigation.workspacePath.removeLast()
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let secondReleased = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return host.store.payload(for: second.id) == nil
                && host.store.payload(for: first.id) != nil
                && !host.navigation.containsChatReader(second)
                && host.navigation.containsChatReader(first)
        }
        #expect(secondReleased, "true pop must release the popped payload and keep the stacked one")

        host.navigation.workspacePath.removeLast()
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()

        let firstReleased = await waitForMainActorCondition(timeout: .seconds(2)) {
            host.controller.view.layoutIfNeeded()
            return host.store.payload(for: first.id) == nil
                && !host.navigation.containsChatReader(first)
        }
        #expect(firstReleased, "true pop of the last reader must release its store entry")
    }

    @Test("ANSI text keeps display styling in full screen while copy stays plain")
    func ansiTextFullScreenPreservesDisplayPayload() throws {
        let formatted = "\u{001B}[1m$\u{001B}[0m oppi status\n\u{001B}[32mPaired\u{001B}[0m"
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .text(text: formatted, language: nil),
            copyOutputText: ANSIParser.strip(formatted),
            toolNamePrefix: "oppi",
            isExpanded: true
        )

        let terminalStream = TerminalTraceStream(
            output: ANSIParser.strip(formatted),
            command: nil,
            isDone: true
        )
        let fullScreenContent = ToolTimelineRowFullScreenSupport.staticFullScreenContent(
            configuration: configuration,
            outputCopyText: configuration.copyOutputText,
            terminalStream: terminalStream
        )

        guard let fullScreenContent else {
            Issue.record("Expected ANSI text full-screen content")
            return
        }
        guard case .terminal(let rendered, _, let stream) = fullScreenContent else {
            Issue.record("Expected terminal full-screen content")
            return
        }
        #expect(rendered == formatted)
        #expect(stream == nil)
        #expect(configuration.copyOutputText == ANSIParser.strip(formatted))
    }

    @Test("streaming ANSI text stays terminal-formatted with its display stream")
    func streamingANSITextPreservesTerminalDisplay() throws {
        let formatted = "\u{001B}[1m$\u{001B}[0m oppi status\n\u{001B}[32mPaired\u{001B}[0m"
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .text(text: formatted, language: nil),
            copyOutputText: ANSIParser.strip(formatted),
            toolNamePrefix: "oppi",
            isExpanded: true,
            isDone: false
        )
        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .text(text: formatted, language: nil),
            isDone: false
        )
        let terminalStream = TerminalTraceStream(
            output: formatted,
            command: nil,
            isDone: false
        )

        let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: configuration,
            outputCopyText: configuration.copyOutputText,
            interactionPolicy: interactionPolicy,
            terminalStream: terminalStream,
            sourceStream: nil
        )

        guard case .terminal(let rendered, _, let stream) = fullScreenContent else {
            Issue.record("Expected streaming ANSI text to use terminal full-screen content")
            return
        }
        #expect(rendered == formatted)
        #expect(stream?.snapshot.output == formatted)
    }

    @Test("streaming file-like tools use live source full screen content")
    func streamingFileLikeToolsUseLiveSourceFullScreenContent() throws {
        let configuration = makeTimelineToolConfiguration(
            expandedContent: .code(
                text: "let draft = 1",
                language: .swift,
                startLine: 1,
                filePath: "Draft.swift"
            ),
            copyOutputText: "let draft = 1",
            toolNamePrefix: "write",
            isExpanded: true,
            isDone: false
        )
        let interactionPolicy = ToolTimelineRowInteractionPolicy.forExpandedContent(
            .code(text: "let draft = 1", language: .swift, startLine: 1, filePath: "Draft.swift"), isDone: false
        )
        let sourceStream = SourceTraceStream(
            text: "let draft = 1",
            filePath: "Draft.swift",
            isDone: false,
            finalContent: nil
        )

        let fullScreenContent = ToolTimelineRowFullScreenSupport.fullScreenContent(
            configuration: configuration,
            outputCopyText: configuration.copyOutputText,
            interactionPolicy: interactionPolicy,
            terminalStream: nil,
            sourceStream: sourceStream
        )

        guard case .liveSource(let snapshot, _) = fullScreenContent else {
            Issue.record("Expected .liveSource for streaming file-like content")
            return
        }
        #expect(snapshot.text == "let draft = 1")
        #expect(snapshot.filePath == "Draft.swift")
        #expect(!snapshot.isDone)
    }

    private static func makeTestPNG() -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    private func makeHostHarness() -> HostHarness {
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            fatalError("Missing UIWindowScene for ToolTimelineRowFullScreenActivationTests")
        }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        return HostHarness(window: window, host: host)
    }

    private struct HostedChatReader {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        let store: ChatReaderPayloadStore
        let target: ChatReaderNavTarget
    }

    private struct ProductionChatReaderHost {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        let store: ChatReaderPayloadStore
        let navigation: AppNavigation
    }

    private struct ProductionChatReaderStack: View {
        var navigation: AppNavigation
        let store: ChatReaderPayloadStore

        var body: some View {
            NavigationStack(path: Binding(
                get: { navigation.workspacePath },
                set: { navigation.workspacePath = $0 }
            )) {
                Text("Inbox")
                    .navigationDestination(for: WorkspaceSessionNavTarget.self) { _ in
                        Text("Chat")
                    }
                    .navigationDestination(for: ChatReaderNavTarget.self) { target in
                        ChatReaderDestinationView(target: target, store: store)
                    }
            }
            .environment(navigation)
            .environment(\.chatReaderPayloadStore, store)
        }
    }

    private static func makeEditDiffReaderPayload() -> ChatReaderPayload {
        let lines = [
            DiffLine(kind: .removed, text: "let value = 1", oldLineNumber: 1, newLineNumber: nil),
            DiffLine(kind: .added, text: "let value = 2", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(kind: .added, text: "let extra = 3", oldLineNumber: nil, newLineNumber: 2),
        ]
        return ChatReaderPayload(
            content: .diff(
                ToolDiffDocument(
                    lines: lines,
                    filePath: "App.swift",
                    copyText: DiffEngine.formatUnified(lines)
                )
            )
        )
    }

    private func makeHostedChatReader(payload: ChatReaderPayload) throws -> HostedChatReader {
        let store = ChatReaderPayloadStore()
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )
        let target = store.store(payload)
        navigation.openChatReader(target)

        let controller = UIHostingController(
            rootView: AnyView(
                ChatReaderDestinationView(target: target, store: store)
                    .environment(navigation)
            )
        )
        let harness = makeHostHarness()
        harness.window.rootViewController = controller
        controller.view.frame = harness.window.bounds
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        return HostedChatReader(
            window: harness.window,
            controller: controller,
            store: store,
            target: target
        )
    }

    private func makeProductionChatReaderStack() throws -> ProductionChatReaderHost {
        let store = ChatReaderPayloadStore()
        let navigation = AppNavigation()
        navigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: "server-1", sessionId: "session-1")
        )
        let controller = UIHostingController(
            rootView: AnyView(
                ProductionChatReaderStack(navigation: navigation, store: store)
            )
        )
        let harness = makeHostHarness()
        harness.window.rootViewController = controller
        controller.view.frame = harness.window.bounds
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
        return ProductionChatReaderHost(
            window: harness.window,
            controller: controller,
            store: store,
            navigation: navigation
        )
    }

    private func activateProductionDiffReader(
        on host: ProductionChatReaderHost
    ) throws -> ChatReaderNavTarget {
        let payload = Self.makeEditDiffReaderPayload()
        let document = try #require({
            if case .diff(let document) = payload.content { return document }
            return nil
        }())
        var openedTarget: ChatReaderNavTarget?
        var configuration = makeTimelineToolConfiguration(
            expandedContent: .diff(lines: document.lines, path: document.filePath),
            copyOutputText: document.copyText,
            toolNamePrefix: "edit",
            editAdded: 2,
            editRemoved: 1,
            isExpanded: true,
            isDone: true
        )
        configuration.openFullScreen = { payload in
            let target = host.store.store(payload, retaining: host.navigation.containsChatReader)
            openedTarget = target
            host.navigation.openChatReader(target)
        }
        let view = ToolTimelineRowContentView(configuration: configuration)
        host.controller.view.addSubview(view)
        view.frame = CGRect(x: 0, y: 2000, width: 390, height: 200)
        host.controller.view.layoutIfNeeded()
        view.performExpandedActivation()
        view.removeFromSuperview()
        host.controller.view.setNeedsLayout()
        host.controller.view.layoutIfNeeded()
        return try #require(openedTarget)
    }

    private func chatReaderShowsUnavailableChrome(in root: UIView) -> Bool {
        let needles = ["Unable to Open", "This reader is no longer available."]
        return timelineAllLabels(in: root).contains { label in
            let text = timelineRenderedText(of: label)
            return needles.contains { text.contains($0) }
        }
    }

    private func chatReaderShowsDiffBody(in root: UIView, containing needle: String) -> Bool {
        guard let body = timelineFirstView(ofType: NativeFullScreenDiffBody.self, in: root) else {
            return false
        }
        return timelineAllTextViews(in: body).contains {
            timelineRenderedText(of: $0).contains(needle)
        }
    }

    private func chatReaderShowsMarkdownBody(in root: UIView, containing needle: String) -> Bool {
        let markdownBody = timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: root)
        let searchRoot = markdownBody ?? root
        let hasNeedle = timelineAllViews(in: searchRoot).contains { view in
            timelineRenderedText(of: view).contains(needle)
        }
        return markdownBody != nil && hasNeedle
    }

    @Test("lookup from presenter finds install on a descendant collection view")
    func lookupFromPresenterFindsDescendantInstall() {
        let harness = makeHostHarness()
        var opened: ChatReaderPayload?
        let collection = UICollectionView(
            frame: harness.host.view.bounds,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        harness.host.view.addSubview(collection)
        ChatReaderOpenLookup.install({ opened = $0 }, on: collection)

        let didOpen = ChatReaderOpenLookup.open(
            ChatReaderPayload(content: .plainText(content: "note", filePath: "note.txt")),
            from: harness.host
        )

        #expect(didOpen)
        #expect(opened != nil)
        #expect(harness.host.presentedViewController == nil)
        harness.window.isHidden = true
    }

    @Test("payload store evicts removed and cleared targets")
    func payloadStoreEvictsRemovedTargets() {
        let store = ChatReaderPayloadStore()
        let first = store.store(ChatReaderPayload(content: .plainText(content: "a", filePath: "a.txt")))
        let second = store.store(ChatReaderPayload(content: .plainText(content: "b", filePath: "b.txt")))
        #expect(store.payload(for: first.id) != nil)
        #expect(store.payload(for: second.id) != nil)

        store.remove(first)
        #expect(store.payload(for: first.id) == nil)
        #expect(store.payload(for: second.id) != nil)

        store.removeAll()
        #expect(store.payload(for: second.id) == nil)
    }

    @Test("lookup from a presented controller does not steal a chat descendant install")
    func lookupFromPresentedControllerDoesNotStealChatInstall() {
        let harness = makeHostHarness()
        var opened: ChatReaderPayload?
        let collection = UICollectionView(
            frame: harness.host.view.bounds,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        harness.host.view.addSubview(collection)
        ChatReaderOpenLookup.install({ opened = $0 }, on: collection)

        let presented = UIViewController()
        harness.host.present(presented, animated: false)
        let didOpen = ChatReaderOpenLookup.open(
            ChatReaderPayload(content: .plainText(content: "note", filePath: "note.txt")),
            from: presented
        )

        #expect(!didOpen)
        #expect(opened == nil)
        harness.host.dismiss(animated: false)
        harness.window.isHidden = true
    }

    private struct ActivatedReader {
        let view: ToolTimelineRowContentView
        let payload: ChatReaderPayload
    }

    private func activateReader(
        configuration: ToolTimelineRowConfiguration,
        host: UIViewController,
        activate: (ToolTimelineRowContentView) -> Void
    ) throws -> ActivatedReader {
        var opened: ChatReaderPayload?
        var configuration = configuration
        configuration.openFullScreen = { opened = $0 }
        let view = ToolTimelineRowContentView(configuration: configuration)
        host.view.addSubview(view)
        view.frame = host.view.bounds
        host.view.layoutIfNeeded()
        activate(view)
        let payload = try #require(opened)
        return ActivatedReader(view: view, payload: payload)
    }
}
