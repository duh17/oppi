/// Chrome policy for workspace session navigation.
///
/// Toolbar visibility is owned by the active surface. The workspace session
/// list keeps its bottom toolbar automatic; `ChatViewController` hides the bottom bar
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
}
