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

    static func selectionModeHint(for question: AskQuestion) -> String? {
        question.multiSelect ? "Select multiple" : nil
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

struct AskSelectionModePill: View {
    let hint: String?

    init(question: AskQuestion) {
        hint = AskCardShared.selectionModeHint(for: question)
    }

    var body: some View {
        if let hint {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.square")
                    .font(.caption2.weight(.semibold))
                Text(hint)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.themeBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.themeBlue.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("ask.selectionMode.multi")
        }
    }
}

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
        HStack(alignment: .top, spacing: 12) {
            if isMultiSelect {
                multiSelectIndicator
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(density.labelFont)
                    .foregroundStyle(.themeFg)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let description = option.description {
                    Text(description)
                        .font(density.descriptionFont)
                        .foregroundStyle(.themeComment)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if !isMultiSelect && isSelected {
                Image(systemName: "checkmark")
                    .font(density.iconFont.weight(.semibold))
                    .foregroundStyle(.themeBlue)
                    .padding(.top, 2)
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
                    isSelected ? Color.themeBlue.opacity(0.55) : Color.themeComment.opacity(isMultiSelect ? 0.18 : 0),
                    lineWidth: isMultiSelect ? 1 : 1.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: density.cornerRadius, style: .continuous))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var multiSelectIndicator: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.themeBlue : Color.clear)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? Color.themeBlue : Color.themeComment.opacity(0.75), lineWidth: 1.6)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.themeOnBlue)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        if isMultiSelect {
            return isSelected ? "Selected, multi-select" : "Not selected, multi-select"
        }
        return isSelected ? "Selected" : "Not selected"
    }
}
