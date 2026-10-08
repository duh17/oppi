import Testing
import UIKit
@testable import Oppi

/// Transitions of the hosted media and document viewport (read-media, CSV/TSV
/// tables, GeoJSON maps) that the mode-dispatch and surface-host suites do not
/// exercise: reuse across content kinds, collapse and reuse while media is still
/// loading, unchanged versus changed content on re-apply, and width changes.
/// They drive the row through its public configuration, so they hold for any
/// ownership of the hosted state.
@Suite("Tool expanded hosted surface")
@MainActor
struct ToolExpandedHostedSurfaceTests {
    // MARK: - Reuse across content kinds

    @Test func tableReusedForMarkdownDropsTheTableAndComesBackFresh() throws {
        let view = ToolTimelineRowContentView(configuration: tableConfiguration())
        _ = fittedTimelineSize(for: view, width: 360)
        let first = try #require(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view))
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)

        view.configuration = markdownConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)
        #expect(first.superview == nil, "The table must not outlive the switch to Markdown")
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) == nil)

        view.configuration = tableConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        let second = try #require(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view))
        #expect(second !== first, "Returning to a table must not resurrect the earlier view")
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
        #expect(timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view) == nil)
    }

    @Test func readMediaReusedForMarkdownDropsTheMediaViewAndComesBackFresh() throws {
        let view = ToolTimelineRowContentView(configuration: readMediaConfiguration())
        _ = fittedTimelineSize(for: view, width: 360)
        let first = try #require(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view))
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)

        view.configuration = markdownConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)
        #expect(first.superview == nil)
        #expect(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view) == nil)

        view.configuration = readMediaConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        let second = try #require(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view))
        #expect(second !== first)
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
        #expect(
            timelineFirstView(ofType: NativeFullScreenMarkdownBody.self, in: view) == nil,
            "The completed Markdown reader must not outlive the switch to a hosted media view"
        )
    }

    @Test func hostedKindsReplaceEachOtherWithoutLeavingTheOldView() throws {
        let view = ToolTimelineRowContentView(configuration: tableConfiguration())
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) != nil)

        view.configuration = mapConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) == nil)
        #expect(timelineFirstView(ofType: GeoJSONMapView.self, in: view) != nil)

        view.configuration = readMediaConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(timelineFirstView(ofType: GeoJSONMapView.self, in: view) == nil)
        #expect(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view) != nil)
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
    }

    // MARK: - Re-apply and collapse

    @Test func reapplyingIdenticalTableKeepsTheMountedViewAndChangedTextReplacesIt() throws {
        let view = ToolTimelineRowContentView(configuration: tableConfiguration())
        _ = fittedTimelineSize(for: view, width: 360)
        let first = try #require(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view))

        view.configuration = tableConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) === first)

        view.configuration = tableConfiguration(csv: "date,route\n2026-09-03,Ferry")
        _ = fittedTimelineSize(for: view, width: 360)
        let changed = try #require(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view))
        #expect(changed !== first)
        #expect(first.superview == nil)
    }

    @Test func reapplyingIdenticalMapKeepsTheMountedView() throws {
        let view = ToolTimelineRowContentView(configuration: mapConfiguration())
        _ = fittedTimelineSize(for: view, width: 360)
        let first = try #require(timelineFirstView(ofType: GeoJSONMapView.self, in: view))

        view.configuration = mapConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(timelineFirstView(ofType: GeoJSONMapView.self, in: view) === first)
    }

    @Test func collapsingHostedContentReleasesItAndExpandingBuildsAFreshView() throws {
        for content in [tableConfiguration(), mapConfiguration(), readMediaConfiguration()] {
            let view = ToolTimelineRowContentView(configuration: content)
            _ = fittedTimelineSize(for: view, width: 360)
            #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
            let hosted = try #require(hostedContentView(in: view))

            view.configuration = collapsedConfiguration()
            _ = fittedTimelineSize(for: view, width: 360)
            #expect(view.expandedContainer.isHidden)
            #expect(view.activeExpandedSurfaceKindForTesting == .none)
            #expect(hosted.superview == nil, "Collapse must drop the hosted view")

            view.configuration = content
            _ = fittedTimelineSize(for: view, width: 360)
            let remounted = try #require(hostedContentView(in: view))
            #expect(remounted !== hosted)
            #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
        }
    }

    // MARK: - Async media

    @Test func collapsingWhileMediaLoadsIgnoresTheLateCompletion() async throws {
        let gate = FetchGate()
        let view = ToolTimelineRowContentView(configuration: lazySVGConfiguration(gate: gate))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { await gate.started == 1 })
        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)

        weak var weakMedia: NativeExpandedReadMediaView? = timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view)
        #expect(weakMedia != nil)

        view.configuration = collapsedConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.expandedContainer.isHidden)

        await gate.open()
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { await gate.finished == 1 })
        try await settle()

        #expect(view.expandedContainer.isHidden)
        #expect(view.activeExpandedSurfaceKindForTesting == .none)
        #expect(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view) == nil)
        #expect(timelineFirstView(ofType: NativeExpandedInlineImageView.self, in: view) == nil)
        #expect(weakMedia == nil, "The collapsed row must not keep the media view alive")
    }

    @Test func reuseWhileMediaLoadsKeepsTheNewContentAndIgnoresTheLateCompletion() async throws {
        let gate = FetchGate()
        let view = ToolTimelineRowContentView(configuration: lazySVGConfiguration(gate: gate))
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { await gate.started == 1 })

        view.configuration = tableConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        let table = try #require(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view))

        await gate.open()
        #expect(await waitForTimelineCondition(timeoutMs: 2_000) { await gate.finished == 1 })
        try await settle()

        #expect(view.activeExpandedSurfaceKindForTesting == .hosted)
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) === table)
        #expect(timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view) == nil)
        #expect(timelineFirstView(ofType: NativeExpandedInlineImageView.self, in: view) == nil)

        view.configuration = markdownConfiguration()
        _ = fittedTimelineSize(for: view, width: 360)
        #expect(view.activeExpandedSurfaceKindForTesting == .markdown)
        #expect(timelineFirstView(ofType: DelimitedTableRenderView.self, in: view) == nil)
    }

    // MARK: - Width

    @Test func hostedViewsTrackTheViewportWidthAcrossAWidthChange() throws {
        for content in [tableConfiguration(), mapConfiguration(), readMediaConfiguration()] {
            let view = ToolTimelineRowContentView(configuration: content)
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 900))
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            let width = container.widthAnchor.constraint(equalToConstant: 360)
            NSLayoutConstraint.activate([
                width,
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
            container.layoutIfNeeded()
            let hosted = try #require(hostedContentView(in: view))
            let wide = view.expandedScrollView.bounds.width
            #expect(wide > 300)
            #expect(abs(hosted.bounds.width - wide) < 0.5)

            width.constant = 280
            container.frame.size.width = 280
            container.setNeedsLayout()
            container.layoutIfNeeded()
            let narrow = view.expandedScrollView.bounds.width
            #expect(narrow < wide - 40)
            #expect(abs(hosted.bounds.width - narrow) < 0.5, "Hosted content must follow the viewport width")
            withExtendedLifetime(container) {}
        }
    }

    // MARK: - Surface API

    @Test func installsMountOnceAndReuseTheViewWhenContentIsUnchanged() throws {
        let harness = HostedSurfaceHarness()
        let surface = harness.surface
        let csv = "date,route\n2026-09-01,Lake"

        #expect(surface.installDocument(itemID: "row", family: .delimitedTable(text: csv, filePath: "rides.csv")), "First install mounts a view")
        let table = try #require(surface.contentView as? DelimitedTableRenderView)
        #expect(!surface.installDocument(itemID: "row", family: .delimitedTable(text: csv, filePath: "rides.csv")), "Identical content reuses the view")
        #expect(surface.contentView === table)

        #expect(surface.installDocument(itemID: "row", family: .delimitedTable(text: csv + "\n2026-09-02,Ship", filePath: "rides.csv")))
        #expect(surface.contentView !== table)
        #expect(table.superview == nil)
        #expect(surface.container.subviews.count == 1)

        #expect(surface.installDocument(itemID: "row", family: .geoJSON(text: Self.point, filePath: "p.geojson")))
        #expect(surface.contentView is GeoJSONMapView)
        #expect(surface.container.subviews.count == 1, "A new kind replaces the old view")
        #expect(!surface.installDocument(itemID: "row", family: .geoJSON(text: Self.point, filePath: "p.geojson")))
    }

    @Test func retiringDropsContentAndLeavesTheExpandedLayout() throws {
        let harness = HostedSurfaceHarness()
        let surface = harness.surface
        surface.installDocument(itemID: "row", family: .geoJSON(text: Self.point, filePath: "p.geojson"))
        harness.activate()
        #expect(surface.isActive)
        #expect(!surface.container.isHidden)
        let map = try #require(surface.contentView)

        surface.retire()
        #expect(!surface.isActive)
        #expect(surface.container.isHidden)
        #expect(surface.contentView == nil)
        #expect(map.superview == nil)

        #expect(surface.installDocument(itemID: "row", family: .geoJSON(text: Self.point, filePath: "p.geojson")), "A retired surface mounts a fresh view")
        #expect(surface.contentView !== map)
    }

    @Test func tablesFollowTheViewportHeightButOtherHostedContentDoesNot() throws {
        let harness = HostedSurfaceHarness(viewportHeight: 30)
        let surface = harness.surface
        surface.installDocument(itemID: "row", family: .delimitedTable(text: "a,b\n1,2\n3,4\n5,6", filePath: "t.csv"))
        harness.activate()
        harness.layout()
        #expect(abs(surface.container.bounds.height - 30) < 0.5, "A table is pinned to the capped viewport")

        surface.installAudioMessage(
            itemID: "row",
            text: "Spoken reply",
            attachmentId: "",
            mimeType: "audio/wav",
            playbackBehavior: nil,
            suppressAutoplay: true,
            durationSeconds: 1,
            resources: .none
        )
        harness.layout()
        #expect(surface.container.bounds.height > 30 + 0.5, "Leaving a table must release the viewport pin")
    }

    // MARK: - Fixtures

    private func hostedContentView(in view: ToolTimelineRowContentView) -> UIView? {
        timelineFirstView(ofType: DelimitedTableRenderView.self, in: view)
            ?? timelineFirstView(ofType: GeoJSONMapView.self, in: view)
            ?? timelineFirstView(ofType: NativeExpandedReadMediaView.self, in: view)
    }

    /// Lets main-actor continuations queued by a finished fetch run.
    private func settle() async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func tableConfiguration(
        csv: String = "date,route\n2026-09-01,Lake\n2026-09-02,Ship"
    ) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            expandedContent: .document(.delimitedTable(text: csv, filePath: "rides.csv")),
            copyOutputText: csv,
            toolNamePrefix: "read",
            isExpanded: true
        )
    }

    private func mapConfiguration() -> ToolTimelineRowConfiguration {
        let geoJSON = """
        {"type":"Feature","properties":{"name":"Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}
        """
        return makeTimelineToolConfiguration(
            expandedContent: .document(.geoJSON(text: geoJSON, filePath: "rainier.geojson")),
            copyOutputText: geoJSON,
            toolNamePrefix: "read",
            isExpanded: true
        )
    }

    private func readMediaConfiguration() -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: Self.svg,
                filePath: "fixtures/portrait.svg",
                startLine: 1,
                attachments: []
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
    }

    /// An SVG file whose bytes arrive only when `gate` opens.
    private func lazySVGConfiguration(gate: FetchGate) -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            expandedContent: .readMedia(
                output: "Read image file [image/svg+xml]",
                filePath: "fixtures/lazy.svg",
                startLine: 1,
                attachments: []
            ),
            toolNamePrefix: "read",
            isExpanded: true
        )
        .withSessionFileDataFetcher { _ in await gate.fetch(Data(Self.svg.utf8)) }
    }

    private func markdownConfiguration() -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "notes",
            expandedContent: .markdown(text: "# Notes\n\nBody with **bold** text."),
            toolNamePrefix: "extensions.notes",
            isExpanded: true
        )
    }

    private func collapsedConfiguration() -> ToolTimelineRowConfiguration {
        makeTimelineToolConfiguration(
            title: "read",
            toolNamePrefix: "read",
            isExpanded: false
        )
    }

    private static let point = """
    {"type":"Feature","properties":{"name":"Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}
    """

    private static let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 600\"><rect width=\"200\" height=\"600\" fill=\"red\"/></svg>"
}

/// Holds a fetch open until the test releases it.
private actor FetchGate {
    private(set) var started = 0
    private(set) var finished = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fetch(_ data: Data) async -> Data {
        started += 1
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        finished += 1
        return data
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// A hosted surface mounted in a host inside a bare scroll view, without a tool row.
@MainActor
private final class HostedSurfaceHarness {
    let scrollView: UIScrollView
    let host = ToolExpandedSurfaceHostView()
    let surface: ToolExpandedHostedSurface

    init(viewportHeight: CGFloat = 200) {
        scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: viewportHeight))
        surface = ToolExpandedHostedSurface(viewport: scrollView)
        scrollView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        ])
        surface.mount(in: host)
    }

    func activate() {
        host.activateSurfaceView(surface.container, contentInsets: .zero)
        surface.didActivate()
    }

    func layout() {
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        surface.updateWidthPriority()
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
    }
}

extension ToolExpandedHostedSurface.MediaResources {
    fileprivate static var none: ToolExpandedHostedSurface.MediaResources {
        ToolExpandedHostedSurface.MediaResources(
            audioPlayer: nil,
            sessionId: nil,
            attachmentFetcher: nil,
            attachmentMediaSourceProvider: nil,
            sessionFileDataFetcher: nil,
            sessionFileMediaSourceProvider: nil
        )
    }
}
