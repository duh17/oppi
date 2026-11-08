import UIKit

/// The mark for a worktree: a separate checkout folder of the same repository
/// on its own branch (a folder with a branch line and nodes). The one owner:
/// Quick Session's worktree control and picker, a session row's worktree
/// indicator, and the workspace screen's worktree control and menu all draw it,
/// so the same shape always means "worktree". `arrow.triangle.branch` stays for
/// a branch or a fork, which is what it says.
///
/// A template vector (`worktree-glyph`), drawn at the size of a folder symbol
/// under `textStyle`, so it sits beside the symbols around it and tints like one.
enum WorktreeGlyph {
    /// A nil `textStyle` is a menu item's image: unconfigured, at body size.
    @MainActor
    static func image(textStyle: UIFont.TextStyle?) -> UIImage? {
        SymbolSizedLogo.image(
            named: "worktree-glyph",
            reference: "folder",
            configuration: textStyle.map { UIImage.SymbolConfiguration(textStyle: $0) }
                ?? UIImage.SymbolConfiguration(textStyle: .body, scale: .small),
            fallbackSide: UIFont.preferredFont(forTextStyle: textStyle ?? .body).pointSize
        )
    }
}
