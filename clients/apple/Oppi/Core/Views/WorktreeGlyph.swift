import UIKit

/// The mark for a worktree: a separate checkout of the same repository on its
/// own branch, drawn as a folder with a branch. The one owner: Quick Session's
/// worktree control and picker, a session row's worktree indicator, the
/// workspace screen's worktree control and menu, and the commit graph's chip
/// for a branch another checkout has out all draw it, so the same shape always
/// means "worktree". The main checkout keeps `house`; `arrow.triangle.branch`
/// stays for a branch or a fork, which is what it says.
///
/// A template vector (`worktree-glyph`), drawn at the size of a folder symbol
/// under the same configuration, so it sits beside the symbols around it and
/// tints like one.
enum WorktreeGlyph {
    /// A nil `textStyle` is a menu item's image: unconfigured, at body size.
    @MainActor
    static func image(textStyle: UIFont.TextStyle?) -> UIImage? {
        image(
            configuration: textStyle.map { UIImage.SymbolConfiguration(textStyle: $0) }
                ?? UIImage.SymbolConfiguration(textStyle: .body, scale: .small),
            fallbackSide: UIFont.preferredFont(forTextStyle: textStyle ?? .body).pointSize
        )
    }

    /// Beside text in `font`, at a symbol's `scale` there.
    @MainActor
    static func image(font: UIFont, scale: UIImage.SymbolScale) -> UIImage? {
        image(configuration: UIImage.SymbolConfiguration(font: font, scale: scale), fallbackSide: font.pointSize)
    }

    @MainActor
    private static func image(configuration: UIImage.SymbolConfiguration, fallbackSide: CGFloat) -> UIImage? {
        SymbolSizedLogo.image(
            named: "worktree-glyph",
            reference: "folder",
            configuration: configuration,
            fallbackSide: fallbackSide
        )
    }
}
