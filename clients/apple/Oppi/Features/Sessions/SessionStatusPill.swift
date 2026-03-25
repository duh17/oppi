import SwiftUI

/// Status pill variants for session rows.
///
/// Provides text + color status indication alongside the dot,
/// satisfying HIG accessibility (status must not rely on color alone).
enum SessionPillVariant: Equatable {
    case waiting
    case idle
    case working
    case done
    case error

    /// Derive the pill variant from session state.
    static func from(status: SessionStatus, pendingCount: Int) -> SessionPillVariant {
        if pendingCount > 0 { return .waiting }

        switch status {
        case .busy, .starting:
            return .working
        case .stopping:
            return .working
        case .ready:
            return .idle
        case .stopped:
            return .done
        case .error:
            return .error
        }
    }

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .error: "Error"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .waiting: .themeOrange
        case .idle: .themeComment
        case .working: .themeCyan
        case .done: .themeGreen
        case .error: .themeRed
        }
    }

    var backgroundColor: Color {
        switch self {
        case .waiting: .themeOrange.opacity(0.12)
        case .idle: .themeComment.opacity(0.1)
        case .working: .themeCyan.opacity(0.12)
        case .done: .themeGreen.opacity(0.12)
        case .error: .themeRed.opacity(0.12)
        }
    }
}

/// Compact text+color pill indicating session status.
struct SessionStatusPill: View {
    let variant: SessionPillVariant

    init(_ variant: SessionPillVariant) {
        self.variant = variant
    }

    var body: some View {
        Text(variant.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(variant.foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(variant.backgroundColor, in: Capsule())
    }
}
