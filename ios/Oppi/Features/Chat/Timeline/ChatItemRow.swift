import SwiftUI

/// Shared expand/collapse motion profile for tool rows.
///
/// Used by native timeline rows so expansion feels consistent across render
/// paths (collection timeline + any future non-collection consumers).
///
/// The UIKit expand/collapse uses bottom-edge anchoring: the bottom of the
/// cell stays in place and content grows upward, keeping the working
/// indicator and items below visible. The scroll offset correction is
/// instant; the in-cell content reveal provides the subtle visual polish.
enum ToolRowExpansionAnimation {
    // periphery:ignore - reserved for future animated scroll correction
    static let expandDuration: TimeInterval = 0.15
    // periphery:ignore - reserved for future animated scroll correction
    static let collapseDuration: TimeInterval = 0.10

    // In-cell reveal for command/output panels (no slide translation).
    static let contentRevealDuration: TimeInterval = 0.05
    static let contentRevealDelay: TimeInterval = 0.0

    // periphery:ignore - SwiftUI animation values, not yet wired to expandable rows
    static let swiftUIExpand: Animation = .easeInOut(duration: expandDuration)
    // periphery:ignore - SwiftUI animation values, not yet wired to expandable rows
    static let swiftUICollapse: Animation = .linear(duration: collapseDuration)
}
