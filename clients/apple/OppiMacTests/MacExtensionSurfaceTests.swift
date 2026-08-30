import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac session trace extension surfaces")
struct MacSessionTraceStoreExtensionSurfaceTests {
    @Test func storesFocusedWidgetNotificationsAndClearsOnSessionEnd() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        store.applyServerMessageForTesting(
            .extensionUINotification(
                widgetNotification(
                    key: "jobs",
                    lines: ["Agents active"],
                    nativeSurface: makeNativeSurface(id: "widget:jobs", title: "Agents", text: "Agents active")
                )
            ),
            target: target
        )

        #expect(store.extensionSurface.widgetEntries(in: .aboveEditor).map(\.id) == ["native:jobs"])

        store.applyServerMessageForTesting(.sessionEnded(reason: "stopped"), target: target)
        #expect(!store.extensionSurface.hasVisibleContent)
    }

    @Test func ignoresWidgetNotificationsForOtherSessions() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)

        store.applyServerMessageForTesting(
            .extensionUINotification(widgetNotification(key: "goal", lines: ["Keep going"])),
            target: MacSelectedSessionTarget(
                workspaceId: target.workspaceId,
                sessionId: "other-session",
                summary: target.summary
            )
        )

        #expect(!store.extensionSurface.hasVisibleContent)
    }

    @Test func selectingAnotherSessionClearsWidgets() {
        let store = MacSessionTraceStore()
        let target = makeTarget()
        store.select(target)
        store.applyServerMessageForTesting(
            .extensionUINotification(widgetNotification(key: "goal", lines: ["Keep going"])),
            target: target
        )
        #expect(store.extensionSurface.hasVisibleContent)

        store.select(makeTarget(sessionId: "session-2"))
        #expect(!store.extensionSurface.hasVisibleContent)
    }
}

@Suite("Mac extension surface composer wiring")
struct MacExtensionSurfaceComposerSourceTests {
    @Test func composerPaintsGenericPanelsAboveAndBelowTheEditor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("MacExtensionSurfacePanel"))
        #expect(source.contains("placement: .aboveEditor"))
        #expect(source.contains("placement: .belowEditor"))
        #expect(source.contains("currentAskRequest == nil"))
        #expect(!source.contains("NSEvent.addLocalMonitor"))
    }

    @Test func painterDoesNotBranchOnToolOrExtensionNames() throws {
        let source = try panelSource()
        #expect(!source.contains("widgetKey =="))
        #expect(!source.contains("extensionDisplayName =="))
        #expect(!source.contains("case \"goal\""))
        #expect(!source.contains("case \"working-words\""))
        #expect(!source.contains("toolName"))
    }

    @Test func eachPlacementIsOneBoundedScrollingSurface() throws {
        let source = try panelSource()
        #expect(source.contains("expandedMaxHeight"))
        #expect(source.contains("MacExtensionBoundedSurface"))
        #expect(source.contains("mac.extension.surface.scroll"))
        #expect(!source.contains("NSEvent.addLocalMonitor"))
    }

    @Test func activityRowLinksUseTheSameOpenURLActionPathAsSpans() throws {
        let source = try panelSource()
        #expect(source.contains("OpenURLAction"))
        #expect(source.contains("row.link"))
        #expect(source.contains("MacExtensionSurfaceLink.url"))
        #expect(!source.contains("widgetKey =="))
        #expect(!source.contains("case \"goal\""))
    }

    private func panelSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacExtensionSurfacePanel.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

@Suite("Mac extension surface links")
struct MacExtensionSurfaceLinkTests {
    @Test func parsesSpanAndActivityRowLinksTheSameWay() {
        #expect(MacExtensionSurfaceLink.url(from: "https://example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(MacExtensionSurfaceLink.url(from: "oppi://session/child-1")?.scheme == "oppi")
        #expect(MacExtensionSurfaceLink.url(from: "file:///tmp/report.md")?.scheme == "file")
        #expect(MacExtensionSurfaceLink.url(from: nil) == nil)
        #expect(MacExtensionSurfaceLink.url(from: "") == nil)
        #expect(MacExtensionSurfaceLink.url(from: "docs/foo.md") == nil)
        #expect(MacExtensionSurfaceLink.url(from: "[[wiki]]") == nil)
    }

    @Test func expandedPlacementBudgetIsBounded() {
        #expect(MacExtensionSurfaceLayout.expandedMaxHeight == 260)
        #expect(MacExtensionSurfaceLayout.expandedMaxHeight > 0)
    }
}

private func widgetNotification(
    key: String,
    lines: [String]? = nil,
    placement: String? = nil,
    nativeSurface: ExtensionUINativeSurface? = nil
) -> ExtensionUINotification {
    ExtensionUINotification(
        method: "setWidget",
        message: nil,
        notifyType: nil,
        statusKey: nil,
        statusText: nil,
        title: nil,
        text: nil,
        widgetKey: key,
        widgetLines: lines,
        widgetPlacement: placement,
        nativeSurface: nativeSurface
    )
}

private func makeNativeSurface(id: String, title: String, text: String) -> ExtensionUINativeSurface {
    ExtensionUINativeSurface(
        version: 1,
        id: id,
        source: "widget",
        presentation: ExtensionUINativePresentation(style: "surfacePanel", title: title, subtitle: nil),
        blocks: [
            .text(
                base: ExtensionUIBlockBase(id: "body", accessibility: nil),
                spans: [ExtensionUITextSpan(text: text, role: nil, traits: nil, link: nil)]
            ),
        ],
        fallback: nil
    )
}

private func makeTarget(sessionId: String = "session-1") -> MacSelectedSessionTarget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = Session(
        id: sessionId,
        workspaceId: "workspace-1",
        workspaceName: "Workspace",
        status: .busy,
        createdAt: now,
        lastActivity: now,
        model: "provider/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello"
    )
    return MacSelectedSessionTarget(
        workspaceId: "workspace-1",
        sessionId: sessionId,
        summary: SessionSummary(from: session)
    )
}
