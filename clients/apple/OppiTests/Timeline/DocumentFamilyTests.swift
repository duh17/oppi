import Testing
import UIKit
@testable import Oppi

/// Behavior of the CSV/TSV and GeoJSON/TopoJSON document families through the
/// one factory: classification, the full-screen source toggle, export, and inline
/// view reuse. Per-kind parsing and rendering have their own suites.
@MainActor
@Suite("DocumentFamily")
struct DocumentFamilyTests {
    private static let csv = "date,route\n2026-09-01,Lake\n"
    private static let point = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Mount Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}]}
    """

    @Test func onlyDocumentFileTypesClassifyAsFamilies() {
        #expect(DocumentFamily(fileType: .csv, text: "a", filePath: "a.csv") == .delimitedTable(text: "a", filePath: "a.csv"))
        #expect(DocumentFamily(fileType: .tsv, text: "a", filePath: "a.tsv") == .delimitedTable(text: "a", filePath: "a.tsv"))
        #expect(DocumentFamily(fileType: .geojson, text: "{}", filePath: nil) == .geoJSON(text: "{}", filePath: nil))
        #expect(DocumentFamily(fileType: .topojson, text: "{}", filePath: "t.topojson") == .geoJSON(text: "{}", filePath: "t.topojson"))
        #expect(DocumentFamily(fileType: .json, text: "{}", filePath: "a.json") == nil)
        #expect(DocumentFamily(fileType: .markdown, text: "#", filePath: "a.md") == nil)
        #expect(DocumentFamily(fileType: .plain, text: "a,b", filePath: "a.txt") == nil)
    }

    // MARK: - Full-screen reader

    @Test func tableReaderTogglesBetweenTableAndPlainSource() throws {
        let family = DocumentFamily.delimitedTable(text: Self.csv, filePath: "rides.csv")
        let controller = makeController(family)

        #expect(controller.installedBodyViewForTesting is DelimitedTableRenderView)
        #expect(controller.installedBodyViewForTesting?.accessibilityIdentifier == "full-screen.delimited-table.body")
        #expect(controller.presentationCopyTextForTesting == Self.csv)

        controller.toggleSourceForTesting()
        controller.view.layoutIfNeeded()
        guard case .plainText(let source, let path) = controller.presentationBodyContentForTesting else {
            Issue.record("Source mode should show the table text as plain text")
            return
        }
        #expect(source == Self.csv)
        #expect(path == "rides.csv")
        #expect(!(controller.installedBodyViewForTesting is DelimitedTableRenderView))

        controller.toggleSourceForTesting()
        controller.view.layoutIfNeeded()
        #expect(controller.installedBodyViewForTesting is DelimitedTableRenderView)
    }

    @Test func mapReaderTogglesBetweenMapAndJSONSource() throws {
        let family = DocumentFamily.geoJSON(text: Self.point, filePath: "rainier.geojson")
        let controller = makeController(family)

        #expect(controller.installedBodyViewForTesting is GeoJSONMapView)
        #expect(controller.installedBodyViewForTesting?.accessibilityIdentifier == "full-screen.geojson.body")

        controller.toggleSourceForTesting()
        controller.view.layoutIfNeeded()
        guard case .code(let source, let language, let path, _) = controller.presentationBodyContentForTesting else {
            Issue.record("Source mode should show the map text as JSON code")
            return
        }
        #expect(source == Self.point)
        #expect(language == "json")
        #expect(path == "rainier.geojson")
        #expect(!(controller.installedBodyViewForTesting is GeoJSONMapView))

        controller.toggleSourceForTesting()
        controller.view.layoutIfNeeded()
        #expect(controller.installedBodyViewForTesting is GeoJSONMapView)
    }

    @Test func toggleTitlesNameTheRenderedSide() {
        let table = DocumentFamily.delimitedTable(text: Self.csv, filePath: nil)
        let map = DocumentFamily.geoJSON(text: Self.point, filePath: nil)
        #expect(table.sourceToggleTitle(showingSource: false) == String(localized: "Source"))
        #expect(table.sourceToggleTitle(showingSource: true) == String(localized: "Table"))
        #expect(map.sourceToggleTitle(showingSource: false) == String(localized: "Source"))
        #expect(map.sourceToggleTitle(showingSource: true) == String(localized: "Rendered"))
    }

    // MARK: - Export

    @Test func readerExportsTableAsPlainTextAndMapAsJSON() throws {
        let table = makeController(.delimitedTable(text: Self.csv, filePath: "rides.csv"))
        guard case .plainText(let csvText, let csvName)? = table.shareableContentForTesting else {
            Issue.record("A table should export as plain text")
            return
        }
        #expect(csvText == Self.csv)
        #expect(csvName == "rides.csv")

        let map = makeController(.geoJSON(text: Self.point, filePath: "rainier.geojson"))
        guard case .json(let mapText, let mapName)? = map.shareableContentForTesting else {
            Issue.record("A map should export as JSON")
            return
        }
        #expect(mapText == Self.point)
        #expect(mapName == "rainier.geojson")
    }

    @Test func fileExportMatchesTheReaderKindAndUsesTheFileName() throws {
        guard case .plainText(_, let csvName) = FileShareService.ShareableContent.fromText(Self.csv, filePath: "exports/rides.csv") else {
            Issue.record("CSV files should share as plain text")
            return
        }
        #expect(csvName == "rides.csv")

        for path in ["exports/park.geojson", "exports/pair.topojson"] {
            guard case .json(_, let name) = FileShareService.ShareableContent.fromText(Self.point, filePath: path) else {
                Issue.record("\(path) should share as JSON")
                continue
            }
            #expect(name == (path as NSString).lastPathComponent)
        }
    }

    // MARK: - Tool row

    @Test func toolRowMountsEachFamilyInTheRowViewportWithTheRowScrollViewOff() throws {
        let csv = "date,route\n2026-09-01,Lake\n2026-09-02,Ship\n"
        let rows: [(family: DocumentFamily, mounted: (UIView) -> UIView?)] = [
            (.delimitedTable(text: csv, filePath: "rides.csv"), { timelineFirstView(ofType: DelimitedTableRenderView.self, in: $0) }),
            (.geoJSON(text: Self.point, filePath: "rainier.geojson"), { timelineFirstView(ofType: GeoJSONMapView.self, in: $0) }),
        ]
        for item in rows {
            let row = ToolTimelineRowContentView(configuration: makeTimelineToolConfiguration(
                expandedContent: .document(item.family),
                copyOutputText: item.family.text,
                toolNamePrefix: "read",
                isExpanded: true,
                isDone: true
            ))
            _ = fittedTimelineSize(for: row, width: 360)

            let viewport = try #require(expandedViewportConstraint(in: row))
            #expect(viewport.isActive, "\(item.family.kindName) needs an active viewport pin")
            #expect(viewport.priority == .required)
            #expect(item.mounted(row) != nil, "\(item.family.kindName) should mount its view")
            #expect(!row.expandedScrollView.isScrollEnabled, "\(item.family.kindName) scrolls itself; the row's scroll view stays off")
            #expect(row.expandedTapCopyGestureEnabledForTesting, "\(item.family.kindName) keeps tap interception for full-screen activation")
        }
    }

    private func expandedViewportConstraint(in row: ToolTimelineRowContentView) -> NSLayoutConstraint? {
        Mirror(reflecting: row).children.first { $0.label == "expandedViewportHeightConstraint" }?.value as? NSLayoutConstraint
    }

    private func makeController(_ family: DocumentFamily) -> FullScreenCodeViewController {
        let controller = FullScreenCodeViewController(content: .document(family))
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }
}
