import MapKit
import UIKit

/// Production MapKit surface for GeoJSON/TopoJSON. Tiles may fail offline;
/// annotations and overlays stay. Never shows the user location puck.
final class GeoJSONMapView: UIView, MKMapViewDelegate, ReaderBody {
    private let plan: GeoJSONViewerPlan
    private let mapView = MKMapView(frame: .zero)
    /// Shown instead of the map when nothing could be drawn: the same load
    /// state every other document block uses, never a decoder message.
    private let statusView = UIContentUnavailableView(loadState: .loading(nil))
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

    /// Nothing could be drawn, so this shows the load state and no map.
    var isUnavailable: Bool {
        contents.failure != nil
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

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true

        addSubview(mapView)
        addSubview(statusView)
        NSLayoutConstraint.activate([
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusView.topAnchor.constraint(equalTo: topAnchor),
            statusView.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyContents() {
        if let failure = contents.failure {
            mapView.isHidden = true
            statusView.isHidden = false
            statusView.configuration = UIContentUnavailableConfiguration.loadState(
                loadState(failure),
                palette: ThemeRuntimeState.currentPalette()
            )
            accessibilityIdentifier = "geojson.map"
            accessibilityLabel = "\(failure.title). \(failure.detail)"
            isAccessibilityElement = true
            return
        }

        mapView.isHidden = false
        statusView.isHidden = true
        mapView.addAnnotations(contents.annotations)
        mapView.addOverlays(contents.overlays, level: .aboveRoads)
        fitVisibleGeometry()
    }

    /// A map with no coordinates is empty; a map that did not decode failed.
    private func loadState(_ failure: GeoJSONMapModel.Failure) -> LoadState {
        switch failure {
        case .noCoordinates:
            return .empty(title: failure.title, systemImage: "map", message: failure.detail)
        case .invalidDocument:
            return .failed(title: failure.title, message: failure.detail, retry: nil)
        }
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
