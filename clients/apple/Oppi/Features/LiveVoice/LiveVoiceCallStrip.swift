import UIKit

/// What the app-wide call strip shows for the app's Live Voice call, or nil to hide it.
///
/// The strip is the call's surface everywhere except the call's own chat, whose composer
/// already is the call: it shows over every other screen (lists, Settings, Files, another
/// session's chat, the lock cover) and hides only while a chat on the call's session is on
/// screen (`LiveVoiceCallCenter.shownChats`).
struct LiveVoiceCallStripContent: Equatable {
    enum Phase: Equatable {
        /// Placed and waiting for the server to confirm it.
        case connecting
        case live
        /// The call failed; the reason stays until End dismisses it.
        case failed
    }

    let key: LiveVoiceCallCenter.CallKey
    /// The session's title, or "Live Voice" while a lock hides it.
    let title: String
    /// Connecting, Listening, Muted, Speaking, the agent's progress, Reconnecting, or why the
    /// call failed (`LiveVoiceCallController.composerStatus`).
    let status: String
    let phase: Phase
    let isMuted: Bool
    /// Duration counts from here (`LiveVoiceCallController.connectedAt`).
    let connectedAt: Date?

    static let lockedTitle = "Live Voice"

    /// - Parameters:
    ///   - sessionTitle: the call's session title as its server's store knows it.
    ///   - titleIsHidden: a scoped lock (server, workspace, or session) covers the call's session.
    @MainActor
    static func make(
        call: LiveVoiceCallCenter.Call?,
        shownChats: some Collection<LiveVoiceCallCenter.CallKey>,
        sessionTitle: String?,
        titleIsHidden: Bool
    ) -> Self? {
        guard let call, !shownChats.contains(call.key) else { return nil }
        let controller = call.controller
        let phase: Phase
        if controller.lastError != nil, !controller.isLive {
            phase = .failed
        } else if controller.isLive, controller.connectedAt != nil {
            phase = .live
        } else if controller.holdsComposer {
            // Placed and on its way: everything before the server's confirmation.
            phase = .connecting
        } else {
            return nil
        }
        let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(
            key: call.key,
            title: titleIsHidden || title.isEmpty ? lockedTitle : title,
            status: phase == .failed ? (controller.lastError ?? controller.composerStatus) : controller.composerStatus,
            phase: phase,
            isMuted: phase != .failed && controller.isMuted,
            connectedAt: phase == .live ? controller.connectedAt : nil
        )
    }

    /// The app's call as the strip shows it now, read from the root's stores (observed by the
    /// caller's update pass).
    @MainActor
    static func current(
        root: AppRootEnvironment,
        locks: ScopedLockService = .shared
    ) -> Self? {
        let center = root.liveVoiceCalls
        guard let call = center.currentCall else { return nil }
        let key = call.key
        let session = root.coordinator.connection(for: key.serverId)?.sessionStore.session(id: key.sessionId)
        let target = ScopedLockTarget.session(
            serverId: key.serverId,
            workspaceId: session?.workspaceId,
            sessionId: key.sessionId,
            isIncognito: session?.ephemeral == true
        )
        return make(
            call: call,
            shownChats: center.shownChats.values,
            sessionTitle: session?.displayTitle,
            titleIsHidden: locks.isLocked(target)
        )
    }

    /// "4:05", or "1:02:09" past an hour.
    static func durationText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }

    /// "4 minutes, 5 seconds", for VoiceOver.
    static func spokenDuration(since start: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: max(0, now.timeIntervalSince(start))) ?? ""
    }
}

/// The call mark on a session's list row: the session has the app's live call.
enum SessionRowCallBadge: Equatable {
    case live
    case muted

    var accessibilityLabel: String {
        switch self {
        case .live: "On a Live Voice call"
        case .muted: "On a Live Voice call, muted"
        }
    }
}

extension LiveVoiceCallCenter {
    /// The row badge for this session: only while its call holds the microphone (connecting
    /// included).
    func rowBadge(serverId: String, sessionId: String) -> SessionRowCallBadge? {
        guard ownsMicrophone, let currentCall,
              currentCall.key == CallKey(serverId: serverId, sessionId: sessionId) else { return nil }
        return currentCall.controller.isMuted ? .muted : .live
    }
}

/// The call strip at the top of the workspace shell. `WorkspaceShellController` owns its
/// place: it pushes the layout (and the lock cover) down by `contentHeight`, so every screen
/// under it keeps its own bars and content clear of the strip without wiring of its own.
@MainActor
final class LiveVoiceCallStripController: UIViewController {
    private let root: AppRootEnvironment
    private let currentContent: @MainActor (AppRootEnvironment) -> LiveVoiceCallStripContent?
    private(set) var content: LiveVoiceCallStripContent?
    private let stripView = LiveVoiceCallStripView()
    private var clock: Timer?
    private var isInBackground = false

    /// The strip changed: the shell lays its content out again, animated when the strip came
    /// or went.
    var onContentChange: ((_ cameOrWent: Bool) -> Void)?

    init(
        root: AppRootEnvironment,
        currentContent: @escaping @MainActor (AppRootEnvironment) -> LiveVoiceCallStripContent? = {
            LiveVoiceCallStripContent.current(root: $0)
        }
    ) {
        self.root = root
        self.currentContent = currentContent
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let strip = stripView
        strip.onOpen = { [weak self] in self?.openCallSession() }
        strip.onToggleMute = { [weak self] in self?.toggleMute() }
        strip.onEnd = { [weak self] in self?.endCall() }
        view = strip
    }

    /// The strip's height under the status bar for `width`; zero while hidden.
    func contentHeight(fitting width: CGFloat) -> CGFloat {
        guard content != nil else { return 0 }
        return stripView.contentHeight(fitting: width)
    }

    override func updateProperties() {
        super.updateProperties()
        let next = currentContent(root)
        // The theme's light or dark, as the layouts under it take it, so the glass and the
        // system colors match the screen whatever the window was given.
        stripView.setAppearance(root.themeStore.userInterfaceStyle)
        stripView.backdropColor = root.themeStore.backgroundColor
        // No clock in the background; the duration is current again the moment the app is back.
        let inBackground = AppScenePhase.shared.isBackground
        if inBackground != isInBackground {
            isInBackground = inBackground
            if !inBackground, content != nil { stripView.updateDuration(now: Date()) }
            updateClock()
        }
        guard next != content else { return }
        let cameOrWent = (next == nil) != (content == nil)
        content = next
        if let next {
            stripView.apply(next, now: Date())
        }
        view.isHidden = next == nil
        updateClock()
        // A wrapped title or failure reason can change the strip's height too.
        onContentChange?(cameOrWent)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateClock()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clock?.invalidate()
        clock = nil
    }

    /// One tick a second while a connected call's duration shows; nothing otherwise.
    private func updateClock() {
        let ticks = content?.connectedAt != nil && viewIfLoaded?.window != nil && !isInBackground
        guard ticks != (clock != nil) else { return }
        clock?.invalidate()
        clock = nil
        guard ticks else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stripView.updateDuration(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    // MARK: Actions

    /// Back to the call: its session opens through the app's one open path, which switches
    /// servers and asks for a lock as any other open does.
    private func openCallSession() {
        guard let key = content?.key else { return }
        root.opener.open(.session(SessionOpen(
            serverId: key.serverId,
            sessionId: key.sessionId,
            origin: .inAppHyperlink
        )))
    }

    private func toggleMute() {
        root.liveVoiceCalls.currentCall?.controller.toggleMute()
    }

    /// End, or Dismiss for a failed call.
    private func endCall() {
        guard let controller = root.liveVoiceCalls.currentCall?.controller else { return }
        Task { await controller.end() }
    }
}
