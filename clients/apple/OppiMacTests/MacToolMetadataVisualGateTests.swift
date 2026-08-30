import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Oppi

@MainActor
final class MacToolMetadataVisualGateTests: XCTestCase {
    func testReducerOwnedMetadataPaintsInCollapsedToolRows() async throws {
        let store = try await makeStore()
        defer { store.clearSelection() }

        XCTAssertEqual(store.toolElapsed(for: "tool-lookup"), 12)
        XCTAssertEqual(store.toolElapsed(for: "tool-edit"), 3)
        XCTAssertEqual(
            store.toolResultSegments(for: "tool-lookup"),
            [
                StyledSegment(text: "12 matches", style: .success),
                StyledSegment(text: " cached", style: .muted),
            ]
        )

        let width: CGFloat = 760
        let height: CGFloat = 240
        let root = MacToolMetadataVisualFixture(store: store)
            .frame(width: width, height: height)
            .environment(\.theme, AppTheme.dark)
            .environment(\.themeID, ThemeID.dark)
            .tint(.themeBlue)
            .preferredColorScheme(.dark)

        let image = try capture(root, width: width, height: height)
        XCTAssertEqual(image.size.width, width, accuracy: 1)
        XCTAssertEqual(image.size.height, height, accuracy: 1)

        let attachment = XCTAttachment(image: image)
        attachment.name = "mac-tool-metadata-dark-760x240"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNightThemeRepaintsCollapsedToolRowsWithActivePalette() async throws {
        let store = try await makeStore()
        defer { store.clearSelection() }
        let width: CGFloat = 760
        let height: CGFloat = 240

        let darkImage = try capture(
            MacToolMetadataVisualFixture(store: store)
                .frame(width: width, height: height)
                .environment(\.theme, AppTheme.dark)
                .environment(\.themeID, ThemeID.dark)
                .tint(.themeBlue)
                .preferredColorScheme(.dark),
            width: width,
            height: height
        )
        let nightImage = try capture(
            MacToolMetadataVisualFixture(store: store)
                .frame(width: width, height: height)
                .environment(\.theme, AppTheme.night)
                .environment(\.themeID, ThemeID.night)
                .tint(.themeBlue)
                .preferredColorScheme(.dark),
            width: width,
            height: height
        )

        XCTAssertEqual(nightImage.size, darkImage.size)
        XCTAssertNotEqual(
            nightImage.tiffRepresentation,
            darkImage.tiffRepresentation,
            "Collapsed tool rows must repaint when the semantic palette changes"
        )

        let attachment = XCTAttachment(image: nightImage)
        attachment.name = "mac-tool-metadata-night-760x240"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeStore() async throws -> MacSessionTraceStore {
        let store = MacSessionTraceStore()
        let session = Session(
            id: "metadata-visual-session",
            workspaceId: "metadata-visual-workspace",
            workspaceName: "Oppi",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_015),
            model: "openai/gpt-5.6-sol",
            messageCount: 4,
            tokens: TokenUsage(input: 1_200, output: 320),
            cost: 0.04,
            firstMessage: "Polish Mac tool metadata"
        )
        let target = MacSelectedSessionTarget(
            workspaceId: "metadata-visual-workspace",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )
        store.select(target)
        await store.installSessionRuntimeForTesting(client: makeClient())

        let manager = try XCTUnwrap(store._chatSessionManagerForTesting)
        manager.reducer.loadSession(metadataTrace(), preserveOrphans: false)
        XCTAssertEqual(manager.reducer.items.count, 2)
        return store
    }

    private func metadataTrace() -> [TraceEvent] {
        let lookupCallSegments = [
            StyledSegment(text: "Lookup", style: .bold),
            StyledSegment(text: " theme tokens", style: .accent),
        ]
        let lookupResultSegments = [
            StyledSegment(text: "12 matches", style: .success),
            StyledSegment(text: " cached", style: .muted),
        ]
        let editArgs: [String: JSONValue] = [
            "path": .string("clients/apple/OppiMac/Views/MacSessionTimelineViews.swift"),
            "edits": .array([
                .object([
                    "oldText": .string("Text(status)"),
                    "newText": .string("Text(result)\nText(elapsed)"),
                ]),
            ]),
        ]

        return [
            TraceEvent(
                id: "tool-lookup",
                type: .toolCall,
                timestamp: "2027-01-15T12:00:00.000Z",
                tool: "extensions.lookup",
                args: ["query": .string("theme tokens")],
                callSegments: lookupCallSegments,
                lifecycleBefore: [
                    TraceLifecycleEvent(
                        id: "lifecycle-lookup-start",
                        event: .toolStart,
                        timestamp: "2027-01-15T12:00:00.000Z",
                        toolCallId: "tool-lookup",
                        toolName: "extensions.lookup"
                    ),
                ]
            ),
            TraceEvent(
                id: "result-lookup",
                type: .toolResult,
                timestamp: "2027-01-15T12:00:12.000Z",
                output: "Found 12 matching theme tokens.",
                toolCallId: "tool-lookup",
                toolName: "extensions.lookup",
                isError: false,
                resultSegments: lookupResultSegments,
                lifecycleAfter: [
                    TraceLifecycleEvent(
                        id: "lifecycle-lookup-end",
                        event: .toolEnd,
                        timestamp: "2027-01-15T12:00:12.000Z",
                        toolCallId: "tool-lookup",
                        toolName: "extensions.lookup",
                        isError: false
                    ),
                ]
            ),
            TraceEvent(
                id: "tool-edit",
                type: .toolCall,
                timestamp: "2027-01-15T12:00:13.000Z",
                tool: "edit",
                args: editArgs,
                lifecycleBefore: [
                    TraceLifecycleEvent(
                        id: "lifecycle-edit-start",
                        event: .toolStart,
                        timestamp: "2027-01-15T12:00:13.000Z",
                        toolCallId: "tool-edit",
                        toolName: "edit"
                    ),
                ]
            ),
            TraceEvent(
                id: "result-edit",
                type: .toolResult,
                timestamp: "2027-01-15T12:00:16.000Z",
                output: "Updated MacSessionTimelineViews.swift",
                toolCallId: "tool-edit",
                toolName: "edit",
                isError: false,
                resultSegments: [StyledSegment(text: "modified", style: .success)],
                lifecycleAfter: [
                    TraceLifecycleEvent(
                        id: "lifecycle-edit-end",
                        event: .toolEnd,
                        timestamp: "2027-01-15T12:00:16.000Z",
                        toolCallId: "tool-edit",
                        toolName: "edit",
                        isError: false
                    ),
                ]
            ),
        ]
    }

    private func makeClient() -> MacWorkspaceClient {
        MacWorkspaceClient(
            socketPath: "/tmp/oppi-mac-tool-metadata-visual.sock",
            token: "sk_owner",
            transport: RecordingLocalHTTPTransport(response: MacLocalHTTPResponse(
                statusCode: 200,
                headers: ["content-type": "application/json"],
                body: Data("{}".utf8)
            ))
        )
    }

    private func capture<Content: View>(
        _ root: Content,
        width: CGFloat,
        height: CGFloat
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
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw MacToolMetadataVisualGateError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

private struct MacToolMetadataVisualFixture: View {
    let store: MacSessionTraceStore
    @FocusState private var sessionFocus: KeybindingFocus?

    var body: some View {
        MacSessionTimelineView(
            isLoading: false,
            lastError: nil,
            items: store.items,
            sessionID: store.selectedTarget?.sessionId,
            workspaceID: store.selectedTarget?.workspaceId,
            toolOutputStore: store.toolOutputStore,
            loadFullToolOutput: { _ in },
            bottomContentInset: 0,
            isBusy: false,
            store: store,
            sessionFocus: $sessionFocus
        )
    }
}

private enum MacToolMetadataVisualGateError: Error {
    case noBitmap
}
