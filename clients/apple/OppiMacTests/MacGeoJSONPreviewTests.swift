import Foundation
import Testing
@testable import Oppi

@Suite("Mac GeoJSON/TopoJSON map viewer")
struct MacGeoJSONPreviewTests {
    @Test func geojsonAndTopojsonFilesOpenAMapPlanInsteadOfPlainText() throws {
        let geojson = try #require(#"{"type":"Point","coordinates":[-121.7603,46.8523]}"#.data(using: .utf8))
        let topojson = try #require(#"{"type":"Topology","objects":{},"arcs":[]}"#.data(using: .utf8))

        guard case .file(let geoFile) = FileViewerDescriptorBuilder.descriptor(
            path: "rainier.geojson",
            data: geojson
        ) else {
            Issue.record("Expected GeoJSON to stay a file descriptor")
            return
        }
        guard case .file(let topoFile) = FileViewerDescriptorBuilder.descriptor(
            path: "arcs.topojson",
            data: topojson
        ) else {
            Issue.record("Expected TopoJSON to stay a file descriptor")
            return
        }

        #expect(geoFile.fileType == .geojson)
        #expect(topoFile.fileType == .topojson)
        #expect(MacToolDocumentColumnPaint.fileUsesGeoJSONPreview(geoFile))
        #expect(MacToolDocumentColumnPaint.fileUsesGeoJSONPreview(topoFile))
        #expect(GeoJSONViewerPlan.opening(path: "rainier.geojson", text: geoFile.text) != nil)
        #expect(GeoJSONViewerPlan.opening(path: "arcs.topojson", text: topoFile.text) != nil)
    }

    @Test func ordinaryJSONDoesNotUseTheMapPlan() throws {
        let json = try #require(#"{"name":"oppi"}"#.data(using: .utf8))
        guard case .file(let file) = FileViewerDescriptorBuilder.descriptor(
            path: "package.json",
            data: json
        ) else {
            Issue.record("Expected package.json to stay a file descriptor")
            return
        }

        #expect(!MacToolDocumentColumnPaint.fileUsesGeoJSONPreview(file))
        #expect(GeoJSONViewerPlan.opening(path: "package.json", text: file.text) == nil)
        #expect(file.fileType == .json)
    }

    @Test func failureDoesNotLeaveAVisibleWorldMap() throws {
        let plan = GeoJSONViewerPlan.resolved(path: "broken.geojson", text: "{not json")
        let contents = GeoJSONMapModel.load(plan)
        #expect(contents.failureReason == "Invalid JSON")
        #expect(contents.annotations.isEmpty)
        #expect(contents.overlays.isEmpty)
        #expect(!contents.hasDrawableGeometry)

        let preview = try source(named: "OppiMac/Views/MacGeoJSONPreview.swift")
        #expect(preview.contains("mapView.isHidden = true"))
        #expect(preview.contains("contents.failureReason"))
        #expect(preview.contains("plan.source"))
        #expect(preview.contains("Text(\"Source\")"))
        #expect(preview.contains("failureLabel"))
    }

    @Test func documentColumnExposesMapAndSourceNotASheet() throws {
        let column = try source(named: "OppiMac/Views/MacToolDocumentColumn.swift")
        let preview = try source(named: "OppiMac/Views/MacGeoJSONPreview.swift")

        #expect(column.contains("fileUsesGeoJSONPreview"))
        #expect(column.contains("MacGeoJSONPreviewView"))
        #expect(preview.contains("Text(\"Rendered\")"))
        #expect(preview.contains("Text(\"Source\")"))
        #expect(preview.contains("Picker"))
        #expect(preview.contains("plan.source"))
        #expect(preview.contains("geojson.map"))
        #expect(!preview.contains("fullScreenCover"))
        #expect(!preview.contains(".sheet("))
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
