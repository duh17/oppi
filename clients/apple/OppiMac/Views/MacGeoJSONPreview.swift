import AppKit
import MapKit
import SwiftUI

/// Map + source for GeoJSON/TopoJSON files. Not a sheet. Document column stays the reading surface.
struct MacGeoJSONPreviewView: View {
    private enum Mode: String, Hashable {
        case rendered
        case source
    }

    let plan: GeoJSONViewerPlan
    var fillsColumn: Bool = false
    var filePath: String? = nil

    @State private var mode: Mode = .rendered
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: fillsColumn ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(containerAccessibilityIdentifier)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label(plan.kind.fileType.displayLabel, systemImage: "map")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(theme.text.secondary)
            Spacer(minLength: 8)
            Picker("Display", selection: $mode) {
                Text("Rendered").tag(Mode.rendered)
                Text("Source").tag(Mode.source)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier(modeAccessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var content: some View {
        if mode == .rendered {
            renderedMapOrFailure
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(plan.source.isEmpty ? " " : plan.source)
                    .font(Font(FontPreferenceStore.macCodeFont()))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityLabel(filePath ?? plan.kind.fileType.displayLabel)
            }
            .frame(maxHeight: fillsColumn ? .infinity : 400)
        }
    }

    @ViewBuilder
    private var renderedMapOrFailure: some View {
        if let reason = GeoJSONMapModel.load(plan).failureReason {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: fillsColumn ? 240 : 180)
                .frame(maxHeight: fillsColumn ? .infinity : 400)
                .accessibilityIdentifier("geojson.map")
                .accessibilityLabel(reason)
        } else {
            MacGeoJSONMapRepresentable(plan: plan)
                .frame(maxWidth: .infinity, minHeight: fillsColumn ? 240 : 180)
                .frame(maxHeight: fillsColumn ? .infinity : 400)
                .accessibilityIdentifier("geojson.map")
        }
    }

    private var containerAccessibilityIdentifier: String {
        fillsColumn ? "mac.documentColumn.geojson" : "mac.timeline.geojson"
    }

    private var modeAccessibilityIdentifier: String {
        fillsColumn ? "mac.documentColumn.geojson.mode" : "mac.timeline.geojson.mode"
    }
}

private final class MacGeoJSONMapHostView: NSView {
    let mapView = MKMapView(frame: .zero)
    let failureLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.setAccessibilityIdentifier("geojson.map")

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.alignment = .center
        failureLabel.lineBreakMode = .byWordWrapping
        failureLabel.maximumNumberOfLines = 0
        failureLabel.textColor = .secondaryLabelColor
        failureLabel.isHidden = true

        addSubview(mapView)
        addSubview(failureLabel)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            failureLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            failureLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            failureLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct MacGeoJSONMapRepresentable: NSViewRepresentable {
    let plan: GeoJSONViewerPlan

    func makeNSView(context: Context) -> MacGeoJSONMapHostView {
        let host = MacGeoJSONMapHostView()
        host.mapView.delegate = context.coordinator
        host.setAccessibilityIdentifier("geojson.map")
        context.coordinator.apply(plan: plan, to: host)
        return host
    }

    func updateNSView(_ host: MacGeoJSONMapHostView, context: Context) {
        context.coordinator.apply(plan: plan, to: host)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var appliedSource: String?

        func apply(plan: GeoJSONViewerPlan, to host: MacGeoJSONMapHostView) {
            guard appliedSource != plan.source else { return }
            appliedSource = plan.source
            let mapView = host.mapView
            mapView.removeAnnotations(mapView.annotations)
            mapView.removeOverlays(mapView.overlays)

            let contents = GeoJSONMapModel.load(plan)
            if let reason = contents.failureReason {
                mapView.isHidden = true
                host.failureLabel.isHidden = false
                host.failureLabel.stringValue = reason
                host.setAccessibilityLabel(reason)
                host.setAccessibilityIdentifier("geojson.map")
                return
            }

            mapView.isHidden = false
            host.failureLabel.isHidden = true
            host.failureLabel.stringValue = ""
            mapView.addAnnotations(contents.annotations)
            mapView.addOverlays(contents.overlays, level: .aboveRoads)
            fit(contents, on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }
            if annotation is MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "geojson.cluster") as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "geojson.cluster")
                view.annotation = annotation
                view.markerTintColor = .systemBlue
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "geojson.point") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "geojson.point")
            view.annotation = annotation
            view.clusteringIdentifier = "geojson.point"
            view.collisionMode = .circle
            view.displayPriority = .defaultHigh
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = NSColor.systemBlue.withAlphaComponent(0.22)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 2
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            if let multiPolygon = overlay as? MKMultiPolygon {
                let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
                renderer.fillColor = NSColor.systemBlue.withAlphaComponent(0.22)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 2
                return renderer
            }
            if let multiPolyline = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func fit(_ contents: GeoJSONMapModel.Contents, on mapView: MKMapView) {
            if contents.overlays.isEmpty, contents.annotations.count == 1,
               let annotation = contents.annotations.first {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: annotation.coordinate,
                        latitudinalMeters: 2_500,
                        longitudinalMeters: 2_500
                    ),
                    animated: false
                )
                return
            }
            var rect = MKMapRect.null
            for overlay in contents.overlays {
                rect = rect.union(overlay.boundingMapRect)
            }
            for annotation in contents.annotations {
                let point = MKMapPoint(annotation.coordinate)
                let pad = MKMapSize(width: 500, height: 500)
                rect = rect.union(
                    MKMapRect(
                        origin: MKMapPoint(x: point.x - pad.width / 2, y: point.y - pad.height / 2),
                        size: pad
                    )
                )
            }
            guard !rect.isNull, !rect.isEmpty else { return }
            mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 36, left: 28, bottom: 36, right: 28), animated: false)
        }
    }
}
