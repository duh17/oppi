import SwiftUI

/// Shared expand/collapse motion profile for tool rows.
///
/// Used by native timeline rows so expansion feels consistent across render
/// paths (collection timeline + any future non-collection consumers).
///
/// The UIKit expand/collapse uses top-edge anchoring: the tapped header stays
/// in place and expanded content grows downward. The scroll offset correction
/// is instant; the in-cell content reveal provides the subtle visual polish.
enum ToolRowExpansionAnimation {
    // In-cell reveal for command/output panels (no slide translation).
    static let contentRevealDuration: TimeInterval = 0.05
    static let contentRevealDelay: TimeInterval = 0.0
}
