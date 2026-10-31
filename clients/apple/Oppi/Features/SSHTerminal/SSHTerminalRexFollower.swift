import Foundation
import Observation
import UIKit

/// Follows one Rex host's sessions over a connection of its own that runs no
/// shell: it signs in with the host's sign-in (`SSHTerminalConnectSession`'s
/// `listsRexSessions`), reads Rex through one `RexMonitor` stream
/// (`RexMonitor.run(over:)`) while its screen shows, and drops both when the
/// screen goes or Oppi leaves the foreground. A Rex host's sessions screen
/// (`SSHTerminalRexSessionsViewController`) and the Terminal tab's Rex section
/// (`SSHTerminalHostListViewController`) each hold one per Rex host; they own
/// the screen, the connect chrome, and what is drawn, and this owns the
/// connection and the stream.
///
/// A screen calls `sync(active:)` from its `updateProperties()` with whether
/// it is showing, in the foreground, and not covered. What it reads (the
/// session's connection state, the monitor's snapshot) is observable, so the
/// screen redraws as Rex changes.
@MainActor @Observable
final class SSHTerminalRexFollower: SSHTerminalRexListFollowing {
    let session: SSHTerminalConnectSession
    let monitor: RexMonitor
    var profile: SSHTerminalProfile
    /// A password typed for this visit (not saved): signs in the list.
    var suppliedPassword: String?
    /// Whether the list may sign in by itself when that would ask the person
    /// for a password, a trust decision, or Face ID. A screen opened for the
    /// host does; the Terminal tab never prompts on its own (`connectsWithoutPrompt`),
    /// and shows a row to tap instead.
    let promptsAutomatically: Bool
    /// The list should sign in once its screen shows with nothing over it: set
    /// on appearing, on coming back to the foreground, and when its connection
    /// drops; cleared as the attempt starts, so a failed one is not retried
    /// until one of those happens again (or a pull to refresh).
    private(set) var needsListConnection = true
    /// The list's sign-in in flight, or the last one, was started by the
    /// screen, not by a tap. Never set for a follower that `promptsAutomatically`.
    private(set) var automaticAttempt = false

    /// What that sign-in ran into (a trust decision, a password) is held back
    /// until a tap: the connect chrome presents nothing for it
    /// (`SSHTerminalConnectChrome`'s `presentsPrompts`), and the row says so.
    /// Only the list's own sign-in is held: a pane opened from a row, or a pane
    /// terminal's Reconnect, runs on the same session with `listsRexSessions`
    /// off, and is the person's own action.
    var holdsPrompts: Bool { automaticAttempt && session.listsRexSessions }

    /// What Rex is read over when no sign-in is: tests and the debug harness
    /// pass a stand-in host.
    @ObservationIgnored private let standIn: (any RexStreamHost)?
    /// Whether signing in would ask for nothing (`SSHTerminalProfile.connectsWithoutPrompt`).
    @ObservationIgnored private let signsInSilently: @MainActor (SSHTerminalProfile) -> Bool
    /// The last answer, kept until something that can change it: the Keychain is
    /// not read on every pass of the screen. A `true` is only trusted for what
    /// is drawn; a decision to sign in asks again.
    @ObservationIgnored private var silentCache: Bool?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(
        profile: SSHTerminalProfile,
        suppliedPassword: String? = nil,
        promptsAutomatically: Bool,
        session: SSHTerminalConnectSession = SSHTerminalConnectSession(),
        monitor: RexMonitor? = nil,
        standIn: (any RexStreamHost)? = nil,
        signsInSilently: @escaping @MainActor (SSHTerminalProfile) -> Bool = { $0.connectsWithoutPrompt() }
    ) {
        self.profile = profile.normalized()
        self.suppliedPassword = suppliedPassword
        self.promptsAutomatically = promptsAutomatically
        self.session = session
        // The host's Rex over Tailscale when it can be (`RexRoutePlan`), else the bridge.
        let monitor = monitor ?? RexMonitor(directHost: RexDirectHost(profile: profile))
        self.monitor = monitor
        self.standIn = standIn
        self.signsInSilently = signsInSilently
        monitor.openPane = { [weak session] pane in session?.openRexPane(pane) }
        // Backgrounding closes the connection even while a terminal covers the
        // screen, whose updates then stop.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.markNeedsConnection() }
            },
        ]
    }

    /// Dropped in any way, even while a terminal covered its screen (a stack
    /// replaced under it): nothing of the list's stays open.
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        reader?.cancel()
        session.cancel()
        session.closeRexSessions()
    }

    private var streamHost: (any RexStreamHost)? { standIn ?? session.rexSessions }

    /// Rex is being read, or a sign-in is on its way: nothing to tap.
    var isConnected: Bool { streamHost != nil }

    /// A trust decision is waiting on the person (the host's key is unknown or changed).
    private var trustPending: Bool {
        switch session.hostFailure {
        case .unknownHostKey?, .hostKeyMismatch?: true
        default: false
        }
    }

    /// Signing in would ask the person for something, or a try failed: the
    /// Terminal tab shows a row to tap, which runs the normal connect.
    var needsTap: Bool {
        guard !promptsAutomatically, !isConnected, !session.connecting else { return false }
        // The password sheet is up for a tap that asked for it.
        if session.passwordPrompt, !holdsPrompts { return false }
        if session.passwordPrompt || trustPending || session.failure != nil { return true }
        return !silentForDisplay
    }

    /// What an automatic sign-in ran into, in a line for the row.
    var promptNote: String? {
        if session.passwordPrompt { return "Needs your password." }
        switch session.hostFailure {
        case .unknownHostKey?: return "This host's key is not trusted yet."
        case .hostKeyMismatch?: return "This host's key has changed."
        default: return nil
        }
    }

    private var silentForDisplay: Bool {
        if let silentCache { return silentCache }
        let value = signsInSilently(profile)
        silentCache = value
        return value
    }

    private func canSignInSilently() -> Bool {
        if silentCache == false { return false }
        let value = signsInSilently(profile)
        silentCache = value
        return value
    }

    private func markNeedsConnection() {
        silentCache = nil
        needsListConnection = true
    }

    /// The screen's per-pass hook. `active`: showing, in the foreground, and
    /// with nothing over it. Everything observed is read before the early
    /// return, so a change while inactive still reruns the pass.
    func sync(active: Bool) {
        _ = session.connecting
        _ = session.passwordPrompt
        _ = session.hostFailure
        _ = session.rexSessions
        _ = needsListConnection
        _ = automaticAttempt
        _ = session.listsRexSessions
        guard active else { return }
        if isConnected {
            startReading()
        } else if needsListConnection, standIn == nil, !session.connecting, !session.passwordPrompt, !trustPending,
                  promptsAutomatically || canSignInSilently() {
            connectList(automatic: true)
        }
    }

    /// The host as saved now. A different host, user, or sign-in ends the
    /// connection, which signs in again with the new one.
    func update(profile stored: SSHTerminalProfile) {
        if !stored.sameCredentials(as: profile) {
            session.cancel()
            close()
            // What the old host ran into says nothing about the new one.
            automaticAttempt = false
            session.hostFailure = nil
            session.failure = nil
            session.passwordPrompt = false
            session.password = ""
        }
        silentCache = nil
        profile = stored.normalized()
    }

    /// The screen shows again: sign in if the connection is gone.
    func appeared() {
        silentCache = nil
        manageFailure = nil
        if !isConnected { markNeedsConnection() }
    }

    /// The person asked to connect (a row tapped): signs in whatever the
    /// sign-in needs, over the screen's connect chrome. What an automatic
    /// attempt already ran into (a trust decision, a password) is shown now.
    func connect() {
        if holdsPrompts, session.passwordPrompt || trustPending {
            automaticAttempt = false
            return
        }
        silentCache = nil
        connectList(automatic: false)
    }

    /// Signs in the list's own connection, unless one is open or on its way.
    /// `automatic`: the screen started it, not a tap.
    func connectList(password: String? = nil, automatic: Bool = false) {
        guard !isConnected, !session.connecting, !AppScenePhase.shared.isBackground else { return }
        needsListConnection = false
        automaticAttempt = automatic && !promptsAutomatically
        SSHTerminalFolderEntry.prepare(session: session, profile: profile, target: nil)
        session.listsRexSessions = true
        session.connect(profile: profile, suppliedPassword: password ?? suppliedPassword)
    }

    /// A password typed in the sheet goes to the connect that asked for it:
    /// the list's, or a pane's or the shell's.
    func submitPassword(_ password: String) {
        if session.listsRexSessions {
            connectList(password: password)
        } else {
            session.submitPrompt(password: password)
        }
    }

    /// A pull to refresh: signs the list in again if its connection is gone,
    /// tries again on a host that had no `nc` or no Rex, and otherwise reads
    /// Rex once more over the stream that is open.
    func refresh() async {
        guard standIn != nil || session.rexSessions?.channel.isActive == true else {
            session.closeRexSessions()
            return connectList(automatic: true)
        }
        monitor.retry()
        startReading()
        await monitor.resync()
    }

    /// Follows Rex while the screen shows and its connection is up: one
    /// stream, whose events update the list as Rex changes. A connection that
    /// drops signs in again; a host without `nc` or without Rex is tried
    /// again only by a pull to refresh.
    private func startReading() {
        guard reader == nil, !monitor.gaveUp, let host = streamHost else { return }
        let connection = session.rexSessions
        reader = Task { [weak self, monitor] in
            await monitor.run(over: host)
            guard !Task.isCancelled, let self else { return }
            self.reader = nil
            guard let connection, !connection.channel.isActive, self.session.rexSessions?.channel === connection.channel else { return }
            self.session.closeRexSessions()
            self.markNeedsConnection()
        }
    }

    /// The monitor stops; the connection stays, so the screen coming back
    /// reads Rex again over it.
    func stopReading() {
        reader?.cancel()
        reader = nil
    }

    /// The connection does not outlive the foreground; it signs in again when
    /// Oppi comes back with the screen showing.
    private func enterBackground() {
        stopReading()
        session.closeRexSessions()
    }

    /// Ends the stream and the connection: the screen is gone, or the person
    /// left it for another. It signs in again when the screen shows again.
    func close() {
        stopReading()
        session.closeRexSessions()
        markNeedsConnection()
    }

    /// A change to Rex (new, rename, close) is in flight, or the last one's
    /// failure, shown under the heading until the next one or a refresh.
    private(set) var managing = false
    private(set) var manageFailure: String?

    /// The sessions whose panes the list shows. Kept for the follower's life,
    /// which is the tab's visit: nothing is saved.
    var expandedSessions: Set<String> = []

    var isOpening: Bool { session.connecting || session.passwordPrompt }

    func manage(_ what: String, _ work: () async throws -> Void) async {
        guard !managing else { return }
        managing = true
        manageFailure = nil
        defer { managing = false }
        do {
            try await work()
        } catch is CancellationError {
        } catch {
            manageFailure = "\(what) \(error.localizedDescription)"
        }
    }
}

/// A Rex the Terminal tab lists in a section of its own: a saved SSH host's
/// (`SSHTerminalRexFollower`, signed in over SSH) or one reached over Tailscale
/// alone (`RexTailnetFollower`). The tab draws both with the same rows
/// (`SSHTerminalRexListRow`) and runs the same actions on them: open a session
/// or a pane, show a session's panes, and make, rename, or close sessions.
@MainActor
protocol SSHTerminalRexListFollowing: AnyObject {
    var monitor: RexMonitor { get }
    /// A pane or the list is opening: a second tap waits.
    var isOpening: Bool { get }
    /// A change to Rex is in flight, and why the last one failed.
    var managing: Bool { get }
    var manageFailure: String? { get }
    var expandedSessions: Set<String> { get set }

    /// The person tapped the row that asks to connect.
    func connect()
    /// Runs one change to Rex, one at a time; a failure is kept, with `what`,
    /// for the section to show.
    func manage(_ what: String, _ work: () async throws -> Void) async
}

extension SSHTerminalRexListFollowing {
    /// Rex can be changed now: it has been read, the stream is up, and no
    /// other change is in flight.
    var canManage: Bool { monitor.canManage && !managing }

    /// Makes a session with a shell and opens it.
    func createSession() async {
        await manage("Could not create a session.") {
            let pane = try await monitor.createSession()
            monitor.openPane?(pane)
        }
    }

    func rename(session sessionID: String, to label: String) async {
        await manage("Could not rename the session.") {
            try await monitor.setLabel(label.trimmingCharacters(in: .whitespacesAndNewlines), ofSession: sessionID)
        }
    }

    func close(session sessionID: String) async {
        await manage("Could not close the session.") {
            try await monitor.destroy(session: sessionID)
        }
    }

    func toggleExpanded(session sessionID: String) {
        if expandedSessions.contains(sessionID) {
            expandedSessions.remove(sessionID)
        } else {
            expandedSessions.insert(sessionID)
        }
    }

    /// A tapped pane opens its session in a terminal of its own, on that pane
    /// (an open terminal for the session is shown and moved to it). False when
    /// Rex no longer lists the pane.
    @discardableResult
    func open(session sessionID: String, pane blockID: String) -> Bool {
        monitor.open(.init(scope: sessionID, id: blockID, isGroup: false))
    }

    /// A tapped session opens in a terminal of its own, on its focused pane,
    /// or its first (an open terminal for the session is shown instead of a
    /// second connection). False when the session is no longer in Rex's list.
    @discardableResult
    func open(session sessionID: String) -> Bool {
        guard let session = monitor.snapshot?.sessions.first(where: { $0.sessionID == sessionID }),
              let pane = session.openingPane else { return false }
        return monitor.open(.init(scope: sessionID, id: pane.blockID, isGroup: false))
    }
}

extension RexSnapshot.Session {
    /// The pane a tap on the session opens: the one Rex types into, else the
    /// session's first pane in window order.
    var openingPane: RexSnapshot.Pane? {
        for window in windows {
            if let pane = window.panes.first(where: { isFocused($0, in: window) }) { return pane }
        }
        return windows.lazy.flatMap(\.panes).first
    }
}

extension SSHTerminalProfile {
    /// Whether signing in asks the person for nothing: the host's key is
    /// already trusted, and the credential is behind an approval still valid
    /// (`SSHApprovalCache`: Face ID or the passcode, reused for 5 minutes) or
    /// needs none. A password that is not saved, a key or password not yet
    /// approved, an unknown host key, and a lock that is due all need the
    /// person, so a screen that must not prompt on its own leaves them to a tap.
    @MainActor
    func connectsWithoutPrompt(
        approvals: SSHApprovalCache = .shared,
        knownHosts: SSHKnownHosts = SSHKnownHosts(),
        store: SSHTerminalProfileStore = SSHTerminalProfileStore(),
        appLockRequiresUnlock: Bool = AppLockService.shared.requiresUnlock()
    ) -> Bool {
        let value = normalized()
        // A lock that is due makes the connect end every approval and ask again.
        guard !appLockRequiresUnlock, value.isConfigured, (try? knownHosts.savedKey(host: value.host, port: value.port)) != nil else { return false }
        switch value.authentication {
        case .deviceKey:
            return approvals.context(for: .deviceKeySigning) != nil
        case .password:
            guard value.savesPassword, value.reusesSavedPassword(of: store.profile(id: value.id)) else { return false }
            return approvals.context(for: .savedPassword(account: SSHTerminalProfileStore.passwordAccount(for: value.id))) != nil
        }
    }
}

extension SSHTerminalRexHostStore {
    /// What a monitor found on `profile`'s host: a read of Rex remembers the
    /// host, a host with no `rex` forgets it. A Rex that is not running stays
    /// remembered (it may be started), and so does a host whose `nc` cannot
    /// reach it (the host's fix, not a sign Rex is gone).
    func record(_ finding: RexMonitor.Finding, on profile: SSHTerminalProfile) {
        switch finding {
        case .reached: markSeen(profile)
        case .absent(.notInstalled): forget(profile.id)
        case .absent(.notRunning), .absent(.noNc), .absent(.refused): break
        }
    }
}
