import Foundation
import MapKit
import Testing
@testable import Oppi

@Suite("GeoJSON and TopoJSON documents")
struct GeoJSONDocumentTests {
    private let rainierPoint = """
    {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Mount Rainier"},"geometry":{"type":"Point","coordinates":[-121.7603,46.8523]}}]}
    """

    private let sharedArcTopology = """
    {
      "type": "Topology",
      "objects": {
        "pair": {
          "type": "GeometryCollection",
          "geometries": [
            {
              "type": "Polygon",
              "arcs": [[0, 1, 2]],
              "properties": {"name": "left"}
            },
            {
              "type": "Polygon",
              "arcs": [[3, -2]],
              "properties": {"name": "right"}
            }
          ]
        }
      },
      "arcs": [
        [[0, 0], [1, 0]],
        [[1, 0], [1, 1]],
        [[1, 1], [0, 1], [0, 0]],
        [[1, 0], [2, 0], [2, 1], [1, 1]]
      ]
    }
    """

    @Test func geojsonAndTopojsonExtensionsAreMapTypes() {
        #expect(FileType.detect(from: "places.geojson") == .geojson)
        #expect(FileType.detect(from: "PARK.GEOJSON") == .geojson)
        #expect(FileType.detect(from: "maps/rainier.topojson") == .topojson)
        #expect(FileType.detect(from: "arcs.TOPOJSON") == .topojson)
        #expect(FileType.geojson.displayLabel == "GeoJSON")
        #expect(FileType.topojson.displayLabel == "TopoJSON")
        #expect(FileType.geojson.previewCategory == .text)
        #expect(FileType.topojson.previewCategory == .text)
        #expect(FileType.geojson.syntaxLanguage == .json)
        #expect(FileType.topojson.syntaxLanguage == .json)
    }

    @Test func jsonSniffPromotesFeatureCollectionGeometryCollectionAndTopology() {
        #expect(
            FileType.detect(from: "places.json", content: rainierPoint) == .geojson
        )
        #expect(
            FileType.detect(
                from: "shapes.json",
                content: #"{"type":"GeometryCollection","geometries":[]}"#
            ) == .geojson
        )
        #expect(
            FileType.detect(from: "arcs.json", content: sharedArcTopology) == .topojson
        )
    }

    @Test func ordinaryJSONIsNotAMap() {
        #expect(FileType.detect(from: "package.json") == .json)
        #expect(
            FileType.detect(
                from: "package.json",
                content: #"{"name":"oppi","version":"1.0.0"}"#
            ) == .json
        )
        #expect(
            FileType.detect(
                from: "config.json",
                content: #"{"type":"module","main":"index.js"}"#
            ) == .json
        )
        #expect(
            FileType.detect(
                from: "point.json",
                content: #"{"type":"Feature","geometry":{"type":"Point","coordinates":[0,0]}}"#
            ) == .json
        )
        #expect(GeoJSONViewerPlan.opening(path: "package.json", text: #"{"name":"oppi"}"#) == nil)
        #expect(GeoJSONViewerPlan.opening(path: "notes.txt", text: rainierPoint) == nil)
    }

    @Test func invalidJSONSurfacesAFailureReasonInsteadOfABlankMap() {
        let plan = GeoJSONViewerPlan.resolved(path: "broken.geojson", text: "{not json")
        #expect(plan.kind == .geojson)
        #expect(plan.source == "{not json")
        #expect(plan.geoJSONData == nil)
        #expect(plan.failureReason == "Invalid JSON")
    }

    @Test func invalidTopologySurfacesAFailureReason() {
        let plan = GeoJSONViewerPlan.resolved(
            path: "broken.topojson",
            text: #"{"type":"FeatureCollection","features":[]}"#
        )
        #expect(plan.kind == .topojson)
        #expect(plan.geoJSONData == nil)
        #expect(plan.failureReason == "Not a TopoJSON Topology")
    }

    @Test func sharedArcPolygonConvertsToClosedGeoJSONRings() throws {
        let data = try TopoJSON.convertToGeoJSONFeatureCollection(sharedArcTopology).get()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "FeatureCollection")
        let features = try #require(root["features"] as? [[String: Any]])
        #expect(features.count == 2)

        let byName = Dictionary(uniqueKeysWithValues: features.map { feature in
            let properties = feature["properties"] as? [String: Any]
            let name = properties?["name"] as? String ?? ""
            return (name, feature)
        })

        let leftRing = try ring(named: "left", in: byName)
        let rightRing = try ring(named: "right", in: byName)
        #expect(leftRing == [
            [0, 0],
            [1, 0],
            [1, 1],
            [0, 1],
            [0, 0],
        ])
        #expect(rightRing == [
            [1, 0],
            [2, 0],
            [2, 1],
            [1, 1],
            [1, 0],
        ])
    }

    @Test func quantizedArcsAndPointsApplyTransform() throws {
        let topology = """
        {
          "type": "Topology",
          "transform": { "scale": [0.5, 0.25], "translate": [10, 20] },
          "objects": {
            "peak": {
              "type": "Point",
              "coordinates": [2, 4],
              "properties": { "name": "peak" }
            },
            "path": {
              "type": "LineString",
              "arcs": [0],
              "properties": { "name": "path" }
            }
          },
          "arcs": [[[0, 0], [2, 0], [0, 4]]]
        }
        """
        let data = try TopoJSON.convertToGeoJSONFeatureCollection(topology).get()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(root["features"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: features.map { feature in
            let properties = feature["properties"] as? [String: Any]
            let name = properties?["name"] as? String ?? ""
            return (name, feature)
        })

        let point = try #require(byName["peak"]?["geometry"] as? [String: Any])
        #expect(point["type"] as? String == "Point")
        #expect(Self.numbers(point["coordinates"]) == [11, 21])

        let line = try #require(byName["path"]?["geometry"] as? [String: Any])
        #expect(line["type"] as? String == "LineString")
        #expect(Self.numberPairs(line["coordinates"]) == [
            [10, 20],
            [11, 20],
            [11, 21],
        ])
    }

    @Test func viewerPlanConvertsTopoJSONForTheMapDecoder() throws {
        let plan = try #require(
            GeoJSONViewerPlan.opening(path: "pair.topojson", text: sharedArcTopology)
        )
        #expect(plan.kind == .topojson)
        #expect(plan.failureReason == nil)
        let data = try #require(plan.geoJSONData)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["type"] as? String == "FeatureCollection")
    }

    @Test func topologyWithSphereAndLandConvertsLandOnly() throws {
        let topology = """
        {
          "type": "Topology",
          "objects": {
            "land": {
              "type": "Polygon",
              "arcs": [[0]],
              "properties": {"name": "land"}
            },
            "sphere": {
              "type": "Sphere"
            }
          },
          "arcs": [
            [[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]]
          ]
        }
        """
        let data = try TopoJSON.convertToGeoJSONFeatureCollection(topology).get()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(root["features"] as? [[String: Any]])
        #expect(features.count == 1)
        let properties = features[0]["properties"] as? [String: Any]
        #expect(properties?["name"] as? String == "land")
        let landRing = try ring(named: "land", in: ["land": features[0]])
        #expect(landRing == [
            [0, 0],
            [2, 0],
            [2, 2],
            [0, 2],
            [0, 0],
        ])
    }

    @Test func topologySkipsNullGeometryAndKeepsDrawableMembers() throws {
        let topology = """
        {
          "type": "Topology",
          "objects": {
            "group": {
              "type": "GeometryCollection",
              "geometries": [
                { "type": null },
                {
                  "type": "Point",
                  "coordinates": [10, 20],
                  "properties": {"name": "kept"}
                }
              ]
            }
          },
          "arcs": []
        }
        """
        let data = try TopoJSON.convertToGeoJSONFeatureCollection(topology).get()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(root["features"] as? [[String: Any]])
        #expect(features.count == 1)
        let point = try #require(features[0]["geometry"] as? [String: Any])
        #expect(point["type"] as? String == "Point")
        #expect(Self.numbers(point["coordinates"]) == [10, 20])
    }

    @Test func topologyPolygonHoleKeepsExteriorAndInteriorRings() throws {
        let topology = """
        {
          "type": "Topology",
          "objects": {
            "donut": {
              "type": "Polygon",
              "arcs": [[0], [1]],
              "properties": {"name": "donut"}
            }
          },
          "arcs": [
            [[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]],
            [[1, 1], [1, 3], [3, 3], [3, 1], [1, 1]]
          ]
        }
        """
        let data = try TopoJSON.convertToGeoJSONFeatureCollection(topology).get()
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let features = try #require(root["features"] as? [[String: Any]])
        let geometry = try #require(features.first?["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "Polygon")
        let rings = try #require(geometry["coordinates"] as? [Any])
        #expect(rings.count == 2)
        #expect(Self.numberPairs(rings[0]) == [
            [0, 0],
            [4, 0],
            [4, 4],
            [0, 4],
            [0, 0],
        ])
        #expect(Self.numberPairs(rings[1]) == [
            [1, 1],
            [1, 3],
            [3, 3],
            [3, 1],
            [1, 1],
        ])

        let geoJSON = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{},"geometry":{"type":"Polygon","coordinates":[[[0,0],[4,0],[4,4],[0,4],[0,0]],[[1,1],[1,3],[3,3],[3,1],[1,1]]]}}]}
        """
        let loaded = GeoJSONMapModel.load(
            GeoJSONViewerPlan.resolved(path: "donut.geojson", text: geoJSON)
        )
        #expect(loaded.failureReason == nil)
        let polygon = try #require(loaded.overlays.first as? MKPolygon)
        #expect(polygon.interiorPolygons?.count == 1)
    }

    @Test func sphereOnlyTopologyHasNoDrawableGeometry() {
        let topology = """
        {"type":"Topology","objects":{"sphere":{"type":"Sphere"}},"arcs":[]}
        """
        let loaded = GeoJSONMapModel.load(
            GeoJSONViewerPlan.resolved(path: "sphere.topojson", text: topology)
        )
        #expect(loaded.annotations.isEmpty)
        #expect(loaded.overlays.isEmpty)
        #expect(loaded.failureReason == "No drawable geometry")
    }

    @Test func mapDecoderLoadsAPointAndRejectsEmptyGeometry() {
        let loaded = GeoJSONMapModel.load(
            GeoJSONViewerPlan.resolved(path: "rainier.geojson", text: rainierPoint)
        )
        #expect(loaded.failureReason == nil)
        #expect(loaded.annotations.count == 1)
        #expect(abs((loaded.annotations.first?.coordinate.longitude ?? 0) - (-121.7603)) < 0.0001)
        #expect(abs((loaded.annotations.first?.coordinate.latitude ?? 0) - 46.8523) < 0.0001)

        let empty = GeoJSONMapModel.load(
            GeoJSONViewerPlan.resolved(
                path: "empty.geojson",
                text: #"{"type":"FeatureCollection","features":[]}"#
            )
        )
        #expect(empty.annotations.isEmpty)
        #expect(empty.overlays.isEmpty)
        #expect(empty.failureReason == "No drawable geometry")
    }

    @Test func fullScreenContentRoutesMapFiles() {
        let geo = FullScreenCodeContent.fromText(rainierPoint, filePath: "rainier.geojson")
        let topo = FullScreenCodeContent.fromText(sharedArcTopology, filePath: "pair.topojson")
        let json = FullScreenCodeContent.fromText(#"{"name":"oppi"}"#, filePath: "package.json")

        guard case .geoJSON(let geoText, let geoPath) = geo else {
            Issue.record("GeoJSON still has no map plan, got \(geo)")
            return
        }
        guard case .geoJSON(let topoText, let topoPath) = topo else {
            Issue.record("TopoJSON still has no map plan, got \(topo)")
            return
        }
        #expect(geoText == rainierPoint)
        #expect(geoPath == "rainier.geojson")
        #expect(topoText == sharedArcTopology)
        #expect(topoPath == "pair.topojson")
        guard case .code(_, let language, _, _) = json else {
            Issue.record("package.json should stay a JSON code viewer, got \(json)")
            return
        }
        #expect(language == "json")
    }

    private func ring(named name: String, in features: [String: [String: Any]]) throws -> [[Double]] {
        let feature = try #require(features[name])
        let geometry = try #require(feature["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "Polygon")
        let rings = try #require(geometry["coordinates"] as? [Any])
        #expect(rings.count == 1)
        return try #require(Self.numberPairs(rings.first))
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        guard let values = value as? [Any] else { return nil }
        return values.map { ($0 as? NSNumber)?.doubleValue ?? Double.nan }
    }

    private static func numberPairs(_ value: Any?) -> [[Double]]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap(numbers)
    }
}
