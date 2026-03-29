import SwiftUI
import UIKit

/// Shared logic between AskCard (inline) and AskCardExpanded (full-screen).
///
/// Contains display helpers and the core option selection/toggle logic.
/// View-specific behavior (auto-advance, collapse, custom text clearing)
/// is handled via the `onSingleSelect` callback in `handleOptionTap`.
enum AskCardShared {

    // MARK: - Display Helpers

    static func answerDisplayText(_ answer: AskAnswer?) -> String {
        guard let answer else { return "(not answered)" }
        switch answer {
        case .single(let value):
            return value
        case .multi(let values):
            return Array(values).sorted().joined(separator: ", ")
        case .custom(let text):
            return "\"\(text)\""
        }
    }

    // MARK: - Selection Queries

    static func isOptionSelected(
        _ option: AskOption,
        in question: AskQuestion,
        answers: [String: AskAnswer]
    ) -> Bool {
        guard let answer = answers[question.id] else { return false }
        switch answer {
        case .single(let value):
            return value == option.value
        case .multi(let values):
            return values.contains(option.value)
        case .custom:
            return false
        }
    }

    static func multiSelectCount(
        for question: AskQuestion,
        answers: [String: AskAnswer]
    ) -> Int? {
        guard case .multi(let values) = answers[question.id] else { return nil }
        return values.count
    }

    // MARK: - Option Toggle

    /// Apply option selection logic shared by both inline and expanded ask cards.
    ///
    /// For multi-select: toggles the option in the set.
    /// For single-select: sets the answer and calls `onSingleSelect` so the
    /// caller can perform view-specific follow-up (auto-advance, collapse, etc.).
    static func handleOptionTap(
        _ option: AskOption,
        question: AskQuestion,
        answers: Binding<[String: AskAnswer]>,
        onSingleSelect: () -> Void
    ) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        if question.multiSelect {
            var current: Set<String>
            if case .multi(let existing) = answers.wrappedValue[question.id] {
                current = existing
            } else {
                current = []
            }

            if current.contains(option.value) {
                current.remove(option.value)
            } else {
                current.insert(option.value)
            }
            answers.wrappedValue[question.id] = current.isEmpty ? nil : .multi(current)
        } else {
            answers.wrappedValue[question.id] = .single(option.value)
            onSingleSelect()
        }
    }
}
