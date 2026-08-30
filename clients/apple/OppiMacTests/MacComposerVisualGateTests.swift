import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import Oppi

@MainActor
final class MacComposerVisualGateTests: XCTestCase {
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
    @FocusState private var focus: KeybindingFocus?

    var body: some View {
        MacSessionTimelineView(
            isLoading: isLoading,
            lastError: lastError,
            items: [],
            isBusy: isBusy,
            store: store,
            sessionFocus: $focus
        )
    }
}

private enum MacComposerSnapshotError: Error {
    case noBitmap
}
