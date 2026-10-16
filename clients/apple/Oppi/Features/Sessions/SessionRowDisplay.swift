import SwiftUI

/// Device-local choices for how session rows look. This is display only: it
/// never changes which sessions are listed, their status, or what is sent to
/// the server. Every default matches the rich row Oppi has always shown.
///
/// Optional built-in facts keep one fixed order. Status, privacy, context
/// (workspace, worktree, terminal, Pi Control), questions, unread completion,
/// search snippets, and Thread access are not optional.
struct SessionRowDisplay: Equatable, Codable, Sendable {
    enum Density: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard
        case compact

        var id: String { rawValue }

        var label: String {
            switch self {
            case .standard: "Standard"
            case .compact: "Compact"
            }
        }
    }

    var density: Density = .standard

    var showsModel = true
    var showsTime = true
    var showsContextUsage = true
    var showsCost = true
    var showsFilesTouched = true
    var showsCompactions = true

    var showsThreadAgentSummary = true
    var showsThreadLaneGraph = true

    /// Today's rich appearance.
    static let standard = Self()

    var isCompact: Bool { density == .compact }
}

/// The saved row appearance, live. The app root injects `display` into every
/// screen's environment, so a Customize Rows save reaches screens that are
/// already up, pushed ones included.
@MainActor @Observable
final class SessionRowDisplayStore {
    private(set) var display: SessionRowDisplay
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// Follows `AppPreferences.SessionRows` as saves land.
    init() {
        display = AppPreferences.SessionRows.display
        observer = NotificationCenter.default.addObserver(
            forName: AppPreferences.SessionRows.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.display = AppPreferences.SessionRows.display
            }
        }
    }

    /// A fixed appearance, for previews and tests.
    init(fixed display: SessionRowDisplay) {
        self.display = display
    }
}

private struct SessionRowDisplayKey: EnvironmentKey {
    static let defaultValue = SessionRowDisplay.standard
}

extension EnvironmentValues {
    /// Saved row appearance, injected once at the app root. The Customize Rows
    /// editor overrides it locally so its preview uses the draft.
    var sessionRowDisplay: SessionRowDisplay {
        get { self[SessionRowDisplayKey.self] }
        set { self[SessionRowDisplayKey.self] = newValue }
    }
}
