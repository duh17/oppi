import Foundation

/// Routes GeoJSON/TopoJSON into the map/source document viewer without rewriting bytes.
struct GeoJSONViewerPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case geojson
        case topojson

        var fileType: FileType {
            switch self {
            case .geojson: .geojson
            case .topojson: .topojson
            }
        }

        init?(path: String, content: String? = nil) {
            switch FileType.detect(from: path, content: content) {
            case .geojson: self = .geojson
            case .topojson: self = .topojson
            default: return nil
            }
        }

        init?(fileType: FileType) {
            switch fileType {
            case .geojson: self = .geojson
            case .topojson: self = .topojson
            default: return nil
            }
        }
    }

    let kind: Kind
    let source: String
    /// FeatureCollection / GeoJSON bytes for `MKGeoJSONDecoder`. Nil on failure.
    let geoJSONData: Data?
    let failureReason: String?

    static func opening(
        path: String,
        text: String
    ) -> GeoJSONViewerPlan? {
        guard let kind = Kind(path: path, content: text) else { return nil }
        return make(kind: kind, text: text)
    }

    static func opening(
        fileType: FileType,
        path: String?,
        text: String
    ) -> GeoJSONViewerPlan? {
        if let path, let plan = opening(path: path, text: text) {
            return plan
        }
        guard let kind = Kind(fileType: fileType) else { return nil }
        return make(kind: kind, text: text)
    }

    static func resolved(path: String?, text: String) -> GeoJSONViewerPlan {
        if let plan = opening(
            fileType: FileType.detect(from: path, content: text),
            path: path,
            text: text
        ) {
            return plan
        }
        let ext = (path as NSString?)?.pathExtension.lowercased()
        let kind: Kind = ext == "topojson" ? .topojson : .geojson
        return make(kind: kind, text: text)
    }

    private static func make(kind: Kind, text: String) -> GeoJSONViewerPlan {
        switch kind {
        case .geojson:
            guard let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return GeoJSONViewerPlan(
                    kind: kind,
                    source: text,
                    geoJSONData: nil,
                    failureReason: "Invalid JSON"
                )
            }
            return GeoJSONViewerPlan(
                kind: kind,
                source: text,
                geoJSONData: data,
                failureReason: nil
            )
        case .topojson:
            switch TopoJSON.convertToGeoJSONFeatureCollection(text) {
            case .success(let data):
                return GeoJSONViewerPlan(
                    kind: kind,
                    source: text,
                    geoJSONData: data,
                    failureReason: nil
                )
            case .failure(let error):
                return GeoJSONViewerPlan(
                    kind: kind,
                    source: text,
                    geoJSONData: nil,
                    failureReason: error.reason
                )
            }
        }
    }
}

enum GeographicJSONSniffer {
    /// GitHub-like sniff for `.json` files. Feature/Point roots stay ordinary JSON.
    static func fileType(from content: String?) -> FileType? {
        guard let content else { return nil }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "FeatureCollection", "GeometryCollection":
            return .geojson
        case "Topology":
            return .topojson
        default:
            return nil
        }
    }
}

/// TopoJSON → GeoJSON FeatureCollection. No extra package; RFC-style arcs + transform.
enum TopoJSON {
    enum ConversionError: Error, Equatable, Sendable {
        case invalidJSON
        case notTopology
        case invalidArcs
        case invalidTransform
        case unsupportedGeometry(String)

        var reason: String {
            switch self {
            case .invalidJSON:
                return "Invalid JSON"
            case .notTopology:
                return "Not a TopoJSON Topology"
            case .invalidArcs:
                return "Invalid TopoJSON arcs"
            case .invalidTransform:
                return "Invalid TopoJSON transform"
            case .unsupportedGeometry(let type):
                return "Unsupported geometry: \(type)"
            }
        }
    }

    private struct Transform {
        let scaleX: Double
        let scaleY: Double
        let translateX: Double
        let translateY: Double
    }

    static func convertToGeoJSONFeatureCollection(_ text: String) -> Result<Data, ConversionError> {
        guard let data = text.data(using: .utf8) else {
            return .failure(.invalidJSON)
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(.invalidJSON)
        }
        guard let topology = root as? [String: Any],
              topology["type"] as? String == "Topology" else {
            return .failure(.notTopology)
        }
        do {
            let transform = try parseTransform(topology["transform"])
            let arcs = try parseArcs(topology["arcs"], transform: transform)
            let objects = topology["objects"] as? [String: Any] ?? [:]
            var features: [Any] = []
            for key in objects.keys.sorted() {
                guard let object = objects[key] else { continue }
                features.append(contentsOf: try makeFeatures(from: object, arcs: arcs, transform: transform))
            }
            let collection: [String: Any] = [
                "type": "FeatureCollection",
                "features": features,
            ]
            let encoded = try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys])
            return .success(encoded)
        } catch let error as ConversionError {
            return .failure(error)
        } catch {
            return .failure(.invalidJSON)
        }
    }

    private static func parseTransform(_ value: Any?) throws -> Transform? {
        guard let value else { return nil }
        guard let object = value as? [String: Any],
              let scale = numberPair(object["scale"]),
              let translate = numberPair(object["translate"]) else {
            throw ConversionError.invalidTransform
        }
        return Transform(
            scaleX: scale.0,
            scaleY: scale.1,
            translateX: translate.0,
            translateY: translate.1
        )
    }

    private static func parseArcs(_ value: Any?, transform: Transform?) throws -> [[[Double]]] {
        guard let value else { return [] }
        guard let rawArcs = value as? [Any] else {
            throw ConversionError.invalidArcs
        }
        return try rawArcs.map { arc in
            try decodeArc(arc, transform: transform)
        }
    }

    /// Delta-decode when a transform is present; otherwise positions are absolute.
    private static func decodeArc(_ value: Any, transform: Transform?) throws -> [[Double]] {
        guard let positions = value as? [Any] else {
            throw ConversionError.invalidArcs
        }
        if let transform {
            var x = 0.0
            var y = 0.0
            return try positions.map { position in
                let pair = try requirePair(position)
                x += pair.0
                y += pair.1
                return [
                    x * transform.scaleX + transform.translateX,
                    y * transform.scaleY + transform.translateY,
                ]
            }
        }
        return try positions.map { position in
            let pair = try requirePair(position)
            return [pair.0, pair.1]
        }
    }

    private static func makeFeatures(
        from object: Any,
        arcs: [[[Double]]],
        transform: Transform?
    ) throws -> [[String: Any]] {
        if object is NSNull {
            return []
        }
        guard let geometry = object as? [String: Any] else {
            throw ConversionError.unsupportedGeometry("missing")
        }
        if shouldSkipGeometry(geometry) {
            return []
        }
        guard let type = geometry["type"] as? String else {
            throw ConversionError.unsupportedGeometry("missing")
        }
        if type == "GeometryCollection" {
            let geometries = geometry["geometries"] as? [Any] ?? []
            var result: [[String: Any]] = []
            for child in geometries {
                result.append(contentsOf: try makeFeatures(from: child, arcs: arcs, transform: transform))
            }
            return result
        }
        let geoJSONGeometry = try geoJSONGeometry(
            from: geometry,
            type: type,
            arcs: arcs,
            transform: transform
        )
        var feature: [String: Any] = [
            "type": "Feature",
            "geometry": geoJSONGeometry,
            "properties": geometry["properties"] as? [String: Any] ?? [:],
        ]
        if let id = geometry["id"] {
            feature["id"] = id
        }
        return [feature]
    }

    private static func geoJSONGeometry(
        from object: [String: Any],
        type: String,
        arcs: [[[Double]]],
        transform: Transform?
    ) throws -> [String: Any] {
        switch type {
        case "Point":
            let coordinates = try decodePoint(object["coordinates"], transform: transform)
            return ["type": "Point", "coordinates": coordinates]
        case "MultiPoint":
            guard let values = object["coordinates"] as? [Any] else {
                throw ConversionError.unsupportedGeometry(type)
            }
            let coordinates = try values.map { try decodePoint($0, transform: transform) }
            return ["type": "MultiPoint", "coordinates": coordinates]
        case "LineString":
            let indexes = try arcIndexes(object["arcs"])
            return [
                "type": "LineString",
                "coordinates": try stitchLine(indexes, arcs: arcs),
            ]
        case "MultiLineString":
            let lines = try arcIndexLines(object["arcs"])
            return [
                "type": "MultiLineString",
                "coordinates": try lines.map { try stitchLine($0, arcs: arcs) },
            ]
        case "Polygon":
            let rings = try arcIndexLines(object["arcs"])
            return [
                "type": "Polygon",
                "coordinates": try rings.map { try closedRing(stitchLine($0, arcs: arcs)) },
            ]
        case "MultiPolygon":
            guard let polygons = object["arcs"] as? [Any] else {
                throw ConversionError.unsupportedGeometry(type)
            }
            let coordinates = try polygons.map { polygon -> [[[Double]]] in
                let rings = try arcIndexLines(polygon)
                return try rings.map { try closedRing(stitchLine($0, arcs: arcs)) }
            }
            return ["type": "MultiPolygon", "coordinates": coordinates]
        default:
            throw ConversionError.unsupportedGeometry(type)
        }
    }

    /// World-atlas Topology objects include `Sphere`; collections may store `type: null`.
    /// Skip those members so remaining drawable geometry still converts.
    private static func shouldSkipGeometry(_ geometry: [String: Any]) -> Bool {
        let rawType = geometry["type"]
        if rawType == nil || rawType is NSNull {
            return true
        }
        if let type = rawType as? String, type == "Sphere" {
            return true
        }
        return false
    }

    private static func decodePoint(_ value: Any?, transform: Transform?) throws -> [Double] {
        let pair = try requirePair(value)
        guard let transform else {
            return [pair.0, pair.1]
        }
        return [
            pair.0 * transform.scaleX + transform.translateX,
            pair.1 * transform.scaleY + transform.translateY,
        ]
    }

    private static func stitchLine(_ indexes: [Int], arcs: [[[Double]]]) throws -> [[Double]] {
        var line: [[Double]] = []
        for (offset, index) in indexes.enumerated() {
            var positions = try positions(forArcIndex: index, arcs: arcs)
            if offset > 0, !positions.isEmpty {
                positions.removeFirst()
            }
            line.append(contentsOf: positions)
        }
        return line
    }

    private static func positions(forArcIndex index: Int, arcs: [[[Double]]]) throws -> [[Double]] {
        let reversed = index < 0
        let arcIndex = reversed ? ~index : index
        guard arcs.indices.contains(arcIndex) else {
            throw ConversionError.invalidArcs
        }
        var positions = arcs[arcIndex]
        if reversed {
            positions.reverse()
        }
        return positions
    }

    private static func closedRing(_ line: [[Double]]) -> [[Double]] {
        guard let first = line.first, let last = line.last else { return line }
        if first == last {
            return line
        }
        var closed = line
        closed.append(first)
        return closed
    }

    private static func arcIndexes(_ value: Any?) throws -> [Int] {
        guard let values = value as? [Any] else {
            throw ConversionError.invalidArcs
        }
        return try values.map(intValue)
    }

    private static func arcIndexLines(_ value: Any?) throws -> [[Int]] {
        guard let values = value as? [Any] else {
            throw ConversionError.invalidArcs
        }
        return try values.map(arcIndexes)
    }

    private static func intValue(_ value: Any) throws -> Int {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        throw ConversionError.invalidArcs
    }

    private static func requirePair(_ value: Any?) throws -> (Double, Double) {
        guard let pair = numberPair(value) else {
            throw ConversionError.invalidArcs
        }
        return pair
    }

    private static func numberPair(_ value: Any?) -> (Double, Double)? {
        guard let values = value as? [Any], values.count >= 2 else { return nil }
        guard let x = doubleValue(values[0]), let y = doubleValue(values[1]) else { return nil }
        return (x, y)
    }

    private static func doubleValue(_ value: Any) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}
