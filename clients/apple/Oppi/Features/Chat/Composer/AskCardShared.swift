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

// MARK: - Shared Option Row

struct AskOptionChoiceRow: View {
    enum Density {
        case inline
        case expanded

        var labelFont: Font {
            switch self {
            case .inline: return .subheadline.weight(.semibold)
            case .expanded: return .body.weight(.semibold)
            }
        }

        var descriptionFont: Font {
            switch self {
            case .inline: return .caption
            case .expanded: return .subheadline
            }
        }

        var iconFont: Font {
            switch self {
            case .inline: return .subheadline
            case .expanded: return .body
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .inline: return 12
            case .expanded: return 16
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .inline: return 10
            case .expanded: return 14
            }
        }

        var minimumHeight: CGFloat {
            switch self {
            case .inline: return 52
            case .expanded: return 50
            }
        }

        var cornerRadius: CGFloat { 12 }
    }

    let option: AskOption
    let isSelected: Bool
    let isMultiSelect: Bool
    let density: Density

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if isMultiSelect {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(density.iconFont)
                    .foregroundStyle(isSelected ? .themeBlue : .themeComment)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(density.labelFont)
                    .foregroundStyle(.themeFg)
                    .fixedSize(horizontal: false, vertical: true)

                if let description = option.description {
                    Text(description)
                        .font(density.descriptionFont)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !isMultiSelect && isSelected {
                Image(systemName: "checkmark")
                    .font(density.iconFont.weight(.semibold))
                    .foregroundStyle(.themeBlue)
            }
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.vertical, density.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: density.minimumHeight, alignment: .leading)
        .background(
            isSelected ? Color.themeBlue.opacity(0.15) : Color.themeBgHighlight,
            in: RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous)
                .stroke(
                    isSelected ? Color.themeBlue.opacity(0.5) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous))
    }
}
