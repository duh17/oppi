import MapKit
import UIKit

/// Production MapKit surface for GeoJSON/TopoJSON. Tiles may fail offline;
/// annotations and overlays stay. Never shows the user location puck.
final class GeoJSONMapView: UIView, MKMapViewDelegate, FullScreenReaderConfigurable {
    private let plan: GeoJSONViewerPlan
    private let mapView = MKMapView(frame: .zero)
    private let failureLabel = UILabel()
    private let contents: GeoJSONMapModel.Contents

    init(plan: GeoJSONViewerPlan, allowsInteraction: Bool = true) {
        self.plan = plan
        contents = GeoJSONMapModel.load(plan)
        super.init(frame: .zero)
        configure(allowsInteraction: allowsInteraction)
        applyContents()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func displays(_ other: GeoJSONViewerPlan) -> Bool {
        plan == other
    }

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        _ = preferences
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
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.22)
            renderer.strokeColor = UIColor.systemBlue
            renderer.lineWidth = 2
            return renderer
        }
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemBlue
            renderer.lineWidth = 3
            return renderer
        }
        if let multiPolygon = overlay as? MKMultiPolygon {
            let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.22)
            renderer.strokeColor = UIColor.systemBlue
            renderer.lineWidth = 2
            return renderer
        }
        if let multiPolyline = overlay as? MKMultiPolyline {
            let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
            renderer.strokeColor = UIColor.systemBlue
            renderer.lineWidth = 3
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    private func configure(allowsInteraction: Bool) {
        backgroundColor = .secondarySystemBackground
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.delegate = self
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.isScrollEnabled = allowsInteraction
        mapView.isZoomEnabled = allowsInteraction
        mapView.accessibilityIdentifier = "geojson.map"
        mapView.accessibilityLabel = plan.kind.fileType.displayLabel

        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.font = .preferredFont(forTextStyle: .subheadline)
        failureLabel.textColor = .secondaryLabel
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        failureLabel.isHidden = true

        addSubview(mapView)
        addSubview(failureLabel)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            failureLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            failureLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            failureLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    private func applyContents() {
        if let reason = contents.failureReason {
            mapView.isHidden = true
            failureLabel.isHidden = false
            failureLabel.text = reason
            accessibilityIdentifier = "geojson.map"
            accessibilityLabel = reason
            isAccessibilityElement = true
            return
        }

        mapView.isHidden = false
        failureLabel.isHidden = true
        mapView.addAnnotations(contents.annotations)
        mapView.addOverlays(contents.overlays, level: .aboveRoads)
        fitVisibleGeometry()
    }

    private func fitVisibleGeometry() {
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
            rect = rect.union(MKMapRect(origin: MKMapPoint(x: point.x - pad.width / 2, y: point.y - pad.height / 2), size: pad))
        }
        guard !rect.isNull, !rect.isEmpty else { return }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 36, left: 28, bottom: 36, right: 28), animated: false)
    }
}
