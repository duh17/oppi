import UIKit
import os

// iOS only: OppiMac compiles ThemeCatalog.swift (which declares `ThemePalette`,
// `ThemeUIKitPalette`, `ThemeUIKitTokens`, and the runtime state) but not this
// file. It names no SwiftUI type, so it needs no `import SwiftUI`.

extension ThemePalette {
    /// The palette as UIKit colors. See `ThemeUIKitTokens`.
    ///
    /// For the palette the window paints, this is the tokens `ThemeRuntimeState`
    /// built on the last theme change, found by palette identity (one lock and
    /// one compare), so a UIKit view that re-reads `palette.ui` in
    /// `updateProperties()` repaints with the SwiftUI surfaces. Any other palette
    /// — an SSH terminal's own theme, a theme gallery card, a preview — builds
    /// its colors once and keeps them by identity, so one screen can show two
    /// themes at once. Palette colors are static sRGB values, so caching the
    /// `UIColor` conversions cannot go stale against a trait collection; the
    /// identity keeps them from going stale against a changed palette
    /// (`PaletteIdentity`).
    ///
    /// Reads `ThemeRuntimeState`, so do not call it from inside
    /// `ThemeUIKitPalette.init`, `ThemeUIKitTokens.init`, or the runtime state's
    /// own init: those run under the state lock (`bee815ece`).
    var ui: ThemeUIKitTokens {
        let identity = self.identity
        if let painted = ThemeRuntimeState.currentUIKitTokens(for: identity) {
            return painted
        }
        return ThemeUIKitTokensStore.tokens(for: self, identity: identity)
    }
}

/// Builds `ThemeUIKitTokens` once per palette build.
///
/// The runtime palette's colors come from `ThemeRuntimeState` instead; what is
/// left here is the palettes no window paints, and the key is the palette's
/// identity, so a hit costs one compare and no color comparison or allocation.
enum ThemeUIKitTokensStore {
    private struct Entry {
        let identity: PaletteIdentity
        let tokens: ThemeUIKitTokens
    }

    /// Most recently built first. One screen holds a handful of themes at once
    /// (an SSH terminal's own theme beside the app's, a gallery of every theme,
    /// the theme a preview pins), so the cap holds a screen's worth.
    private static let entries = OSAllocatedUnfairLock(initialState: [Entry]())
    private static let capacity = 16

    static func tokens(for palette: ThemePalette, identity: PaletteIdentity) -> ThemeUIKitTokens {
        let hit = entries.withLock { (entries: inout [Entry]) -> ThemeUIKitTokens? in
            entries.first { $0.identity == identity }?.tokens
        }
        if let hit { return hit }

        let tokens = ThemeUIKitTokens(
            shared: ThemeUIKitPalette(palette: palette),
            palette: palette
        )
        entries.withLock { (entries: inout [Entry]) in
            entries.insert(Entry(identity: identity, tokens: tokens), at: 0)
            if entries.count > capacity {
                entries.removeLast(entries.count - capacity)
            }
        }
        return tokens
    }
}
