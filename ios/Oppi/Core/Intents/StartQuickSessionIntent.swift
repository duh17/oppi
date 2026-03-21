import AppIntents

/// App Intent that opens Oppi and presents the Quick Session sheet.
///
/// Triggered from:
/// - Action Button (via ControlWidget assignment)
/// - Control Center (via ControlWidget)
/// - Lock Screen (via ControlWidget)
/// - Spotlight search
/// - Siri voice command
/// - Shortcuts app
struct StartQuickSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    // periphery:ignore
    static let description: IntentDescription = "Start a new Oppi agent session"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickSessionTrigger.shared.requestPresentation()
        return .result()
    }
}
