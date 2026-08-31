import Foundation

/// Where session-window chrome belongs after the native look-and-feel pass.
enum MacSessionChromeRegion: String, Sendable {
    case toolbar
    case inspector
    case composer
    case timeline
}

/// Slot inside the composer capsule. Tests lock iOS ChatInputBar placement
/// without rendering SwiftUI: model/thinking/steering on the action row,
/// dictation left of the send field, stop on the send button.
enum MacSessionComposerSlot: String, Sendable {
    case actionRow
    case primaryButton
    case textRow
}

enum MacSessionComposerPrimaryAction: String, Sendable {
    case send
    case stop
}

enum MacSessionComposerSurface: String, Sendable {
    case editor
    case loading
    case resume
    case stopping
    case failed

    var acceptsInput: Bool { self == .editor }
}

/// Composer Stop aborts the in-flight turn. Session-process kill stays on
/// the session list, matching iOS ChatActionHandler vs Force Stop Session.
enum MacSessionStopKind: String, Sendable {
    case abortTurn
    case stopSessionProcess
}

/// Session-window controls and surfaces. Keep this list platform-neutral so
/// tests can lock the HIG placement without rendering SwiftUI.
enum MacSessionChromeItem: String, CaseIterable, Sendable {
    case title
    case context
    case outline
    case model
    case thinking
    case steering
    case stop
    case dictation
    case fileBrowser
    case changedFiles
    case filePreview
    case diff
    case composer
    case timeline

    var region: MacSessionChromeRegion {
        switch self {
        case .title, .context, .outline:
            .toolbar
        case .fileBrowser, .changedFiles, .filePreview, .diff:
            .inspector
        case .model, .thinking, .steering, .stop, .dictation, .composer:
            .composer
        case .timeline:
            .timeline
        }
    }

    var composerSlot: MacSessionComposerSlot? {
        switch self {
        case .model, .thinking, .steering:
            .actionRow
        case .stop:
            .primaryButton
        case .dictation:
            .textRow
        case .title, .context, .outline, .fileBrowser, .changedFiles, .filePreview, .diff, .composer, .timeline:
            nil
        }
    }
}

/// Path paint for inspector rows and tool headers. SwiftUI's middle
/// truncation eats the filename on long `/Users/.../Foo.swift` strings;
/// keep the last path component and ellipsize the directory instead.
enum MacPathPaint {
    /// Inspector rows are too narrow for a directory prefix; paint the
    /// filename so middle truncation cannot hide it.
    static func inspectorLabel(_ path: String) -> String {
        ToolCallFormatting.fileNameDisplayPath(path)
    }

    static func truncatedKeepingFileName(_ path: String, maxCharacters: Int = 48) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }

        let file = ToolCallFormatting.fileNameDisplayPath(trimmed)
        if trimmed.count <= maxCharacters {
            return trimmed
        }
        if file.count >= maxCharacters {
            return file
        }

        let nsPath = trimmed as NSString
        let directory = nsPath.deletingLastPathComponent
        if directory.isEmpty || directory == "." {
            return file
        }

        let ellipsis = "…"
        let separator = trimmed.contains("/") ? "/" : ""
        let budget = maxCharacters - file.count - ellipsis.count - separator.count
        if budget <= 0 {
            return ellipsis + file
        }
        return String(directory.prefix(budget)) + ellipsis + separator + file
    }
}

enum MacSessionWindowChrome {
    static let inspectorInitiallyPresented = false
    /// Queue, ask, extension, and completion UI share this total budget so the
    /// composer cannot swallow a short session window.
    static let composerAuxiliaryTotalMaximumHeight: CGFloat = 220
    static let composerAuxiliaryRegionSpacing: CGFloat = 10

    static func items(in region: MacSessionChromeRegion) -> [MacSessionChromeItem] {
        MacSessionChromeItem.allCases.filter { $0.region == region }
    }

    /// Mic sits left of the send field, matching iOS ChatInputBar.
    static func composerTextRowItems() -> [MacSessionChromeItem] {
        [.dictation]
    }

    /// Action-row chrome matches iOS ChatInputBar: model and thinking always,
    /// Steering/Follow-up only while the session is busy and no ask card is up.
    static func composerActionRowItems(isBusy: Bool, hasAskRequest: Bool) -> [MacSessionChromeItem] {
        var items: [MacSessionChromeItem] = [.model, .thinking]
        if showsSteering(isBusy: isBusy, hasAskRequest: hasAskRequest) {
            items.insert(.steering, at: 0)
        }
        return items
    }

    static func showsSteering(isBusy: Bool, hasAskRequest: Bool) -> Bool {
        isBusy && !hasAskRequest
    }

    /// Send stays send when there is a draft (steer/follow-up). Empty + busy
    /// morphs the same control into stop, matching ChatInputBar.primaryActionKind
    /// without the iOS ignore-ask case (Mac ask cards keep their own buttons).
    static func composerPrimaryAction(
        isBusy: Bool,
        canSend: Bool,
        isSending: Bool,
        hasAskRequest: Bool
    ) -> MacSessionComposerPrimaryAction {
        if canSend || isSending {
            return .send
        }
        if isBusy && !hasAskRequest {
            return .stop
        }
        return .send
    }

    static func composerStopKind() -> MacSessionStopKind {
        .abortTurn
    }

    static func composerSurface(
        for status: SessionStatus?,
        isLoading: Bool = false
    ) -> MacSessionComposerSurface {
        if isLoading {
            return .loading
        }
        guard let status else { return .loading }
        switch status {
        case .starting, .ready, .busy:
            return .editor
        case .stopping:
            return .stopping
        case .stopped:
            return .resume
        case .error:
            return .failed
        }
    }

    static func showsComposerStateBar(
        surface: MacSessionComposerSurface,
        hasTimelineItems: Bool
    ) -> Bool {
        switch surface {
        case .editor:
            false
        case .loading, .failed:
            // With no transcript, the timeline owns the large loading/error
            // treatment and its recovery action. Repeating it above the
            // composer makes an empty session look like two failures.
            hasTimelineItems
        case .resume, .stopping:
            true
        }
    }

    static func shouldResetComposer(
        previousSessionID: String?,
        currentSessionID: String?
    ) -> Bool {
        previousSessionID != currentSessionID
    }

    /// Async composer work belongs to the session that started it. A picker,
    /// drop provider, or send completion must not mutate a newly selected
    /// session after the user changes rows.
    static func shouldApplyComposerCompletion(
        originatingSessionID: String?,
        currentSessionID: String?
    ) -> Bool {
        guard let originatingSessionID else { return false }
        return originatingSessionID == currentSessionID
    }

    static func shouldApplyAttachmentCompletion(
        originatingSessionID: String?,
        currentSessionID: String?,
        surface: MacSessionComposerSurface
    ) -> Bool {
        shouldApplyComposerCompletion(
            originatingSessionID: originatingSessionID,
            currentSessionID: currentSessionID
        ) && surface.acceptsInput
    }

    static func composerAuxiliaryRegionMaximumHeight(
        hasAboveEditorContent: Bool,
        hasBelowEditorContent: Bool
    ) -> CGFloat {
        let regionCount = (hasAboveEditorContent ? 1 : 0) + (hasBelowEditorContent ? 1 : 0)
        guard regionCount > 0 else { return 0 }
        let totalSpacing = CGFloat(regionCount - 1) * composerAuxiliaryRegionSpacing
        return max(
            (composerAuxiliaryTotalMaximumHeight - totalSpacing) / CGFloat(regionCount),
            0
        )
    }

    static func sessionListStopKind() -> MacSessionStopKind {
        .stopSessionProcess
    }
}
