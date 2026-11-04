import Foundation
import Testing
import UIKit
@testable import Oppi

/// A FeatureCollection whose only geometry has no coordinates made
/// `MKGeoJSONDecoder` fail the whole document, and the chat block drew a black
/// panel with a raw `Foundation._GenericObjCError`. Members with no drawable
/// geometry are dropped before decoding, so the rest still draws and a document
/// with nothing left says so in plain words at a compact height.
@MainActor
@Suite("GeoJSON map without drawable geometry")
struct GeoJSONMapUnavailableTests {
    /// The reported document, byte for byte.
    private static let emptyLoop = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Kapiʻolani Park loop — Sat 2×6 PMP","description":"1.93 mi loop · flat · run 3 laps per 6-mi block","stroke":"#e4572e","stroke-width":4},"geometry":{"type":"LineString","coordinates":[]}}]}
    """

    private static let rainierPoint = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Mount Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}]}
    """

    private static let rainierFeature = """
    {"type":"Feature","properties":{"name":"Mount Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}
    """

    private static let emptyLineFeature = """
    {"type":"Feature","properties":{"name":"Kapiʻolani Park loop"},"geometry":{"type":"LineString","coordinates":[]}}
    """

    private static func load(_ text: String, path: String = "map.geojson") -> GeoJSONMapModel.Contents {
        GeoJSONMapModel.load(GeoJSONViewerPlan.resolved(path: path, text: text))
    }

    @Test func emptyLineStringSaysThereIsNoMapInsteadOfADecoderError() {
        let contents = Self.load(Self.emptyLoop)
        #expect(contents.failureReason == "No map to show")
        #expect(!contents.hasDrawableGeometry)
        let shown = contents.failureReason ?? ""
        #expect(!shown.contains("GenericObjCError"))
        #expect(!shown.contains("couldn't be completed"))
    }

    @Test func mixedCollectionDrawsTheFeatureThatHasCoordinates() {
        let mixed = """
        {"type":"FeatureCollection","features":[\(Self.emptyLineFeature),\(Self.rainierFeature)]}
        """
        let contents = Self.load(mixed)
        #expect(contents.failureReason == nil)
        #expect(contents.annotations.count == 1)
        #expect(contents.annotations.first?.title == "Mount Rainier")
    }

    @Test func unusableGeometriesAreSkippedAndTheRestStillDraws() {
        // A one-point line, a three-point ring, a null geometry and an empty
        // multi-polygon have nothing to draw next to a usable point.
        let mixed = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{},"geometry":{"type":"LineString","coordinates":[[-121.7,46.8]]}},
          {"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[-121.7,46.8],[-121.6,46.9],[-121.5,46.8]]]}},
          {"type":"Feature","properties":{},"geometry":null},
          {"type":"Feature","properties":{},"geometry":{"type":"MultiPolygon","coordinates":[]}},
          \(Self.rainierFeature)
        ]}
        """
        let contents = Self.load(mixed)
        #expect(contents.failureReason == nil)
        #expect(contents.annotations.count == 1)
        #expect(contents.overlays.isEmpty)
    }

    @Test func invalidDocumentSaysItCannotReadTheMapAndKeepsTheDecoderErrorOutOfTheCopy() {
        let contents = Self.load("{not json")
        #expect(contents.failureReason == "Couldn't read this map")
        let shown = contents.failureReason ?? ""
        #expect(!shown.contains("GenericObjCError"))
        #expect(!shown.contains("couldn't be completed"))
        #expect(!shown.contains("JSON"))
    }

    @Test func chatBlockShowsACompactUnavailableStateInsteadOfAMapBox() throws {
        let markdown = AssistantMarkdownContentView()
        markdown.apply(configuration: .make(
            content: "```geojson\n\(Self.emptyLoop)\n```",
            isStreaming: false,
            themeID: .dark
        ))
        let size = fittedTimelineSize(for: markdown, width: 360)
        let map = try #require(timelineFirstView(ofType: GeoJSONMapView.self, in: markdown))
        #expect(map.accessibilityLabel == "No map to show. This GeoJSON has no coordinates to draw.")
        #expect(size.height < 180, "Unavailable map block drew \(size.height) pt tall")
        #expect(size.height > 0)
    }
}
