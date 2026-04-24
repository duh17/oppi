import SwiftUI

/// Status pill variants for session rows.
///
/// Provides text + color status indication alongside the session title,
/// keeping the list scannable even when section headers are off-screen.
enum SessionPillVariant: Equatable {
    case waiting
    case question
    case idle
    case working
    case done
    case stopped
    case error

    /// Priority: permission (waiting) > ask (question) > status-based.
    static func from(status: SessionStatus, pendingCount: Int, pendingAskCount: Int = 0) -> SessionPillVariant {
        if pendingCount > 0 { return .waiting }
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

    static func from(session: Session, pendingCount: Int, pendingAskCount: Int = 0) -> SessionPillVariant {
        if pendingCount > 0 { return .waiting }
        if pendingAskCount > 0 { return .question }
        if session.isAwaitingFirstPrompt { return .idle }
        return from(status: session.status, pendingCount: 0, pendingAskCount: 0)
    }

    var label: String {
        switch self {
        case .waiting: "Waiting"
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
        case .waiting: .themeOrange
        case .idle, .done: .themeGreen
        case .question, .working: .themeBlue
        case .stopped: .themeComment
        case .error: .themeRed
        }
    }

    var backgroundColor: Color {
        switch self {
        case .waiting: .themeOrange.opacity(0.12)
        case .idle, .done: .themeGreen.opacity(0.12)
        case .question, .working: .themeBlue.opacity(0.12)
        case .stopped: .themeComment.opacity(0.1)
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
