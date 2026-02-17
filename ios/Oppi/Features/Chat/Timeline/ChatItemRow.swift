import SwiftUI

/// Shared expand/collapse motion profile for tool rows.
///
/// Used by native timeline rows so expansion feels consistent across render
/// paths (collection timeline + any future non-collection consumers).
enum ToolRowExpansionAnimation {
    // Shared very-subtle timing for all tool rows (native + SwiftUI).
    static let expandDuration: TimeInterval = 0.12
    static let collapseDuration: TimeInterval = 0.08

    // In-cell reveal for command/output panels (no slide translation).
    static let contentRevealDuration: TimeInterval = 0.05
    static let contentRevealDelay: TimeInterval = 0.0

    static let swiftUIExpand: Animation = .easeInOut(duration: expandDuration)
    static let swiftUICollapse: Animation = .linear(duration: collapseDuration)
}

/// Identifies a file to open in a sheet.
struct FileToOpen: Identifiable {
    let workspaceId: String
    let sessionId: String
    let path: String

    var id: String { "\(workspaceId)/\(sessionId)/\(path)" }
}
