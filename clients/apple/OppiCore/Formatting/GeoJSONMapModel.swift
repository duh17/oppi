import Foundation
import MapKit
import OSLog

private let geoJSONLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "GeoJSON")

/// Decodes a viewer plan with MapKit.
///
/// `MKGeoJSONDecoder` fails the whole document when one member has no usable
/// coordinates: an empty `LineString` throws `Foundation._GenericObjCError` and
/// the caller gets no map at all. Members with nothing to draw are therefore
/// dropped before MapKit sees the bytes, so the rest of a collection still
/// draws, and a document with nothing left says so in plain words.
enum GeoJSONMapModel {
    /// Why a map has nothing to draw. The copy lives here so every surface that
    /// shows a plan (chat block, tool row, reader, Mac preview) says the same
    /// thing; a decoder error is only ever logged, never shown.
    enum Failure: Equatable, Sendable {
        /// The document parsed, but no feature kept any coordinates.
        case noCoordinates
        /// The document did not decode as GeoJSON at all.
        case invalidDocument

        var title: String {
            switch self {
            case .noCoordinates:
                String(localized: "No map to show")
            case .invalidDocument:
                String(localized: "Couldn't read this map")
            }
        }

        var detail: String {
            switch self {
            case .noCoordinates:
                String(localized: "This GeoJSON has no coordinates to draw.")
            case .invalidDocument:
                String(localized: "The GeoJSON is not valid.")
            }
        }
    }

    struct Contents {
        var annotations: [MKPointAnnotation]
        var overlays: [MKOverlay]
        /// Set when nothing could be drawn. Never carries a decoder message.
        var failure: Failure?

        var hasDrawableGeometry: Bool {
            !annotations.isEmpty || !overlays.isEmpty
        }

        /// The one-line form, for a surface that shows the state as a sentence
        /// instead of a title and detail.
        var failureReason: String? {
            failure?.title
        }
    }

    static func load(_ plan: GeoJSONViewerPlan) -> Contents {
        guard plan.failureReason == nil, let data = plan.geoJSONData else {
            return failure(.invalidDocument)
        }
        guard let drawableData = GeoJSONGeometryFilter.drawableData(from: data) else {
            return failure(.noCoordinates)
        }
        do {
            let objects = try MKGeoJSONDecoder().decode(drawableData)
            var annotations: [MKPointAnnotation] = []
            var overlays: [MKOverlay] = []
            for object in objects {
                ingest(object, title: nil, annotations: &annotations, overlays: &overlays)
            }
            guard !annotations.isEmpty || !overlays.isEmpty else {
                return failure(.noCoordinates)
            }
            return Contents(annotations: annotations, overlays: overlays, failure: nil)
        } catch {
            // Foundation's decode errors ("The operation couldn't be completed.
            // (Foundation._GenericObjCError error 0.)") tell a person nothing,
            // so they stay in the log.
            geoJSONLogger.error("GeoJSON decode failed: \(String(describing: error), privacy: .public)")
            return failure(.invalidDocument)
        }
    }

    private static func failure(_ failure: Failure) -> Contents {
        Contents(annotations: [], overlays: [], failure: failure)
    }

    private static func ingest(
        _ object: MKGeoJSONObject,
        title: String?,
        annotations: inout [MKPointAnnotation],
        overlays: inout [MKOverlay]
    ) {
        if let feature = object as? MKGeoJSONFeature {
            let featureTitle = propertyTitle(from: feature.properties) ?? title
            for geometry in feature.geometry {
                ingest(geometry, title: featureTitle, annotations: &annotations, overlays: &overlays)
            }
            return
        }
        if let shape = object as? MKShape {
            ingestShape(shape, title: title, annotations: &annotations, overlays: &overlays)
        }
    }

    private static func ingestShape(
        _ shape: MKShape,
        title: String?,
        annotations: inout [MKPointAnnotation],
        overlays: inout [MKOverlay]
    ) {
        if let title {
            shape.title = title
        }
        if let point = shape as? MKPointAnnotation {
            annotations.append(point)
            return
        }
        if let overlay = shape as? MKOverlay {
            overlays.append(overlay)
        }
    }

    private static func propertyTitle(from properties: Data?) -> String? {
        guard let properties,
              let object = try? JSONSerialization.jsonObject(with: properties) as? [String: Any] else {
            return nil
        }
        for key in ["name", "title", "NAME", "Title"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

/// Removes the members of a GeoJSON document that have no coordinates to draw.
///
/// A `LineString` needs two positions, a polygon ring needs four, and a null or
/// missing geometry draws nothing. MapKit rejects the whole document over any of
/// them, so they are filtered out here; anything this filter does not understand
/// is left alone for `MKGeoJSONDecoder` to accept or reject.
private enum GeoJSONGeometryFilter {
    /// A node to decode: the value itself, and whether anything was dropped.
    private struct Node {
        let value: Any
        let dropped: Bool

        static func unchanged(_ value: Any) -> Self {
            Self(value: value, dropped: false)
        }
    }

    /// The document without its undrawable members, or nil when nothing
    /// drawable is left. Bytes this filter did not change are returned as they
    /// came in, so MapKit decodes exactly what the document said.
    static func drawableData(from data: Data) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return data
        }
        guard let sanitized = drawable(root) else { return nil }
        guard sanitized.dropped,
              let encoded = try? JSONSerialization.data(withJSONObject: sanitized.value) else {
            return data
        }
        return encoded
    }

    /// The drawable part of one GeoJSON node, or nil when it draws nothing.
    private static func drawable(_ node: Any) -> Node? {
        guard var object = node as? [String: Any] else { return .unchanged(node) }
        guard let type = object["type"] as? String else { return .unchanged(node) }

        switch type {
        case "FeatureCollection":
            guard let features = object["features"] as? [Any] else { return .unchanged(node) }
            let members = drawableMembers(features)
            guard !members.kept.isEmpty else { return nil }
            object["features"] = members.kept
            return Node(value: object, dropped: members.dropped)

        case "Feature":
            guard let geometry = object["geometry"], !(geometry is NSNull),
                  let sanitized = drawable(geometry) else { return nil }
            object["geometry"] = sanitized.value
            return Node(value: object, dropped: sanitized.dropped)

        case "GeometryCollection":
            guard let geometries = object["geometries"] as? [Any] else { return .unchanged(node) }
            let members = drawableMembers(geometries)
            guard !members.kept.isEmpty else { return nil }
            object["geometries"] = members.kept
            return Node(value: object, dropped: members.dropped)

        case "Point":
            guard isPosition(object["coordinates"]) else { return nil }
            return .unchanged(node)

        case "MultiPoint":
            guard let points = object["coordinates"] as? [Any] else { return .unchanged(node) }
            let kept = points.filter { isPosition($0) }
            guard !kept.isEmpty else { return nil }
            guard kept.count != points.count else { return .unchanged(node) }
            object["coordinates"] = kept
            return Node(value: object, dropped: true)

        case "LineString":
            guard line(object["coordinates"]) != nil else { return nil }
            return .unchanged(node)

        case "MultiLineString":
            guard let lines = object["coordinates"] as? [Any] else { return .unchanged(node) }
            let kept = lines.filter { line($0) != nil }
            guard !kept.isEmpty else { return nil }
            guard kept.count != lines.count else { return .unchanged(node) }
            object["coordinates"] = kept
            return Node(value: object, dropped: true)

        case "Polygon":
            guard let rings = object["coordinates"] as? [Any], let kept = drawableRings(rings) else {
                return nil
            }
            guard kept.count != rings.count else { return .unchanged(node) }
            object["coordinates"] = kept
            return Node(value: object, dropped: true)

        case "MultiPolygon":
            guard let polygons = object["coordinates"] as? [Any] else { return .unchanged(node) }
            var kept: [Any] = []
            var dropped = false
            for polygon in polygons {
                guard let rings = polygon as? [Any], let polygonRings = drawableRings(rings) else {
                    dropped = true
                    continue
                }
                if polygonRings.count == rings.count {
                    kept.append(polygon)
                } else {
                    dropped = true
                    kept.append(polygonRings)
                }
            }
            guard !kept.isEmpty else { return nil }
            guard dropped else { return .unchanged(node) }
            object["coordinates"] = kept
            return Node(value: object, dropped: true)

        default:
            // A geometry this filter does not know: leave it to the decoder.
            return .unchanged(node)
        }
    }

    private static func drawableMembers(_ nodes: [Any]) -> (kept: [Any], dropped: Bool) {
        var kept: [Any] = []
        kept.reserveCapacity(nodes.count)
        var dropped = false
        for node in nodes {
            guard let sanitized = drawable(node) else {
                dropped = true
                continue
            }
            kept.append(sanitized.value)
            dropped = dropped || sanitized.dropped
        }
        return (kept, dropped)
    }

    /// A GeoJSON position: two or more finite numbers.
    private static func isPosition(_ value: Any?) -> Bool {
        guard let values = value as? [Any], values.count >= 2 else { return false }
        for value in values {
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return false }
        }
        return true
    }

    /// A line: at least two positions, each one usable.
    private static func line(_ value: Any?) -> [Any]? {
        guard let positions = value as? [Any], positions.count >= 2 else { return nil }
        guard positions.allSatisfy(isPosition) else { return nil }
        return positions
    }

    /// A ring is a closed line of at least four positions. A polygon keeps its
    /// exterior ring and drops the holes that cannot be drawn.
    private static func drawableRings(_ rings: [Any]) -> [Any]? {
        guard let exterior = rings.first, let exteriorLine = line(exterior),
              exteriorLine.count >= 4 else {
            return nil
        }
        return rings.filter { (line($0)?.count ?? 0) >= 4 }
    }
}
