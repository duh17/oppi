import Foundation
import Testing

@Suite("ExtensionSurfacePanel chrome")
struct ExtensionSurfacePanelChromeTests {
    @Test("Collapsed strip uses the live elevated glass panel")
    func collapsedStripUsesElevatedGlassPanel() throws {
        let source = try extensionSurfacePanelSource()
        let helper = try extensionSurfacePanelSourceSlice(
            named: "func extensionGlassPanel(cornerRadius: CGFloat = 18) -> some View {",
            until: "func extensionStripPillSurface",
            in: source
        )
        let collapsedStrip = try extensionSurfacePanelSourceSlice(
            named: "if showsStrip {",
            until: "if let activeEntry {",
            in: source
        )

        #expect(helper.contains(".themedSurface("))
        #expect(helper.contains(".elevatedPanel"))
        #expect(collapsedStrip.contains(".extensionGlassPanel(cornerRadius: 18)"))
        #expect(collapsedStrip.contains("extension-strip-\\(placement.accessibilityIdentifierComponent)-collapsed"))
        #expect(!collapsedStrip.contains("extensionStripGlassPanel"))
        #expect(!collapsedStrip.contains(".glassEffect(.regular"))
        #expect(!source.contains("extensionStripGlassPanel"))
        #expect(!source.contains("func extensionStripGlassPanel"))
    }
}

private func extensionSurfacePanelSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Oppi/Features/Chat/Support/ExtensionSurfacePanel.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func extensionSurfacePanelSourceSlice(
    named marker: String,
    until endMarker: String,
    in source: String
) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw ExtensionSurfacePanelSourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw ExtensionSurfacePanelSourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum ExtensionSurfacePanelSourceSliceError: Error {
    case missingMarker(String)
}
