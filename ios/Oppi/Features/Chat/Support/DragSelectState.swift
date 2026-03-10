import Foundation

/// Manages the state machine for drag-to-select across a list of rows.
///
/// The first row touched during a drag determines the action direction:
/// - If the row was **unselected**, the drag **selects** rows.
/// - If the row was **selected**, the drag **deselects** rows.
///
/// Each row is only processed once per drag (tracked by `visitedPaths`).
/// Call `reset()` at the end of each drag gesture.
struct DragSelectState: Sendable {

    /// Direction determined by the first row touched during a drag gesture.
    enum Action: Sendable, Equatable {
        case selecting
        case deselecting
    }

    /// The resolved action for this drag, or nil if no row has been touched yet.
    private(set) var action: Action?

    /// Paths already visited during this drag — prevents toggling back and forth.
    private(set) var visitedPaths: Set<String> = []

    /// Process a drag hitting a row at `path`. Mutates `selectedPaths` in place.
    ///
    /// - Parameters:
    ///   - path: The file path of the row under the finger.
    ///   - selectedPaths: The current selection set (modified in place).
    /// - Returns: `true` if the selection changed, `false` if the row was already visited or no-op.
    @discardableResult
    mutating func handleRow(_ path: String, selectedPaths: inout Set<String>) -> Bool {
        guard !visitedPaths.contains(path) else { return false }

        // First row determines direction
        if action == nil {
            action = selectedPaths.contains(path) ? .deselecting : .selecting
        }

        visitedPaths.insert(path)

        switch action {
        case .selecting:
            selectedPaths.insert(path)
            return true
        case .deselecting:
            selectedPaths.remove(path)
            return true
        case .none:
            return false
        }
    }

    /// Reset state at the end of a drag gesture.
    mutating func reset() {
        action = nil
        visitedPaths.removeAll()
    }

    // MARK: - Row hit-testing

    /// Find the file path at a given point, using stored row frames.
    static func pathAtLocation(_ location: CGPoint, in rowFrames: [String: CGRect]) -> String? {
        for (path, frame) in rowFrames where frame.contains(location) {
            return path
        }
        return nil
    }
}
