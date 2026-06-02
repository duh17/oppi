import SwiftUI

/// Status pill variants for session rows.
///
/// Provides text + color status indication alongside the session title,
/// keeping the list scannable even when section headers are off-screen.
enum SessionPillVariant: Equatable {
    case question
    case idle
    case working
    case done
    case stopped
    case error

    /// Priority: ask/input request > status-based.
    static func from(status: SessionStatus, pendingAskCount: Int = 0) -> SessionPillVariant {
        if pendingAskCount > 0 { return .question }

        switch status {
        case .busy, .starting, .stopping:
            return .working
        case .ready:
            return .done
        case .stopped:
            return .stopped
        case .error:
            return .error
        }
    }

    static func from(session: Session, pendingAskCount: Int = 0) -> SessionPillVariant {
        if pendingAskCount > 0 { return .question }
        if session.isAwaitingFirstPrompt { return .idle }
        return from(status: session.status)
    }

    var label: String {
        switch self {
        case .question: "Question"
        case .idle: "Idle"
        case .working: "Working"
        case .done: "Done"
        case .stopped: "Stopped"
        case .error: "Error"
        }
    }

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
