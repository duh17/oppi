import SwiftUI

/// Chrome policy for workspace session navigation.
///
/// Toolbar visibility is owned by the active surface. The workspace session
/// list keeps its bottom toolbar automatic; `ChatView` hides the bottom bar
/// when it becomes the active destination.
enum WorkspaceSessionNavigationChromePolicy {
    enum Surface {
        case sessionList
        case sessionTimeline
    }

    static func shouldHideBottomBar(on surface: Surface) -> Bool {
        switch surface {
        case .sessionList:
            return false
        case .sessionTimeline:
            return true
        }
    }

    static func bottomBarVisibility(on surface: Surface) -> Visibility {
        shouldHideBottomBar(on: surface) ? .hidden : .automatic
    }
}
