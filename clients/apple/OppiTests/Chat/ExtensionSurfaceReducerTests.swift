import Foundation
import Testing
@testable import Oppi

@Suite("Shared extension surface reducer")
struct ExtensionSurfaceReducerTests {
    @Test func nativeWidgetTakesPrecedenceOverTextLines() {
        var surface = ExtensionSurfaceState()
        let native = makeNativeSurface(id: "widget:jobs", title: "Jobs", text: "Agents active")
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "jobs", lines: ["Agents active"], nativeSurface: native),
            to: &surface
        )

        #expect(surface.nativeSurfaces["widget:jobs"]?.key == "jobs")
        #expect(surface.nativeSurfaces["widget:jobs"]?.order == 1)
        #expect(surface.widgets["jobs"] == nil)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["native:jobs"])
    }

    @Test func textWidgetStoresLinesWhenNativeSurfaceIsAbsent() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["Keep going"]),
            to: &surface
        )

        #expect(surface.widgets["goal"]?.lines == ["Keep going"])
        #expect(surface.nativeSurfaces.isEmpty)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["widget:goal"])
    }

    @Test func mixedWidgetsPreserveArrivalOrder() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            widgetNotification(
                key: "jobs",
                lines: ["Agents active"],
                nativeSurface: makeNativeSurface(id: "widget:jobs", title: "Agents", text: "Agents active")
            ),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["Goal active"]),
            to: &surface
        )

        #expect(surface.nativeSurfaces["widget:jobs"]?.order == 1)
        #expect(surface.widgets["goal"]?.order == 2)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["native:jobs", "widget:goal"])
    }

    @Test func replacingAWidgetMovesItToLatestPosition() {
        var surface = ExtensionSurfaceState()
        let native = makeNativeSurface(id: "widget:jobs", title: "Agents", text: "Agents active")
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "jobs", lines: ["Agents active"], nativeSurface: native),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["Goal active"]),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "jobs", lines: ["Agents updated"], nativeSurface: native),
            to: &surface
        )

        #expect(surface.nativeSurfaces["widget:jobs"]?.order == 3)
        #expect(surface.widgets["goal"]?.order == 2)
        #expect(surface.widgetEntries(in: .aboveEditor).map(\.id) == ["widget:goal", "native:jobs"])
    }

    @Test func belowEditorPlacementIsSeparateFromAbove() {
        var surface = ExtensionSurfaceState()
        let native = makeNativeSurface(id: "widget:below", title: "Below editor", text: "Rendered below the composer")
        ExtensionSurfaceReducer.apply(
            widgetNotification(
                key: "below",
                lines: ["Rendered below the composer"],
                placement: "belowEditor",
                nativeSurface: native
            ),
            to: &surface
        )

        #expect(surface.widgetEntries(in: .aboveEditor).isEmpty)
        #expect(surface.widgetEntries(in: .belowEditor).map(\.id) == ["native:below"])
        #expect(surface.hasVisibleContent(in: .belowEditor))
        #expect(!surface.hasVisibleContent(in: .aboveEditor))
    }

    @Test func emptyWidgetLinesClearTheSurface() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["Keep going"]),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["", "\n"]),
            to: &surface
        )

        #expect(surface.widgets["goal"] == nil)
        #expect(!surface.hasVisibleContent)
        #expect(!surface.hasRetainedContent)
    }

    @Test func nilWidgetPayloadClearsNativeAndText() {
        var surface = ExtensionSurfaceState()
        let native = makeNativeSurface(id: "widget:jobs", title: "Jobs", text: "Busy")
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "jobs", lines: ["Busy"], nativeSurface: native),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(widgetNotification(key: "jobs"), to: &surface)

        #expect(surface.widgets.isEmpty)
        #expect(surface.nativeSurfaces.isEmpty)
    }

    @Test func arbitraryWidgetKeysShareTheSamePaintPath() {
        var surface = ExtensionSurfaceState()
        for key in ["goal", "working-words", "pi-review", "custom-key-99"] {
            ExtensionSurfaceReducer.apply(
                widgetNotification(key: key, lines: ["row for \(key)"]),
                to: &surface
            )
        }

        let entries = surface.widgetEntries(in: .aboveEditor)
        #expect(entries.count == 4)
        #expect(Set(entries.map(\.id)) == [
            "widget:goal",
            "widget:working-words",
            "widget:pi-review",
            "widget:custom-key-99",
        ])
    }

    @Test func statusDoesNotBecomeAWidgetEntry() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setStatus",
                message: nil,
                notifyType: nil,
                statusKey: "jobs",
                statusText: "1 running agent",
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )

        #expect(surface.widgetEntries(in: .aboveEditor).isEmpty)
        #expect(surface.standaloneStatusEntries().map(\.text) == ["1 running agent"])
        #expect(surface.hasVisibleContent(in: .aboveEditor))
    }

    @Test func setTitleIsAboveEditorChromeOnly() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setTitle",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: "Session label",
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )

        #expect(surface.title == "Session label")
        #expect(surface.hasVisibleMetadata(in: .aboveEditor))
        #expect(!surface.hasVisibleMetadata(in: .belowEditor))
    }

    @Test func workingMessageVisibleAndIndicatorAreRetainedWithoutVisibleChrome() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setWorkingMessage",
                message: "Running checks",
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setWorkingVisible",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil,
                workingVisible: false
            ),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setWorkingIndicator",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil,
                workingIndicator: ExtensionUIWorkingIndicator(frames: ["●"], intervalMs: 250)
            ),
            to: &surface
        )

        #expect(surface.working?.message == "Running checks")
        #expect(surface.working?.visible == false)
        #expect(surface.working?.indicator?.frames == ["●"])
        #expect(surface.working?.indicator?.intervalMs == 250)
        #expect(!surface.hasVisibleContent)
        #expect(surface.hasRetainedContent)
    }

    @Test func hiddenThinkingLabelStoresTrimmedTextAndClearsToEmpty() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setHiddenThinkingLabel",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil,
                hiddenThinkingLabel: " Private reasoning "
            ),
            to: &surface
        )

        #expect(surface.hiddenThinkingLabel == "Private reasoning")
        #expect(surface.hasRetainedContent)

        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setHiddenThinkingLabel",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )

        #expect(surface.hiddenThinkingLabel == nil)
        #expect(!surface.hasRetainedContent)
    }

    @Test func toolsExpandedFalseStillRetainsTimelineState() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setToolsExpanded",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil,
                toolsExpanded: true
            ),
            to: &surface
        )
        #expect(surface.toolsExpanded == true)

        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setToolsExpanded",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil,
                toolsExpanded: false
            ),
            to: &surface
        )

        #expect(surface.toolsExpanded == false)
        #expect(surface.hasRetainedContent)
        #expect(!surface.hasVisibleContent)
    }

    @Test func notifyAndEditorTextDoNotMutateProtocolSurfaceState() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            widgetNotification(key: "goal", lines: ["Keep going"]),
            to: &surface
        )
        let before = surface

        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "notify",
                message: "Task complete",
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "set_editor_text",
                message: nil,
                notifyType: nil,
                statusKey: nil,
                statusText: nil,
                title: nil,
                text: "composer draft",
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )

        #expect(surface == before)
    }

    @Test func sameRawKeyAttachesStatusToNativeSurface() {
        var surface = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(
            widgetNotification(
                key: "goal",
                lines: ["Keep working"],
                nativeSurface: makeNativeSurface(id: "widget:goal", title: "Goal", text: "Keep working")
            ),
            to: &surface
        )
        ExtensionSurfaceReducer.apply(
            ExtensionUINotification(
                method: "setStatus",
                message: nil,
                notifyType: nil,
                statusKey: "goal",
                statusText: "goal: Active 1/25",
                title: nil,
                text: nil,
                widgetKey: nil,
                widgetLines: nil,
                widgetPlacement: nil
            ),
            to: &surface
        )

        #expect(surface.standaloneStatusEntries().isEmpty)
        #expect(surface.attachedStatusText(for: "goal", extensionScopeId: nil) == "goal: Active 1/25")
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
