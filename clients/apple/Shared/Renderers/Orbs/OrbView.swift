import AppKit
import SwiftUI

// The Mac's SwiftUI wrapper around `OrbMetalView`. iOS draws the same view in
// UIKit (`OrbMetalView` conforms to `OrbPlatformView`), so the wrapper ships in
// `OppiMac` only and `OrbMetalView.swift` names no SwiftUI type.

struct OrbView: View {
    var style: OrbStyle
    var sizeClass: OrbSizeClass
    var tint: Color
    var voiceSpectrum: VoiceSpectrumFrame = .zero
    var isActive: Bool = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    var body: some View {
        OrbRepresentable(
            style: style,
            sizeClass: sizeClass,
            tint: tint,
            accents: [
                theme.accent.blue,
                theme.accent.cyan,
                theme.accent.purple,
                theme.accent.orange,
            ],
            voiceSpectrum: voiceSpectrum,
            isActive: isActive,
            isDarkBackground: colorScheme == .dark
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .id(themeID)
    }
}

private struct OrbRepresentable: NSViewRepresentable {
    var style: OrbStyle
    var sizeClass: OrbSizeClass
    var tint: Color
    var accents: [Color]
    var voiceSpectrum: VoiceSpectrumFrame
    var isActive: Bool
    var isDarkBackground: Bool

    func makeNSView(context: Context) -> OrbMetalView {
        let view = OrbMetalView(style: style, sizeClass: sizeClass)
        apply(view)
        return view
    }

    func updateNSView(_ nsView: OrbMetalView, context: Context) {
        apply(nsView)
    }

    static func dismantleNSView(_ nsView: OrbMetalView, coordinator: ()) {
        nsView.stopAndDismantle()
    }

    private func apply(_ view: OrbMetalView) {
        view.style = style
        view.sizeClass = sizeClass
        view.tintNSColor = NSColor(tint)
        view.accentNSColors = accents.map { NSColor($0) }
        view.voiceSpectrum = voiceSpectrum
        view.isAnimationEnabled = isActive
        view.isDarkBackground = isDarkBackground
        view.honorsSystemReduceMotion = true
    }
}
