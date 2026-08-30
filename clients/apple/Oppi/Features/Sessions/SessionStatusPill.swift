import SwiftUI

typealias SessionPillVariant = SessionRowStatusKind

extension SessionRowStatusKind {
    var foregroundColor: Color {
        switch self {
        case .idle, .done: .themeGreen
        case .question, .working: .themeBlue
        case .stopped: .themeComment
        case .error: .themeRed
        }
    }

    var backgroundColor: Color {
        switch self {
        case .idle, .done: .themeGreen.opacity(0.12)
        case .question, .working: .themeBlue.opacity(0.12)
        case .stopped: .themeComment.opacity(0.1)
        case .error: .themeRed.opacity(0.12)
        }
    }
}

/// Compact text status aligned to the row's trailing edge.
struct SessionStatusPill: View {
    let variant: SessionPillVariant

    init(_ variant: SessionPillVariant) {
        self.variant = variant
    }

    var body: some View {
        Text(variant.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(variant.foregroundColor)
            .multilineTextAlignment(.trailing)
    }
}
