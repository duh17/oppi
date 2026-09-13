#if DEBUG
import Foundation
import SwiftUI

// MARK: - GeoJSON Mount Rainier Preview

/// Production MapKit GeoJSON viewer. Not a snapshot Image.
struct GeoJSONMountRainierPreview: View {
    private static let source = """
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "properties": { "name": "Mount Rainier" },
              "geometry": {
                "type": "Point",
                "coordinates": [-121.7603, 46.8523]
              }
            },
            {
              "type": "Feature",
              "properties": { "name": "Summit area" },
              "geometry": {
                "type": "Polygon",
                "coordinates": [[
                  [-121.7700, 46.8450],
                  [-121.7500, 46.8450],
                  [-121.7500, 46.8600],
                  [-121.7700, 46.8600],
                  [-121.7700, 46.8450]
                ]]
              }
            }
          ]
        }
        """

    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light"
            ? .light
            : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        FullScreenCodeView(
            content: .geoJSON(content: Self.source, filePath: "mount-rainier.geojson")
        )
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier("screenshot.ready")
    }
}
#endif
