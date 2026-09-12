import Foundation
import MapKit

/// Decodes a viewer plan with MapKit. Empty success is treated as failure.
enum GeoJSONMapModel {
    struct Contents {
        var annotations: [MKPointAnnotation]
        var overlays: [MKOverlay]
        var failureReason: String?

        var hasDrawableGeometry: Bool {
            !annotations.isEmpty || !overlays.isEmpty
        }
    }

    static func load(_ plan: GeoJSONViewerPlan) -> Contents {
        if let failureReason = plan.failureReason {
            return Contents(annotations: [], overlays: [], failureReason: failureReason)
        }
        guard let data = plan.geoJSONData else {
            return Contents(annotations: [], overlays: [], failureReason: "Invalid JSON")
        }
        do {
            let objects = try MKGeoJSONDecoder().decode(data)
            var annotations: [MKPointAnnotation] = []
            var overlays: [MKOverlay] = []
            for object in objects {
                ingest(object, title: nil, annotations: &annotations, overlays: &overlays)
            }
            if annotations.isEmpty && overlays.isEmpty {
                return Contents(
                    annotations: [],
                    overlays: [],
                    failureReason: "No drawable geometry"
                )
            }
            return Contents(annotations: annotations, overlays: overlays, failureReason: nil)
        } catch {
            return Contents(
                annotations: [],
                overlays: [],
                failureReason: shortReason(error)
            )
        }
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

    private static func shortReason(_ error: Error) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Couldn't decode GeoJSON"
        }
        if text.count <= 80 {
            return text
        }
        return "Couldn't decode GeoJSON"
    }
}
