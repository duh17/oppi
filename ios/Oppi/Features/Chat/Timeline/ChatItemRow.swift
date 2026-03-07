import SwiftUI

/// Shared expand/collapse motion profile for tool rows.
///
/// Used by native timeline rows so expansion feels consistent across render
/// paths (collection timeline + any future non-collection consumers).
enum ToolRowExpansionAnimation {
    // Shared very-subtle timing for all tool rows (native + SwiftUI).
    // periphery:ignore - intentional animation constants; not yet wired to UIKit rows
    static let expandDuration: TimeInterval = 0.12
    // periphery:ignore - intentional animation constants; not yet wired to UIKit rows
    static let collapseDuration: TimeInterval = 0.08

    // In-cell reveal for command/output panels (no slide translation).
    static let contentRevealDuration: TimeInterval = 0.05
    static let contentRevealDelay: TimeInterval = 0.0

    // periphery:ignore - SwiftUI animation values, not yet wired to expandable rows
    static let swiftUIExpand: Animation = .easeInOut(duration: expandDuration)
    // periphery:ignore - SwiftUI animation values, not yet wired to expandable rows
    static let swiftUICollapse: Animation = .linear(duration: collapseDuration)
}

