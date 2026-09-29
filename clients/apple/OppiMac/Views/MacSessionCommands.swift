import SwiftUI

/// Session-scoped commands published by the mounted session. Titles and
/// shortcuts come from `MacAppCommand`; enablement follows the currently
/// focused session, not last-selected.
enum MacSessionCommandKind: String, CaseIterable, Sendable {
    case send
    case stopTurn
    case resume
    case dictation
    case files
    case outline
    case context

    var menuTitle: String { command.title }

    var command: MacAppCommand {
        switch self {
        case .send: .send
        case .stopTurn: .stopTurn
        case .resume: .resume
        case .dictation: .toggleDictation
        case .files: .toggleFiles
        case .outline: .toggleOutline
        case .context: .toggleContext
        }
    }
}

/// Enablement for the Session menu. Matches composer/toolbar owners:
/// Send vs Stop Turn uses `MacSessionWindowChrome.composerPrimaryAction`,
/// Resume uses the ended-session surface, panels require a visible session.
struct MacSessionCommandAvailability: Equatable, Sendable {
    var send: Bool
    var stopTurn: Bool
    var resume: Bool
    var panels: Bool

    static let inactive = Self(send: false, stopTurn: false, resume: false, panels: false)

    struct Input: Equatable, Sendable {
        var isSessionVisible: Bool
        var status: SessionStatus?
        var isLoading: Bool
        var hasDraft: Bool
        var hasAttachments: Bool
        var hasStagedReviewComments: Bool
        var canSendMessage: Bool
        var isSending: Bool
        var isStoppingTurn: Bool
        var isResuming: Bool
        var hasAskRequest: Bool
    }

    static func evaluate(_ input: Input) -> Self {
        guard input.isSessionVisible else { return .inactive }

        let surface = MacSessionWindowChrome.composerSurface(
            for: input.status,
            isLoading: input.isLoading
        )
        let hasContent = input.hasDraft || input.hasAttachments || input.hasStagedReviewComments
        let canSend = input.canSendMessage && hasContent
        let canSubmit = canSend && !input.isSending
        let primary = MacSessionWindowChrome.composerPrimaryAction(
            isBusy: input.status?.isRunning == true,
            canSend: canSend,
            isSending: input.isSending,
            hasAskRequest: input.hasAskRequest
        )

        switch surface {
        case .editor:
            return Self(
                send: primary == .send && canSubmit,
                stopTurn: primary == .stop && !input.isStoppingTurn,
                resume: false,
                panels: true
            )
        case .resume:
            return Self(
                send: false,
                stopTurn: false,
                resume: !input.isResuming,
                panels: true
            )
        case .loading, .stopping, .failed:
            return Self(send: false, stopTurn: false, resume: false, panels: true)
        }
    }

    func isEnabled(_ kind: MacSessionCommandKind) -> Bool {
        switch kind {
        case .send: send
        case .stopTurn: stopTurn
        case .resume: resume
        case .dictation, .files, .outline, .context: panels
        }
    }
}

/// One menu/toolbar action. Disabled items stay visible. Stale sessions are
/// dropped by unmounting the publisher, not by storing a session id here.
struct MacSessionCommandItem {
    var enabled: Bool
    var action: () -> Void

    func perform() {
        guard enabled else { return }
        action()
    }
}

private struct MacSessionSendCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionStopTurnCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionResumeCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionDictationCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionFilesCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionOutlineCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

private struct MacSessionContextCommandKey: FocusedValueKey {
    typealias Value = MacSessionCommandItem
}

extension FocusedValues {
    var macSessionSendCommand: MacSessionCommandItem? {
        get { self[MacSessionSendCommandKey.self] }
        set { self[MacSessionSendCommandKey.self] = newValue }
    }

    var macSessionStopTurnCommand: MacSessionCommandItem? {
        get { self[MacSessionStopTurnCommandKey.self] }
        set { self[MacSessionStopTurnCommandKey.self] = newValue }
    }

    var macSessionResumeCommand: MacSessionCommandItem? {
        get { self[MacSessionResumeCommandKey.self] }
        set { self[MacSessionResumeCommandKey.self] = newValue }
    }

    var macSessionDictationCommand: MacSessionCommandItem? {
        get { self[MacSessionDictationCommandKey.self] }
        set { self[MacSessionDictationCommandKey.self] = newValue }
    }

    var macSessionFilesCommand: MacSessionCommandItem? {
        get { self[MacSessionFilesCommandKey.self] }
        set { self[MacSessionFilesCommandKey.self] = newValue }
    }

    var macSessionOutlineCommand: MacSessionCommandItem? {
        get { self[MacSessionOutlineCommandKey.self] }
        set { self[MacSessionOutlineCommandKey.self] = newValue }
    }

    var macSessionContextCommand: MacSessionCommandItem? {
        get { self[MacSessionContextCommandKey.self] }
        set { self[MacSessionContextCommandKey.self] = newValue }
    }
}
