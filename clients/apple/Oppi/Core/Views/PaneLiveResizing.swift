import UIKit

/// A screen whose views are costly to lay out at a new width (the chat's
/// timeline, a reader, the code editor) holds them while a divider beside it
/// moves, and lays them out once when the divider pauses or comes to rest.
///
/// The pan arrives on the main thread, so a re-wrap that runs on a moving
/// frame drops that frame. While held, the screen's cheap chrome (bars, the
/// composer) still follows every frame; its heavy views keep the width they
/// had, clipped when the pane shrinks and beside a plain band when it grows.
/// A screen that does not adopt this gets real layout on every frame.
///
/// The divider's owner calls `paneWillBeginLiveResize` when it starts to move
/// and `paneSettleLiveResize(to:final:)` once the finger pauses (under 30 pt/s
/// for 100 ms, `final` false), and once the divider is at rest (`final`
/// true). After a pause the next movement begins again.
@MainActor
protocol PaneLiveResizing: UIViewController {
    /// A divider beside this screen started to move: hold heavy views at
    /// their current width.
    func paneWillBeginLiveResize()
    /// The divider paused or came to rest (`final`): lay the held views out at
    /// `size`, the screen's size now, keeping the reading position.
    func paneSettleLiveResize(to size: CGSize, final: Bool)
}
