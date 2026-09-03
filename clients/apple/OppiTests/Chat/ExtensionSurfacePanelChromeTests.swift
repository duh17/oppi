import Foundation
import Testing

@Suite("ExtensionSurfacePanel chrome")
struct ExtensionSurfacePanelChromeTests {
    @Test("Collapsed strip has no panel fill; pills use elevatedPanel capsules")
    func collapsedStripUsesElevatedPillsWithoutBar() throws {
        let source = try extensionSurfacePanelSource()
        let pill = try extensionSurfacePanelSourceSlice(
            named: "func extensionStripPillSurface(isActive: Bool, activeStroke: Color) -> some View {",
            until: "private extension View {",
            in: source
        )
        let collapsedStrip = try extensionSurfacePanelSourceSlice(
            named: "if showsStrip {",
            until: "if let activeEntry {",
            in: source
        )
        let drawer = try extensionSurfacePanelSourceSlice(
            named: "private struct ExtensionSurfaceDrawer",
            until: "struct ExtensionSurfacePanel<LeadingStripContent: View>",
            in: source
        )

        #expect(!collapsedStrip.contains(".extensionGlassPanel"))
        #expect(!collapsedStrip.contains("minHeight: 50"))
        #expect(!collapsedStrip.contains(".padding(.horizontal, 8)"))
        #expect(!collapsedStrip.contains(".padding(.vertical, 7)"))
        #expect(!collapsedStrip.contains(".glassEffect(.regular"))
        #expect(collapsedStrip.contains(".frame(maxWidth: .infinity"))
        #expect(collapsedStrip.contains("extension-strip-\\(placement.accessibilityIdentifierComponent)-collapsed"))

        #expect(pill.contains(".themedSurface(.elevatedPanel, in: Capsule())"))
        #expect(pill.contains("ExtensionStripPillMetrics.horizontalPadding"))
        #expect(pill.contains("ExtensionStripPillMetrics.verticalPadding"))
        #expect(pill.contains("ExtensionStripPillMetrics.visualHeight"))
        #expect(pill.contains(".contentShape(Capsule())"))
        #expect(pill.contains("activeStroke.opacity(0.45)"))
        #expect(!pill.contains(".themeFg.opacity(0.08)"))
        #expect(!pill.contains("0.045"))
        #expect(!pill.contains(".background(\n                .themeFg.opacity(isActive ? 0.1 : 0.045)"))

        #expect(drawer.contains(".extensionGlassPanel(cornerRadius: 18)"))
        #expect(source.contains("func extensionGlassPanel(cornerRadius: CGFloat = 18)"))
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
