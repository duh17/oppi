import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Oppi

@MainActor
final class MacComposerVisualGateTests: XCTestCase {
    func testEditorRequestDoesNotClaimComposerCommandReturn() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)
        store.applyLiveRuntimeMessage(.extensionUIRequest(ExtensionUIRequest(
            id: "blocking-editor", sessionId: target.sessionId, method: "editor", title: "Review response"
        )), sessionId: target.sessionId)
        let host = NSHostingView(rootView: MacComposerSnapshotHost(store: store, initialDraft: "Do not send this")
            .frame(width: 680).padding(20).environment(\.theme, AppTheme.dark))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        await flushExtensionHost(host)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let claimed = window.performKeyEquivalent(with: key)
        // Revoke the target synchronously, before any accidentally scheduled
        // send Task can read local configuration. The red run is side-effect free.
        store.clearSelection()
        XCTAssertFalse(claimed, "An unanswered editor must disable the ordinary composer shortcut")
    }

    func testExtensionEditorMountedOpenTypeSubmitAndRemoteSettlement() async throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)
        let request = ExtensionUIRequest(id: "mounted-editor", sessionId: target.sessionId,
                                         method: "editor", title: "Review response", prefill: "Original")
        store.applyLiveRuntimeMessage(.extensionUIRequest(request), sessionId: target.sessionId)
        var responses: [ClientMessage] = []
        store._sendLiveMessageForTesting = { responses.append($0); return true }
        let host = NSHostingView(rootView: MacComposerSnapshotHost(store: store, initialDraft: "Untouched draft")
            .frame(width: 680).padding(20)
            .environment(\.theme, AppTheme.dark).environment(\.themeID, ThemeID.dark))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        defer {
            for sheet in window.sheets { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        await flushExtensionHost(host)
        let before = XCTAttachment(image: try extensionHostImage(host))
        before.name = "extension-editor-mounted-entry"
        before.lifetime = .keepAlways
        add(before)
        // Offscreen SwiftUI AX children are absent on the current macOS host.
        // Dispatch local window events at the fixed fixture's visible button;
        // this still exercises production hit testing and Button actions.
        try clickExtensionHost(host, at: NSPoint(x: 90, y: host.isFlipped ? 66 : host.bounds.height - 66))
        await flushExtensionHost(host)
        var sheet = try XCTUnwrap(window.sheets.first, "The production composer entry point must mount an editor sheet")
        var content = try XCTUnwrap(sheet.contentView)
        XCTAssertGreaterThanOrEqual(content.bounds.height, 360,
            "The editor sheet must fit its header, input, and response controls instead of clipping to 240 pt")
        let editor = try XCTUnwrap(visualDescendants(of: content, type: NSTextView.self).first)
        XCTAssertEqual(editor.string, "Original")
        editor.insertText("Edited on Mac", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await flushExtensionHost(content)
        XCTAssertEqual(store.extensionEditorText(for: request), "Edited on Mac")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(sheet.performKeyEquivalent(with: escape))
        await flushExtensionHost(host)
        XCTAssertTrue(responses.isEmpty, "Escape closes without cancelling the server request")
        XCTAssertEqual(store.extensionEditorText(for: request), "Edited on Mac")
        XCTAssertNotNil(store.currentExtensionDialog)
        XCTAssertTrue(window.sheets.isEmpty)
        try clickExtensionHost(host, at: NSPoint(x: 90, y: host.isFlipped ? 66 : host.bounds.height - 66))
        await flushExtensionHost(host)
        sheet = try XCTUnwrap(window.sheets.first)
        content = try XCTUnwrap(sheet.contentView)
        let reopenedEditor = try XCTUnwrap(visualDescendants(of: content, type: NSTextView.self).first)
        XCTAssertEqual(reopenedEditor.string, "Edited on Mac")
        var replacement = request
        replacement.title = "Review updated response"
        store.applyLiveRuntimeMessage(.extensionUIRequest(replacement), sessionId: target.sessionId)
        await flushExtensionHost(content)
        XCTAssertEqual(store.currentExtensionDialog, replacement)
        let ready = XCTAttachment(image: try extensionHostImage(content))
        ready.name = "extension-editor-mounted-ready-to-submit"
        ready.lifetime = .keepAlways
        add(ready)
        let submitKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(sheet.performKeyEquivalent(with: submitKey), "Cmd-Return must reach the production Submit action")
        await flushExtensionHost(content)
        XCTAssertEqual(responses.count, 1)
        guard case .extensionUIResponse(let id, let text, _, _, _) = responses.first else {
            XCTFail("Expected extension response from mounted Submit"); return
        }
        XCTAssertEqual(id, request.id)
        XCTAssertEqual(text, "Edited on Mac")
        XCTAssertNotNil(store.currentExtensionDialog, "Transport write is not server settlement")
        let image = try extensionHostImage(content)
        let attachment = XCTAttachment(image: image)
        attachment.name = "extension-editor-mounted-after-submit"
        attachment.lifetime = .keepAlways
        add(attachment)
        store.applyLiveRuntimeMessage(.extensionUISettled(id: request.id, sessionId: target.sessionId), sessionId: target.sessionId)
        await flushExtensionHost(host)
        XCTAssertNil(store.currentExtensionDialog)
        XCTAssertTrue(window.sheets.isEmpty, "Remote settlement must dismiss the mounted sheet")

        let pointerRequest = ExtensionUIRequest(id: "mounted-editor-pointer", sessionId: target.sessionId,
                                                method: "editor", title: "Review pointer response", prefill: "Original")
        store.applyLiveRuntimeMessage(.extensionUIRequest(pointerRequest), sessionId: target.sessionId)
        await flushExtensionHost(host)
        try clickExtensionHost(host, at: NSPoint(x: 90, y: host.isFlipped ? 66 : host.bounds.height - 66))
        await flushExtensionHost(host)
        sheet = try XCTUnwrap(window.sheets.first, "Pointer cycle must mount an editor sheet")
        content = try XCTUnwrap(sheet.contentView)
        let pointerEditor = try XCTUnwrap(visualDescendants(of: content, type: NSTextView.self).first)
        XCTAssertEqual(pointerEditor.string, "Original")
        pointerEditor.insertText("Pointer edited", replacementRange: NSRange(location: 0, length: pointerEditor.string.utf16.count))
        await flushExtensionHost(content)
        let pointerEscape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(sheet.performKeyEquivalent(with: pointerEscape))
        await flushExtensionHost(host)
        XCTAssertEqual(responses.count, 1, "Pointer-cycle Escape must not send")
        XCTAssertEqual(store.extensionEditorText(for: pointerRequest), "Pointer edited")
        XCTAssertTrue(window.sheets.isEmpty)
        try clickExtensionHost(host, at: NSPoint(x: 90, y: host.isFlipped ? 66 : host.bounds.height - 66))
        await flushExtensionHost(host)
        sheet = try XCTUnwrap(window.sheets.first)
        content = try XCTUnwrap(sheet.contentView)
        XCTAssertEqual(visualDescendants(of: content, type: NSTextView.self).first?.string, "Pointer edited")
        var pointerReplacement = pointerRequest
        pointerReplacement.title = "Review updated pointer response"
        store.applyLiveRuntimeMessage(.extensionUIRequest(pointerReplacement), sessionId: target.sessionId)
        await flushExtensionHost(content)
        XCTAssertEqual(store.currentExtensionDialog, pointerReplacement)
        sheet.makeKeyAndOrderFront(nil)
        try clickExtensionHost(content, at: visibleSubmitHit(in: content).point)
        await flushExtensionHost(content)
        XCTAssertEqual(responses.count, 2)
        guard case .extensionUIResponse(let pointerId, let pointerText, _, _, _) = responses.last else {
            XCTFail("Expected extension response from mounted pointer Submit"); return
        }
        XCTAssertEqual(pointerId, pointerRequest.id)
        XCTAssertEqual(pointerText, "Pointer edited")
        store.applyLiveRuntimeMessage(.extensionUISettled(id: pointerRequest.id, sessionId: target.sessionId), sessionId: target.sessionId)
        await flushExtensionHost(host)
        XCTAssertNil(store.currentExtensionDialog)
        XCTAssertTrue(window.sheets.isEmpty, "Remote settlement must dismiss the pointer sheet")
    }

    func testExtensionWorkingThinkingAndToolDisplayMountedPaint() throws {
        let store = MacSessionTraceStore()
        let target = makeTarget(status: .busy)
        store.select(target)
        let rows: [ChatItem] = [
            .thinking(id: "hidden-thinking", preview: "", hasMore: false, isDone: true),
            .toolCall(id: "generic-row", tool: "fixture_operation", argsSummary: "Inspect result",
                      outputPreview: "Detailed extension output\nSecond line", outputByteCount: 42, isError: false, isDone: true),
        ]
        func notification(_ method: String, message: String? = nil, visible: Bool? = nil,
                          frames: [String]? = nil, hidden: String? = nil, expanded: Bool? = nil) {
            store.applyLiveRuntimeMessage(.extensionUINotification(ExtensionUINotification(
                method: method, message: message, notifyType: nil, statusKey: nil, statusText: nil,
                title: nil, text: nil, widgetKey: nil, widgetLines: nil, widgetPlacement: nil,
                workingIndicator: frames.map { .init(frames: $0, intervalMs: 120) },
                workingVisible: visible, hiddenThinkingLabel: hidden, toolsExpanded: expanded
            )), sessionId: target.sessionId)
        }
        func capture(_ name: String) throws -> NSImage {
            let image = try hostedSnapshot(of: MacTimelineSnapshotHost(store: store, isLoading: false,
                lastError: nil, isBusy: true, items: rows)
                .frame(width: 640, height: 420)
                .environment(\.theme, AppTheme.dark).environment(\.themeID, ThemeID.dark))
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            return image
        }
        notification("setWorkingMessage", message: "Checking files")
        notification("setWorkingIndicator", frames: ["●"])
        notification("setHiddenThinkingLabel", hidden: "Reasoning is private")
        let collapsed = try capture("extension-display-collapsed")
        notification("setToolsExpanded", expanded: true)
        let expanded = try capture("extension-display-expanded")
        XCTAssertNotEqual(collapsed.tiffRepresentation, expanded.tiffRepresentation,
                          "The actual Mac tool painter must change when expansion arrives")
        notification("setWorkingVisible", visible: false)
        let hidden = try capture("extension-display-working-hidden")
        XCTAssertNotEqual(expanded.tiffRepresentation, hidden.tiffRepresentation,
                          "The actual Mac timeline must remove its working row")
    }

    private func flushExtensionHost(_ view: NSView) async {
        for _ in 0..<12 {
            await Task.yield()
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        CATransaction.flush()
    }

    private func clickExtensionHost(_ view: NSView, at point: NSPoint) throws {
        let window = try XCTUnwrap(view.window)
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseUp, .leftMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            if type == .leftMouseUp {
                NSApp.postEvent(event, atStart: true)
            } else {
                window.sendEvent(event)
            }
        }
    }

    private func visibleSubmitHit(in content: NSView) -> (point: NSPoint, hit: String) {
        let x = content.bounds.maxX - 50
        let offsets: [CGFloat] = Array(stride(from: 8, through: 48, by: 4)).map(CGFloat.init)
        for offset in offsets {
            let y = content.isFlipped ? content.bounds.maxY - offset : content.bounds.minY + offset
            let local = NSPoint(x: x, y: y)
            let windowPoint = content.convert(local, to: nil)
            let hit = content.window?.contentView?.hitTest(windowPoint)
            if let hit, !(hit is NSTextView), hit !== content {
                return (local, String(describing: type(of: hit)))
            }
        }
        let fallback = NSPoint(
            x: x,
            y: content.isFlipped ? content.bounds.maxY - 32 : content.bounds.minY + 32
        )
        let windowPoint = content.convert(fallback, to: nil)
        let hit = content.window?.contentView?.hitTest(windowPoint)
        return (fallback, hit.map { String(describing: type(of: $0)) } ?? "nil")
    }

    private func extensionHostImage(_ view: NSView) throws -> NSImage {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    func testPrimaryComposerStates() throws {
        for status in [SessionStatus.ready, .busy, .stopping, .stopped] {
            let store = MacSessionTraceStore()
            store.select(makeTarget(status: status))
            let composerWidth: CGFloat = 760
            let image = try hostedSnapshot(of:
                MacComposerSnapshotHost(store: store)
                    .frame(width: composerWidth)
                    .padding(24)
                    .background(AppTheme.dark.bg.primary)
                    .environment(\.theme, AppTheme.dark)
                    .environment(\.themeID, ThemeID.dark)
                    .tint(.themeBlue)
                    .preferredColorScheme(.dark)
            )
            assertComposerGeometry(
                image,
                composerWidth: composerWidth,
                context: "primary \(status.rawValue)"
            )
            let attachment = XCTAttachment(image: image)
            attachment.name = "composer-\(status.rawValue)-structural"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testNarrowReadyAndBusyComposerMatrix() throws {
        let widths: [CGFloat] = [320, 360, 420, 440]
        let statuses: [SessionStatus] = [.ready, .busy]

        for status in statuses {
            for composerWidth in widths {
                let store = MacSessionTraceStore()
                store.select(makeTarget(status: status))
                let image = try hostedSnapshot(of:
                    MacComposerSnapshotHost(store: store)
                        .frame(width: composerWidth)
                        .padding(24)
                        .background(AppTheme.dark.bg.primary)
                        .environment(\.theme, AppTheme.dark)
                        .environment(\.themeID, ThemeID.dark)
                        .tint(.themeBlue)
                        .preferredColorScheme(.dark)
                )
                assertComposerGeometry(
                    image,
                    composerWidth: composerWidth,
                    context: "narrow \(status.rawValue) at \(Int(composerWidth)) pt"
                )

                let attachment = XCTAttachment(image: image)
                attachment.name = "composer-narrow-\(status.rawValue)-\(Int(composerWidth))pt-structural"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testNarrowTerminalComposerStates() throws {
        let composerWidth: CGFloat = 320
        for status in [SessionStatus.stopping, .stopped] {
            let store = MacSessionTraceStore()
            store.select(makeTarget(status: status))
            let image = try hostedSnapshot(of:
                MacComposerSnapshotHost(store: store)
                    .frame(width: composerWidth)
                    .padding(24)
                    .background(AppTheme.dark.bg.primary)
                    .environment(\.theme, AppTheme.dark)
                    .environment(\.themeID, ThemeID.dark)
                    .tint(.themeBlue)
                    .preferredColorScheme(.dark)
            )
            assertComposerGeometry(
                image,
                composerWidth: composerWidth,
                context: "narrow terminal \(status.rawValue)"
            )

            let attachment = XCTAttachment(image: image)
            attachment.name = "composer-narrow-\(status.rawValue)-320pt-structural"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEmptyTimelineStateMatrix() throws {
        let fixtures: [(name: String, status: SessionStatus, isLoading: Bool, error: String?, isBusy: Bool)] = [
            ("loading", .starting, true, nil, false),
            ("error", .error, false, "The session stream closed before history loaded.", false),
            ("error-without-detail", .error, false, nil, false),
            ("empty", .ready, false, nil, false),
            ("busy", .busy, false, nil, true),
        ]
        let timelineWidth: CGFloat = 420
        let timelineHeight: CGFloat = 300

        for fixture in fixtures {
            let store = MacSessionTraceStore()
            store.select(makeTarget(status: fixture.status))
            let image = try hostedSnapshot(of:
                MacTimelineSnapshotHost(
                    store: store,
                    isLoading: fixture.isLoading,
                    lastError: fixture.error,
                    isBusy: fixture.isBusy
                )
                .frame(width: timelineWidth, height: timelineHeight)
                .padding(24)
                .background(AppTheme.dark.bg.primary)
                .environment(\.theme, AppTheme.dark)
                .environment(\.themeID, ThemeID.dark)
                .tint(.themeBlue)
                .preferredColorScheme(.dark)
            )

            XCTAssertEqual(image.size.width, timelineWidth + 48, accuracy: 1)
            XCTAssertEqual(image.size.height, timelineHeight + 48, accuracy: 1)
            let attachment = XCTAttachment(image: image)
            attachment.name = "timeline-empty-\(fixture.name)-420pt-structural"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testInboxReasonRowMatrix() throws {
        let readySession = makeTarget(status: .ready).summary.session
        let busySession = makeTarget(status: .busy).summary.session
        let fixtures: [(name: String, presentation: SessionRowPresentation)] = [
            (
                "search-match",
                SessionRowPresentationBuilder.make(
                    session: readySession,
                    workspaceContext: "Oppi",
                    searchSnippet: SessionSearchStore.parseSnippet(
                        "Fixed <b>launch</b> flash while reconnecting to the live session"
                    )
                )
            ),
            (
                "lineage",
                SessionRowPresentationBuilder.make(
                    session: busySession,
                    lineageHint: "Child of the live UI review session",
                    workspaceContext: "Oppi"
                )
            ),
        ]
        let rowWidth: CGFloat = 280

        for fixture in fixtures {
            let image = try hostedSnapshot(of:
                WorkspaceSessionSummaryRow(presentation: fixture.presentation)
                    .frame(width: rowWidth)
                    .padding(24)
                    .background(AppTheme.dark.bg.primary)
                    .environment(\.theme, AppTheme.dark)
                    .environment(\.themeID, ThemeID.dark)
                    .tint(.themeBlue)
                    .preferredColorScheme(.dark)
            )

            XCTAssertEqual(image.size.width, rowWidth + 48, accuracy: 1)
            XCTAssertLessThanOrEqual(
                image.size.height,
                58 + 48,
                "The \(fixture.name) row should remain a compact two-band scan target"
            )
            let attachment = XCTAttachment(image: image)
            attachment.name = "inbox-row-\(fixture.name)-280pt-structural"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testReadyComposerWithDenseDraftAndDocumentAttachment() throws {
        let store = MacSessionTraceStore()
        store.select(makeTarget(status: .ready))
        let composerWidth: CGFloat = 560
        let attachment = try MacPendingAttachment(
            id: "visual:architecture-notes",
            url: URL(fileURLWithPath: "/tmp/oppi-visual-fixtures/architecture-notes.md"),
            displayName: "architecture-notes.md",
            mimeType: "text/markdown",
            sizeBytes: 18_432
        )
        let draft = """
        Please tighten the live-session layout at narrow window widths.

        Check the composer controls, attachment affordance, queue status, and focus order.
        Keep every action discoverable without letting labels collide or clip.
        """
        let image = try hostedSnapshot(of:
            MacComposerSnapshotHost(
                store: store,
                initialDraft: draft,
                initialAttachments: [attachment]
            )
            .frame(width: composerWidth)
            .padding(24)
            .background(AppTheme.dark.bg.primary)
            .environment(\.theme, AppTheme.dark)
            .environment(\.themeID, ThemeID.dark)
            .tint(.themeBlue)
            .preferredColorScheme(.dark)
        )
        assertComposerGeometry(
            image,
            composerWidth: composerWidth,
            context: "ready dense draft with document attachment",
            maximumHeight: 480
        )
        XCTAssertGreaterThan(
            image.size.height,
            120,
            "The dense draft and attachment fixture should visibly expand the composer"
        )

        let snapshot = XCTAttachment(image: image)
        snapshot.name = "composer-ready-dense-draft-document-attachment-560pt-structural"
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }

    func testNightThemeRepaintsComposerWithNonDefaultPalette() throws {
        let composerWidth: CGFloat = 560
        let darkStore = MacSessionTraceStore()
        darkStore.select(makeTarget(status: .ready))
        let nightStore = MacSessionTraceStore()
        nightStore.select(makeTarget(status: .ready))

        let darkImage = try hostedSnapshot(of:
            MacComposerSnapshotHost(store: darkStore)
                .frame(width: composerWidth)
                .padding(24)
                .background(AppTheme.dark.bg.primary)
                .environment(\.theme, AppTheme.dark)
                .environment(\.themeID, ThemeID.dark)
                .tint(.themeBlue)
                .preferredColorScheme(.dark)
        )
        let nightImage = try hostedSnapshot(of:
            MacComposerSnapshotHost(store: nightStore)
                .frame(width: composerWidth)
                .padding(24)
                .background(AppTheme.night.bg.primary)
                .environment(\.theme, AppTheme.night)
                .environment(\.themeID, ThemeID.night)
                .tint(.themeBlue)
                .preferredColorScheme(.dark)
        )

        XCTAssertEqual(nightImage.size, darkImage.size)
        XCTAssertNotEqual(
            nightImage.tiffRepresentation,
            darkImage.tiffRepresentation,
            "A mounted composer must repaint when its semantic palette changes"
        )

        let attachment = XCTAttachment(image: nightImage)
        attachment.name = "composer-ready-night-theme-560pt-structural"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCollapsedMessageQueueHugsContentInsideATallOverlay() throws {
        let overlayHeight: CGFloat = 640
        let composerWidth: CGFloat = 560
        let baselineStore = MacSessionTraceStore()
        let baselineTarget = makeTarget(status: .busy)
        baselineStore.select(baselineTarget)

        let queuedStore = MacSessionTraceStore()
        let queuedTarget = makeTarget(status: .busy)
        queuedStore.select(queuedTarget)
        applyQueueState(
            MessageQueueState(
                version: 1,
                steering: [
                    MessageQueueItem(
                        id: "steer-1",
                        message: "Tighten the live session layout",
                        createdAt: 1_800_000_000_000
                    ),
                ],
                followUp: []
            ),
            to: queuedStore,
            target: queuedTarget
        )

        let baseline = try measureComposerHeightInOverlay(
            store: baselineStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-tall-overlay-baseline"
        )
        let queued = try measureComposerHeightInOverlay(
            store: queuedStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-collapsed-queue-tall-overlay"
        )

        let auxiliaryBand = queued.height - baseline.height
        XCTAssertGreaterThan(
            auxiliaryBand,
            24,
            "Collapsed Message Queue chip should paint above the composer"
        )
        XCTAssertLessThan(
            auxiliaryBand,
            100,
            "Collapsed Message Queue must hug the chip instead of reserving the \(Int(MacSessionWindowChrome.composerAuxiliaryTotalMaximumHeight))pt auxiliary cap"
        )
        XCTAssertLessThan(
            queued.height,
            baseline.height + MacSessionWindowChrome.composerAuxiliaryTotalMaximumHeight,
            "Composer height must stay near chip+composer, well below the 220pt cap"
        )
    }

    func testShortExtensionSurfaceHugsContentInsideATallOverlay() throws {
        let overlayHeight: CGFloat = 640
        let composerWidth: CGFloat = 560
        let baselineStore = MacSessionTraceStore()
        let baselineTarget = makeTarget(status: .busy)
        baselineStore.select(baselineTarget)

        let extensionStore = MacSessionTraceStore()
        let extensionTarget = makeTarget(status: .busy)
        extensionStore.select(extensionTarget)
        applyWidgetLines(["Agents active"], to: extensionStore, target: extensionTarget)

        let baseline = try measureComposerHeightInOverlay(
            store: baselineStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-tall-overlay-extension-baseline"
        )
        let shortSurface = try measureComposerHeightInOverlay(
            store: extensionStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-short-extension-tall-overlay"
        )

        let auxiliaryBand = shortSurface.height - baseline.height
        XCTAssertGreaterThan(
            auxiliaryBand,
            24,
            "Short above-composer extension chrome should paint above the composer"
        )
        XCTAssertLessThan(
            auxiliaryBand,
            140,
            "Short extension chrome must hug its card instead of filling the expanded 260pt scroller"
        )
        XCTAssertLessThan(
            shortSurface.height,
            baseline.height + MacSessionWindowChrome.composerAuxiliaryTotalMaximumHeight,
            "Short extension chrome must not reserve the 220pt auxiliary band"
        )
    }

    func testAuxiliaryContentCompressesInsideAShortOverlay() throws {
        let overlayHeight: CGFloat = 320
        let composerWidth: CGFloat = 560
        let manyLines = (1...40).map { "Queued job \($0)" }
        let moreLines = (1...80).map { "Queued job \($0)" }

        let manyStore = MacSessionTraceStore()
        let manyTarget = makeTarget(status: .busy)
        manyStore.select(manyTarget)
        applyWidgetLines(manyLines, to: manyStore, target: manyTarget)

        let moreStore = MacSessionTraceStore()
        let moreTarget = makeTarget(status: .busy)
        moreStore.select(moreTarget)
        applyWidgetLines(moreLines, to: moreStore, target: moreTarget)

        let many = try measureComposerHeightInOverlay(
            store: manyStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-extension-40-lines-short-overlay"
        )
        let more = try measureComposerHeightInOverlay(
            store: moreStore,
            width: composerWidth,
            overlayHeight: overlayHeight,
            attachmentName: "composer-busy-extension-80-lines-short-overlay"
        )

        XCTAssertEqual(
            many.height,
            more.height,
            accuracy: 12,
            "Overflowing auxiliary chrome should cap and scroll instead of growing with extra lines"
        )
        XCTAssertLessThanOrEqual(
            many.height,
            MacSessionWindowChrome.composerAuxiliaryTotalMaximumHeight + 180,
            "A short overlay must keep overflowing auxiliary content inside the shared 220pt cap"
        )
        XCTAssertGreaterThan(
            many.height,
            160,
            "Capped auxiliary chrome should still occupy the bounded pane"
        )
    }

    func testHuggingCappedRegionKeepsAStableScrollViewIdentity() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("struct MacComposerHuggingCappedRegion"),
            "Composer auxiliary chrome must keep a dedicated hugging region"
        )
        XCTAssertTrue(
            source.contains("ScrollView(.vertical)"),
            "The hugging region must always wrap in a vertical ScrollView"
        )
        XCTAssertTrue(
            source.contains(".scrollBounceBehavior(.basedOnSize)"),
            "Short content must not rubber-band; bounce basedOnSize replaces scrollDisabled"
        )
        XCTAssertFalse(
            source.contains(".scrollDisabled"),
            "Parent vertical ScrollView.scrollDisabled also disables descendant horizontal widget/terminal line scrollers"
        )
        XCTAssertTrue(
            source.contains("contentHeight > 0 ? min(contentHeight, maxHeight) : nil"),
            "Unmeasured content must hug instead of filling maxHeight"
        )
        XCTAssertFalse(
            source.contains("if overflows"),
            "Do not recreate auxiliary content by branching Group vs ScrollView at the cap"
        )
    }

    func testZeroPaneQuickSessionIsCenteredBoundedAndResponsive() throws {
        let fixtures: [(name: String, width: CGFloat)] = [
            ("wide", 1_000),
            ("minimum", MacSessionShellLayoutPolicy.timelineMinimumWidth),
        ]

        for fixture in fixtures {
            let capture = try hostedZeroPaneQuickSession(
                width: fixture.width,
                height: 620
            )
            XCTAssertEqual(capture.image.size.width, fixture.width, accuracy: 1)
            XCTAssertEqual(capture.image.size.height, 620, accuracy: 1)
            XCTAssertEqual(capture.inputCount, 1, "Zero-pane startup must expose one Quick Session input")
            XCTAssertGreaterThan(capture.inputFrame.width, 180, "The Quick Session input must remain usable")
            XCTAssertGreaterThan(capture.inputFrame.minY, 180, "The start surface must not hug the bottom edge")
            XCTAssertLessThan(capture.inputFrame.maxY, 440, "The start surface must remain vertically centered")

            if fixture.width > MacQuickSessionPaneLayoutPolicy.maximumSurfaceWidth {
                let boundedInset = (fixture.width - MacQuickSessionPaneLayoutPolicy.maximumSurfaceWidth) / 2
                XCTAssertGreaterThanOrEqual(capture.inputFrame.minX, boundedInset)
                XCTAssertLessThanOrEqual(capture.inputFrame.maxX, fixture.width - boundedInset)
            } else {
                XCTAssertGreaterThanOrEqual(capture.inputFrame.minX, 0)
                XCTAssertLessThanOrEqual(capture.inputFrame.maxX, fixture.width)
            }

            let attachment = XCTAttachment(image: capture.image)
            attachment.name = "quick-session-zero-pane-\(fixture.name)-\(Int(fixture.width))pt-structural"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func hostedZeroPaneQuickSession(
        width: CGFloat,
        height: CGFloat
    ) throws -> (image: NSImage, inputFrame: NSRect, inputCount: Int) {
        let deck = MacSessionPaneDeck()
        let root = MacSessionPaneDeckView(
            deck: deck,
            workspaces: [quickSessionWorkspace()],
            isStoppingSession: { _ in false },
            stopTarget: { _ in },
            loadWorktrees: { _ in [] },
            launchQuickSession: { _, _ in },
            loadsSessionsOnMount: false
        )
        .frame(width: width, height: height)
        .background(AppTheme.dark.bg.primary)
        .environment(\.theme, AppTheme.dark)
        .environment(\.themeID, ThemeID.dark)
        .tint(.themeBlue)
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(AppTheme.dark.bg.primary)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let inputs = visualDescendants(of: host, type: MacComposerPasteTextView.self)
        let input = try XCTUnwrap(inputs.first)
        let inputFrame = input.convert(input.bounds, to: host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MacComposerSnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return (image, inputFrame, inputs.count)
    }

    private func quickSessionWorkspace() -> Workspace {
        Workspace(
            id: "visual-workspace",
            name: "Oppi",
            description: nil,
            icon: .symbol("folder"),
            systemPrompt: nil,
            hostMount: "/tmp/oppi",
            tools: nil,
            gitStatusEnabled: nil,
            runtime: .host,
            sandboxConfig: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func assertComposerGeometry(
        _ image: NSImage,
        composerWidth: CGFloat,
        context: String,
        maximumHeight: CGFloat = 360,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let fixturePadding: CGFloat = 24 * 2
        XCTAssertEqual(
            image.size.width,
            composerWidth + fixturePadding,
            accuracy: 1,
            "Unexpected snapshot width for \(context)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            image.size.height,
            72,
            "Composer content did not paint for \(context)",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            image.size.height,
            maximumHeight,
            "Composer expanded beyond the bounded fixture for \(context)",
            file: file,
            line: line
        )
    }

    private func measureComposerHeightInOverlay(
        store: MacSessionTraceStore,
        width: CGFloat,
        overlayHeight: CGFloat,
        attachmentName: String
    ) throws -> (height: CGFloat, image: NSImage) {
        let heightBox = MacComposerHeightBox()
        let image = try hostedOverlaySnapshot(
            of: MacComposerOverlayHost(store: store, heightBox: heightBox)
                .frame(width: width, height: overlayHeight)
                .background(AppTheme.dark.bg.primary)
                .environment(\.theme, AppTheme.dark)
                .environment(\.themeID, ThemeID.dark)
                .tint(.themeBlue)
                .preferredColorScheme(.dark),
            width: width,
            height: overlayHeight,
            heightBox: heightBox
        )
        let attachment = XCTAttachment(image: image)
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(
            heightBox.height,
            72,
            "Composer content did not paint for \(attachmentName)"
        )
        return (heightBox.height, image)
    }

    private func applyQueueState(
        _ queue: MessageQueueState,
        to store: MacSessionTraceStore,
        target: MacSelectedSessionTarget
    ) {
        store.applyServerMessageForTesting(.queueState(queue: queue), target: target)
    }

    private func applyWidgetLines(
        _ lines: [String],
        to store: MacSessionTraceStore,
        target: MacSelectedSessionTarget
    ) {
        store.applyServerMessageForTesting(
            .extensionUINotification(
                ExtensionUINotification(
                    method: "setWidget",
                    message: nil,
                    notifyType: nil,
                    statusKey: nil,
                    statusText: nil,
                    title: nil,
                    text: nil,
                    widgetKey: "jobs",
                    widgetLines: lines,
                    widgetPlacement: "aboveEditor"
                )
            ),
            target: target
        )
    }

    /// `ImageRenderer` paints AppKit-backed controls as yellow prohibited
    /// placeholders. Hosting in a real offscreen window preserves structural
    /// layout while the desktop is locked. Liquid Glass still requires the
    /// final running-window screenshot, so these attachments say structural.
    private func hostedSnapshot<Content: View>(of root: Content) throws -> NSImage {
        let host = NSHostingView(rootView: root)
        let fitted = host.fittingSize
        host.frame = NSRect(
            origin: .zero,
            size: NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
        )
        return try snapshotHostedView(host)
    }

    private func hostedOverlaySnapshot<Content: View>(
        of root: Content,
        width: CGFloat,
        height: CGFloat,
        heightBox: MacComposerHeightBox
    ) throws -> NSImage {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(AppTheme.dark.bg.primary)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let deadline = Date().addingTimeInterval(2)
        var lastHeight: CGFloat = 0
        var stableCount = 0
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
            if heightBox.height > 72, abs(heightBox.height - lastHeight) < 0.5 {
                stableCount += 1
                if stableCount >= 3 {
                    break
                }
            } else {
                stableCount = 0
                lastHeight = heightBox.height
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MacComposerSnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func snapshotHostedView(_ host: NSHostingView<some View>) throws -> NSImage {
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(AppTheme.dark.bg.primary)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MacComposerSnapshotError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func makeTarget(status: SessionStatus) -> MacSelectedSessionTarget {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(
            id: "visual-\(status.rawValue)",
            workspaceId: "visual-workspace",
            workspaceName: "Oppi",
            status: status,
            createdAt: now,
            lastActivity: now,
            model: "openai/gpt-5.6-sol",
            messageCount: 12,
            tokens: TokenUsage(input: 48_200, output: 3_400),
            cost: 2.31,
            firstMessage: "Polish the Mac live-session experience",
            thinkingLevel: "high",
            runtime: .oppi
        )
        return MacSelectedSessionTarget(
            workspaceId: "visual-workspace",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
    }
}

@MainActor
private final class MacComposerHeightBox {
    var height: CGFloat = 0
}

private struct MacComposerOverlayHost: View {
    let store: MacSessionTraceStore
    let heightBox: MacComposerHeightBox
    @Environment(\.theme) private var theme
    @FocusState private var focus: KeybindingFocus?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                MacSessionComposerBar(store: store, sessionFocus: $focus)
                    .background(
                        theme.bg.highlight.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: {
                        heightBox.height = $0
                    }
            }
    }
}

private struct MacComposerSnapshotHost: View {
    let store: MacSessionTraceStore
    let initialDraft: String
    let initialAttachments: [MacPendingAttachment]
    @Environment(\.theme) private var theme
    @FocusState private var focus: KeybindingFocus?

    init(
        store: MacSessionTraceStore,
        initialDraft: String = "",
        initialAttachments: [MacPendingAttachment] = []
    ) {
        self.store = store
        self.initialDraft = initialDraft
        self.initialAttachments = initialAttachments
    }

    var body: some View {
        MacSessionComposerBar(
            store: store,
            sessionFocus: $focus,
            initialDraft: initialDraft,
            initialAttachments: initialAttachments
        )
            // `cacheDisplay` flattens compositor-only glass. This test-only
            // backdrop keeps contrast inspectable without altering production.
            .background(
                theme.bg.highlight.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacTimelineSnapshotHost: View {
    let store: MacSessionTraceStore
    let isLoading: Bool
    let lastError: String?
    let isBusy: Bool
    var items: [ChatItem] = []
    @FocusState private var focus: KeybindingFocus?

    var body: some View {
        MacSessionTimelineView(
            isLoading: isLoading,
            lastError: lastError,
            items: items,
            isBusy: isBusy,
            store: store,
            sessionFocus: $focus
        )
    }
}

@MainActor
private func visualDescendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
    var matches: [T] = []
    if let match = root as? T {
        matches.append(match)
    }
    for subview in root.subviews {
        matches.append(contentsOf: visualDescendants(of: subview, type: type))
    }
    return matches
}

private enum MacComposerSnapshotError: Error {
    case noBitmap
}
