import UIKit

/// What the controls of an Org reader do: its heading folds, and, when the
/// reader can save the file, the task controls of `ReaderTaskEditing`.
///
/// Folding belongs to the reader, not the file: it starts all expanded, lives
/// as long as the reader, and is never saved.
@MainActor
final class OrgReaderControls: ReaderTaskControlHandling {
    private let editing: ReaderTaskEditing?
    /// The headings folded, by source line.
    private(set) var folded: Set<Int> = []
    /// Called after a fold changed `folded`; the reader renders again.
    var onFoldChange: (@MainActor () -> Void)?

    init(editing: ReaderTaskEditing?) {
        self.editing = editing
    }

    var allowsTaskControls: Bool { editing?.allowsTaskControls == true }
    var allowsFolding: Bool { true }

    func toggleFold(line: Int) {
        if !folded.insert(line).inserted { folded.remove(line) }
        onFoldChange?()
    }

    func interaction(for control: ReaderTaskControl, in view: UIView) -> ReaderTaskInteraction {
        if control.isFold {
            return .action { [weak self] in self?.toggleFold(line: control.line) }
        }
        return editing?.interaction(for: control, in: view) ?? .action {}
    }
}
