import Foundation
import Observation
import OSLog
import UIKit

private let openerLog = Logger(subsystem: AppIdentifiers.subsystem, category: "AppOpener")

/// Everything that opens something in Oppi, from any entry point: scene URLs,
/// notification responses, App Intents and controls, timeline and extension
/// links, and SwiftUI `openURL`.
enum AppOpenRequest: Equatable, Sendable {
    case session(SessionOpen)
    /// Pairing-approval notification. `.deny` skips App Lock and launch: the
    /// system action already authenticated, and the server forgets the
    /// approval in two minutes.
    case pairing(serverId: String, approvalId: String?, action: PairingNotificationAction)
    /// Control widget, Action Button, "New Session" Shortcut.
    case quickSession(QuickSessionStart)
    /// `oppi://workspace?path=&name=&server=`: workspace creation, prefilled.
    case createWorkspace(WorkspaceDeepLink.Payload)
    /// `oppi://connect` or `oppi://pair`.
    case invite(URL)
    /// http(s): the browser preference decides in-app or system.
    case webLink(URL)
    /// `[[target]]`: a session, a workspace file, or a host file; may ask which.
    case resourceReference(ResourceReference)
    /// `[[file]]` inside a session-origin reader.
    case sessionFile(ResourceReference)
    /// `file://` link inside a workspace.
    case fileLink(FileLinkPayload)
    /// Any other scheme (`mailto:`, `tel:`, ...): the system opens it.
    case system(URL)

    /// One URL parser for scene URLs, in-app links, and SwiftUI `openURL`.
    ///
    /// `origin` says whether a session link replaces the visible route or
    /// keeps the back stack. `sourceServerID` is an in-app link's source
    /// server; a scene URL carries no server, so session resolution falls
    /// back to the cached stores.
    init(url: URL, origin: SessionNavigationSource, sourceServerID: String? = nil) {
        let scheme = url.scheme?.lowercased()
        if let session = SessionOpen(
            url: url,
            origin: origin,
            sourceServerID: sourceServerID
        ) {
            self = .session(session)
        } else if scheme == "oppi", let payload = WorkspaceDeepLink.payload(from: url) {
            self = .createWorkspace(payload)
        } else if scheme == "oppi" {
            self = .invite(url)
        } else if let reference = ResourceReferenceURL.parse(url) {
            self = .resourceReference(reference)
        } else if scheme == "http" || scheme == "https" {
            self = .webLink(url)
        } else {
            self = .system(url)
        }
    }
}

/// One session open. The same value comes from a push tap, a scene URL, Siri,
/// and a link inside Oppi.
struct SessionOpen: Equatable, Sendable {
    /// Where the session lives: a push, banner, or Siri receipt names it. Nil
    /// only for `oppi://session/<id>` URLs, which carry no server.
    var serverId: String?
    var sessionId: String
    /// Hint only; the session's own record wins once it is loaded.
    var workspaceId: String?
    /// `.externalURL` replaces the visible route; `.inAppHyperlink` keeps the
    /// back stack.
    var origin: SessionNavigationSource
    /// Siri "Start Session": the durable receipt to consume once its server is
    /// up (the created row and any unsent prompt).
    var startedSessionRequestID: Int?

    init(
        serverId: String? = nil,
        sessionId: String,
        workspaceId: String? = nil,
        origin: SessionNavigationSource,
        startedSessionRequestID: Int? = nil
    ) {
        self.serverId = serverId
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.origin = origin
        self.startedSessionRequestID = startedSessionRequestID
    }

    /// Nil unless `url` is `oppi://session/<id>`. A `?workspaceId=` query is
    /// ignored: a URL must never choose the session's workspace (or its lock
    /// scope); only server-provided payloads carry one.
    init?(url: URL, origin: SessionNavigationSource, sourceServerID: String? = nil) {
        guard url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "session" else {
            return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pathParts = (components?.percentEncodedPath ?? url.path)
            .split(separator: "/", omittingEmptySubsequences: true)
        guard pathParts.count == 1, let rawId = pathParts.first else { return nil }
        let sessionId = (String(rawId).removingPercentEncoding ?? String(rawId))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionId.isEmpty else { return nil }

        self.init(serverId: sourceServerID, sessionId: sessionId, origin: origin)
    }
}

/// In-app session links resolve through the source server when it has the
/// session, otherwise only through a unique match. An external `oppi://`
/// session URL carries no server and takes the same unique-match fallback.
enum InAppSessionServerResolution {
    static func resolve(
        sourceServerID: String?,
        sourceServerHasMatch: Bool,
        matchingServerIDs: [String]
    ) -> String? {
        if let sourceServerID {
            return sourceServerHasMatch ? sourceServerID : nil
        }
        let uniqueMatches = Set(matchingServerIDs)
        return uniqueMatches.count == 1 ? uniqueMatches.first : nil
    }
}

/// What a destination did with an open. `.unreachable` keeps the request in
/// the one parked slot so the next foreground retries it.
enum AppOpenOutcome {
    case finished
    case unreachable
}

/// `oppi://workspace?path=<path>&name=<name>[&server=<fingerprint>]`.
enum WorkspaceDeepLink {
    struct Payload: Equatable, Sendable {
        let path: String
        let name: String?
        let serverFingerprint: String?
        /// Client-only: the server the opener resolved and switched to, so the
        /// shell never resolves it a second time with different rules.
        var resolvedServerId: String?

        init(
            path: String,
            name: String?,
            serverFingerprint: String?,
            resolvedServerId: String? = nil
        ) {
            self.path = path
            self.name = name
            self.serverFingerprint = serverFingerprint
            self.resolvedServerId = resolvedServerId
        }

        func resolved(on serverId: String) -> Self {
            var copy = self
            copy.resolvedServerId = serverId
            return copy
        }
    }

    static func fingerprintsMatch(_ lhs: String, _ rhs: String) -> Bool {
        normalizedFingerprint(lhs) == normalizedFingerprint(rhs)
    }

    static func payload(from url: URL) -> Payload? {
        guard url.scheme?.lowercased() == "oppi" else {
            return nil
        }
        guard routeName(from: url) == "workspace" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        guard let path = trimmedQueryValue("path", in: queryItems), !path.isEmpty else {
            return nil
        }

        let name = nonEmptyTrimmedQueryValue("name", in: queryItems)
        let serverFingerprint = nonEmptyTrimmedQueryValue("server", in: queryItems)
        return Payload(path: path, name: name, serverFingerprint: serverFingerprint)
    }

    private static func routeName(from url: URL) -> String? {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host.lowercased()
        }
        return url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first?
            .lowercased()
    }

    private static func trimmedQueryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        queryItems
            .first { $0.name.lowercased() == name }
            .flatMap(\.value)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmptyTrimmedQueryValue(_ name: String, in queryItems: [URLQueryItem]) -> String? {
        guard let value = trimmedQueryValue(name, in: queryItems), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedFingerprint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("sha256:") {
            return String(trimmed.dropFirst("sha256:".count))
        }
        return trimmed
    }
}

/// The one owner of every open in the app.
///
/// Entry points deliver an `AppOpenRequest`; nothing else waits for App Lock,
/// launch, a scoped lock, or the target server. One parked slot keeps the
/// latest request until the app and its server are ready; a newer request
/// replaces it and cancels the work the older one started.
@MainActor @Observable
final class AppOpener {
    typealias BrowserPresent = @MainActor (URL) -> Void
    typealias SystemOpen = @MainActor (URL) -> Void

    // Sibling `AppOpener+*.swift` files hold the destination work that is
    // real logic (resource references, invites), so these are internal.
    let coordinator: ConnectionCoordinator
    let navigation: AppNavigation
    private let composerDraftStore: ComposerDraftStore
    private let appLock: AppLockService
    let scopedLock: ScopedLockService
    private let intentSessionOpenTrigger: IntentSessionOpenTrigger
    /// The browser preference's two effects. Tests record them.
    @ObservationIgnored private let browserPresent: BrowserPresent
    @ObservationIgnored private let systemOpen: SystemOpen

    var serverStore: ServerStore { coordinator.serverStore }
    var activeConnection: ServerConnection { coordinator.activeConnection }

    /// An invite waiting for approval on the user's other device. The root
    /// covers the app until it resolves or the user cancels.
    var invitePairingWaitExpiresAt: Int64?
    /// A `[[link]]` that matched more than one resource. The root asks which.
    var pendingResourceReferenceChoice: PendingResourceReferenceChoice?

    @ObservationIgnored private var hasFinishedLaunch = false
    /// The one parked request: App Lock, launch, an invite bootstrap, or an
    /// unreachable server is keeping it. A newer request replaces it.
    @ObservationIgnored private var parked: AppOpenRequest?
    /// The generation of the request that owns `currentTask`; every await
    /// checks it so a superseded open cannot navigate.
    @ObservationIgnored var generation: UInt64 = 0
    @ObservationIgnored var currentTask: Task<Void, Never>?
    @ObservationIgnored var invitePairingGate = InvitePairingGate()
    @ObservationIgnored var invitePairingTask: Task<Void, Never>?
#if DEBUG
    /// Replaces the network round trip for a server switch in unit tests.
    @ObservationIgnored var _serverReadyForTesting: (@MainActor (String) async -> Bool)?
    /// A debug harness answers its own `[[links]]` from fixtures. True means
    /// it handled the reference.
    @ObservationIgnored var _resourceReferenceHandlerForTesting: (@MainActor (ResourceReference) -> Bool)?
    /// Observes (and absorbs) every request in unit tests, so a producer test
    /// proves delivery without opening anything.
    @ObservationIgnored var _openRequestObserverForTesting: (@MainActor (AppOpenRequest) -> Bool)?
    /// Pins the browser preference in tests; nil reads the stored setting.
    @ObservationIgnored var _browserLinkPreferenceForTesting: AppPreferences.Browser.LinkOpeningMode?
    /// Advances the parked-request lifetime in tests.
    @ObservationIgnored var _nowForTesting: (() -> Date)?
#endif

    /// A parked request is given up after this long: it is a tap, not a task.
    private static let parkedRequestLifetime: TimeInterval = 10 * 60
    @ObservationIgnored private var parkedAt: Date?
    /// Only a foreground app runs parked work; a background launch just parks.
    @ObservationIgnored private var sceneIsActive = false
    /// A request waiting in App Lock's one deferred slot. It is tracked so a
    /// leftover Siri receipt or a parked drain cannot overwrite it.
    @ObservationIgnored private var deferredRequest: AppOpenRequest?
    /// The parked request has already said its server is unreachable; retries
    /// stay silent.
    @ObservationIgnored private var didToastUnreachable = false
    /// The request the current task is running, so a newer open can abandon
    /// its Siri receipt instead of replaying it at the next launch.
    @ObservationIgnored private var activeRequest: AppOpenRequest?

    private var now: Date {
#if DEBUG
        if let _nowForTesting { return _nowForTesting() }
#endif
        return Date()
    }

    init(
        coordinator: ConnectionCoordinator,
        navigation: AppNavigation,
        composerDraftStore: ComposerDraftStore,
        appLock: AppLockService = .shared,
        scopedLock: ScopedLockService = .shared,
        intentSessionOpenTrigger: IntentSessionOpenTrigger = .shared,
        browserPresent: @escaping BrowserPresent = { InAppBrowserPresenter.present(url: $0) },
        systemOpen: @escaping SystemOpen = { UIApplication.shared.open($0) }
    ) {
        self.coordinator = coordinator
        self.navigation = navigation
        self.composerDraftStore = composerDraftStore
        self.appLock = appLock
        self.scopedLock = scopedLock
        self.intentSessionOpenTrigger = intentSessionOpenTrigger
        self.browserPresent = browserPresent
        self.systemOpen = systemOpen
    }

    /// The only way in.
    func open(_ request: AppOpenRequest) {
#if DEBUG
        if let observer = _openRequestObserverForTesting, observer(request) {
            return
        }
#endif
        if case .pairing(let serverId, let approvalId, .deny) = request {
            // Deny never parks and never waits for App Lock: the notification
            // action already authenticated, and the server's TTL bounds it.
            denyPairing(serverId: serverId, approvalId: approvalId)
            return
        }
        supersede()
        let generation = generation
        deferredRequest = request
        appLock.performWhenUnlocked { [weak self] in
            self?.accept(request, generation: generation)
        }
    }

    /// Launch is over: parked work can run, and so can web and system links
    /// that never needed it.
    func launchDidFinish() {
        hasFinishedLaunch = true
        // A receipt left by a process that died before it came forward opens
        // now. It is an open like any other: a locked app defers it. A parked
        // request is the newer one: it wins the slot.
        if parked == nil, deferredRequest == nil, let receipt = intentSessionOpenTrigger.peek() {
            open(.session(SessionOpen(
                serverId: receipt.serverId,
                sessionId: receipt.sessionId,
                workspaceId: receipt.workspaceId,
                origin: .externalURL,
                startedSessionRequestID: receipt.requestID
            )))
            return
        }
        drainParkedIfPossible()
    }

    /// The app is in front again: retry a request whose server was unreachable.
    /// A newer tap has already replaced it.
    func sceneDidBecomeActive() {
        sceneIsActive = true
        drainParkedIfPossible()
    }

    func sceneDidEnterBackground() {
        sceneIsActive = false
        // App Lock drops its one deferred action on background; do not keep
        // advertising a deferred request that can never run.
        deferredRequest = nil
    }

    /// The root's presentation changed (onboarding finished, launch ready): a
    /// Quick Session parked behind it can run now.
    func presentationDidUpdate() {
        drainParkedIfPossible()
    }

    // MARK: - Parking

    private func supersede() {
        abandonIntentReceipt(for: activeRequest)
        abandonIntentReceipt(for: parked)
        abandonIntentReceipt(for: deferredRequest)
        generation &+= 1
        clearParked()
        activeRequest = nil
        deferredRequest = nil
        currentTask?.cancel()
        currentTask = nil
    }

    private func abandonIntentReceipt(for request: AppOpenRequest?) {
        guard case .session(let open)? = request,
              let requestID = open.startedSessionRequestID else { return }
        intentSessionOpenTrigger.abandon(requestID: requestID)
    }

    private func accept(_ request: AppOpenRequest, generation: UInt64) {
        guard generation == self.generation else { return }
        // The current accept owns the deferred slot; a superseded accept leaves
        // the newer request (and its receipt) in place.
        deferredRequest = nil
        if case .invite(let url) = request {
            startInvite(url, generation: generation)
            return
        }
        run(request, generation: generation)
    }

    private func run(_ request: AppOpenRequest, generation: UInt64) {
        guard generation == self.generation else { return }
        currentTask?.cancel()
        activeRequest = request
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await perform(request, generation: generation)
        }
    }

    func drainParkedIfPossible() {
        guard let request = parked else { return }
        // A removed server or a sign-out ends the request instead of leaving a
        // toast that repeats at every launch.
        if let serverId = serverIdReferenced(by: request), serverStore.server(for: serverId) == nil {
            clearParked()
            return
        }
        if let parkedAt, now.timeIntervalSince(parkedAt) > Self.parkedRequestLifetime {
            openerLog.notice("Dropping a parked open request that waited too long")
            clearParked()
            return
        }
        // A background launch or a parked retry runs only while the app is in
        // front; the next active transition drains it.
        guard sceneIsActive else { return }
        // An open already owns App Lock's one deferred slot; arming a drain now
        // would replace the user's tap.
        guard deferredRequest == nil else { return }
        guard !appLock.requiresUnlock() else {
            // App Lock's deferred slot drains this after the next unlock. A
            // cancelled unlock drops that slot; the next foreground or root
            // update re-arms it.
            appLock.performWhenUnlocked { [weak self] in self?.drainParkedIfPossible() }
            return
        }
        // Unlocked with a tracked deferred request means App Lock dropped its
        // action (cancelled unlock): forget it so it cannot block later opens.
        deferredRequest = nil
        guard canRunNow(request) else { return }
        // Keep `parkedAt`: a retry of the same request must not restart its
        // 10-minute lifetime.
        parked = nil
        generation &+= 1
        run(request, generation: generation)
    }

    private func clearParked() {
        parked = nil
        parkedAt = nil
        didToastUnreachable = false
    }

    /// The server a request needs, when it names one up front. Requests that
    /// resolve their server later are cleared by the destination's own lookup.
    private func serverIdReferenced(by request: AppOpenRequest) -> String? {
        switch request {
        case .session(let open):
            return open.serverId
        case .pairing(let serverId, _, _):
            return serverId
        case .resourceReference(let reference), .sessionFile(let reference):
            return reference.sourceServerID
        case .createWorkspace(let payload):
            return payload.resolvedServerId
        default:
            return nil
        }
    }

    private var isInviteInFlight: Bool { invitePairingGate.inFlight }

    /// Launch gates everything but web and system links and an invite, which
    /// needs only the pairing list. Quick Session also waits for the shell:
    /// the sheet must not open over onboarding.
    private func canRunNow(_ request: AppOpenRequest) -> Bool {
        if isInviteInFlight { return false }
        switch request {
        case .webLink, .system:
            return true
        case .quickSession:
            return hasFinishedLaunch
                && navigation.launchPhase == .ready
                && !navigation.showOnboarding
        case .pairing(_, _, .deny):
            return true
        case .invite:
            // accept() runs an invite on its own generation; it never parks.
            return false
        default:
            return hasFinishedLaunch
        }
    }

    private func park(_ request: AppOpenRequest) {
        parked = request
        // A retry of the same request keeps its original deadline.
        if parkedAt == nil { parkedAt = now }
        activeRequest = nil
        openerLog.notice("Parked open request until the app and its server are ready")
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    /// Brings `serverId` up, refusing to activate a superseded request.
    func openServer(_ serverId: String, generation: UInt64) async -> Bool {
#if DEBUG
        if let _serverReadyForTesting {
            return await _serverReadyForTesting(serverId)
        }
#endif
        return await coordinator.switchToServerReady(serverId, shouldActivate: { [weak self] in
            self?.isCurrent(generation) ?? false
        })
    }

    private func perform(_ request: AppOpenRequest, generation: UInt64) async {
        guard isCurrent(generation) else { return }
        guard canRunNow(request) else {
            park(request)
            return
        }

        let outcome: AppOpenOutcome
        switch request {
        case .session(let open):
            outcome = await performSession(open, generation: generation)
        case .createWorkspace(let payload):
            outcome = await performCreateWorkspace(payload, generation: generation)
        case .quickSession(let start):
            navigation.presentQuickSession(start, from: .intent)
            outcome = .finished
        case .pairing(let serverId, let approvalId, let action):
            PairingApprovalController.shared.handleNotification(
                serverId: serverId,
                approvalId: approvalId,
                action: action,
                coordinator: coordinator
            )
            outcome = .finished
        case .webLink(let url):
            presentWebLink(url)
            outcome = .finished
        case .system(let url):
            systemOpen(url)
            outcome = .finished
        case .resourceReference(let reference):
            outcome = await handleResourceReference(reference, generation: generation)
        case .sessionFile(let reference):
            outcome = await openSessionFileReference(reference, generation: generation)
        case .fileLink(let payload):
            outcome = await handleFileLink(payload, generation: generation)
        case .invite:
            // accept() runs invites on their own generation; nothing reaches
            // perform with one.
            return
        }
        guard isCurrent(generation) else { return }
        if outcome == .unreachable {
            park(request)
        } else {
            activeRequest = nil
            parkedAt = nil
            didToastUnreachable = false
        }
    }

    // MARK: - Sessions

    private func performSession(
        _ open: SessionOpen,
        generation: UInt64
    ) async -> AppOpenOutcome {
        let serverId: String
        switch open.origin {
        case .inAppHyperlink:
            // A link inside Oppi knows its source server; a stale link that
            // server does not have is dropped rather than guessed.
            guard let resolved = inAppSessionServerId(for: open) else { return .finished }
            serverId = resolved
        case .externalURL:
            if let named = open.serverId {
                guard serverStore.server(for: named) != nil else {
                    // An empty pairing list means it is not readable yet (the
                    // device is locked), not that the server is gone. Keep the
                    // receipt for the next launch without toasting.
                    guard !serverStore.servers.isEmpty else { return .finished }
                    // A receipt for a removed server would otherwise toast
                    // again at every launch.
                    if let requestID = open.startedSessionRequestID {
                        intentSessionOpenTrigger.abandon(requestID: requestID)
                    }
                    toast("Server not found for this session link")
                    return .finished
                }
                serverId = named
            } else {
                guard let found = await coordinator.findOrFetchSession(id: open.sessionId) else {
                    // No paired server knows this session: the workspace root,
                    // the same landing a missing deep link always had.
                    showWorkspaceRoot()
                    return .finished
                }
                guard isCurrent(generation) else { return .finished }
                serverId = found.serverId
            }
        }

        // A self-link to the chat on screen changes nothing and runs no
        // preparation.
        if open.origin == .inAppHyperlink,
           coordinator.connection(for: serverId)?.isFocusedSession(open.sessionId) == true {
            return .finished
        }

        // A locked session (or its workspace or server) asks before Oppi
        // switches servers, so cancel leaves everything where it was. The
        // scope comes from the known session, never from a URL's workspace
        // hint: the hint is content, not lock authority. The route gate checks
        // again once the session's workspace is loaded.
        guard await scopedLock.authorize(scopedLock.sessionTarget(
            serverId: serverId,
            sessionId: open.sessionId
        )), isCurrent(generation) else { return .finished }

        let switched = await openServer(serverId, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched, let connection = coordinator.connection(for: serverId) else {
            toastUnreachableIfFirstAttempt(serverId)
            return .unreachable
        }

        consumeIntentReceiptIfNeeded(for: open, serverId: serverId, connection: connection)
        return await openPreparedSession(
            serverId: serverId,
            sessionId: open.sessionId,
            workspaceIdHint: open.workspaceId,
            connection: connection,
            origin: open.origin,
            generation: generation
        )
    }

    /// The tail every session open shares: dismiss a covering viewer, prepare
    /// the target (claim, refresh, prefetch, hydrate dialogs), then route it,
    /// whichever entry point asked. Ask cards have to appear on a push tap as
    /// on a link tap.
    func openPreparedSession(
        serverId: String,
        sessionId: String,
        workspaceIdHint: String?,
        connection: ServerConnection,
        origin: SessionNavigationSource,
        generation: UInt64
    ) async -> AppOpenOutcome {
        await FullScreenViewerPresentationPolicy.dismissCoveringOverlayThenNavigate(
            shouldNavigate: { [weak self] in self?.isCurrent(generation) ?? false },
            navigate: {}
        )
        guard isCurrent(generation) else { return .finished }

        await connection.prepareExternalSessionOpen(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint
        )
        guard isCurrent(generation) else { return .finished }

        // The route and its lock scope come from loaded session data (the
        // record, a pending ask, or a dialog), never from a URL hint.
        let workspaceId = connection.sessionReentryWorkspaceId(for: sessionId)
        // The destination lock target is the loaded workspace (never a URL
        // hint). The route gate uses the same value; asking here covers a
        // record that only became readable after the pre-switch gate, and an
        // unknown workspace still checks the session and server scopes.
        guard await scopedLock.authorize(scopedLock.sessionTarget(
            serverId: serverId,
            sessionId: sessionId,
            workspaceId: workspaceId
        )), isCurrent(generation) else { return .finished }
        navigation.selectedTab = .workspaces
        navigation.openSession(
            WorkspaceSessionNavTarget(
                serverId: serverId,
                sessionId: sessionId,
                workspaceId: workspaceId,
                routeScope: connection.sessionStore.routeScope(for: sessionId)
            ),
            source: origin
        )
        return .finished
    }

    private func inAppSessionServerId(for open: SessionOpen) -> String? {
        let matches = coordinator.connections.compactMap { serverID, connection in
            connection.sessionStore.sessions.contains(where: { $0.id == open.sessionId })
                ? serverID
                : nil
        }
        return InAppSessionServerResolution.resolve(
            sourceServerID: open.serverId,
            sourceServerHasMatch: open.serverId.map(matches.contains) ?? false,
            matchingServerIDs: matches
        )
    }

    /// Siri / Shortcuts: the durable receipt is consumed only once its server
    /// is up, so a failed open never loses the created row or unsent prompt.
    private func consumeIntentReceiptIfNeeded(
        for open: SessionOpen,
        serverId: String,
        connection: ServerConnection
    ) {
        guard let requestID = open.startedSessionRequestID,
              let receipt = intentSessionOpenTrigger.take(requestID: requestID) else {
            return
        }
        if let session = receipt.session {
            connection.sessionStore.upsert(session)
        }
        guard let prompt = receipt.unsentPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty,
              let workspaceId = receipt.workspaceId ?? open.workspaceId,
              let key = ComposerDraftKey(
                  serverID: serverId,
                  workspaceID: workspaceId,
                  sessionID: open.sessionId
              ) else {
            return
        }
        composerDraftStore.setDraft(
            ComposerDraftPayload(text: prompt, repoPointers: [], attachments: []),
            for: key
        )
    }

    private func showWorkspaceRoot() {
        navigation.selectedTab = .workspaces
        navigation.clearWorkspaceSelections()
    }

    // MARK: - Workspace creation

    private func performCreateWorkspace(
        _ payload: WorkspaceDeepLink.Payload,
        generation: UInt64
    ) async -> AppOpenOutcome {
        guard let server = workspaceDeepLinkTargetServer(for: payload) else {
            return .finished
        }
        guard await scopedLock.authorize(.server(server.id)), isCurrent(generation) else {
            return .finished
        }
        let switched = await openServer(server.id, generation: generation)
        guard isCurrent(generation) else { return .finished }
        guard switched else {
            toastUnreachableIfFirstAttempt(server.id)
            return .unreachable
        }

        // The server is resolved once, here. The shell only presents the form.
        navigation.pendingWorkspaceDeepLink = payload.resolved(on: server.id)
        navigation.showAllWorkspaceSessions()
        return .finished
    }

    private func workspaceDeepLinkTargetServer(
        for payload: WorkspaceDeepLink.Payload
    ) -> PairedServer? {
        if let fingerprint = payload.serverFingerprint {
            if let server = serverStore.servers.first(where: {
                WorkspaceDeepLink.fingerprintsMatch($0.id, fingerprint)
            }) {
                return server
            }
            toast("Server not found for this workspace link")
            return nil
        }
        if serverStore.servers.count == 1, let server = serverStore.servers.first {
            return server
        }
        if serverStore.servers.isEmpty {
            toast("Pair a server before opening workspace links")
        } else {
            toast("Workspace link needs a server fingerprint")
        }
        return nil
    }

    // MARK: - Pairing

    /// Deny from a notification action. It never waits for App Lock: the
    /// system action already required device authentication.
    func denyPairing(serverId: String, approvalId: String?) {
        guard let approvalId else { return }
        Task { @MainActor [self] in
            await denyPairingAndWait(serverId: serverId, approvalId: approvalId)
        }
    }

    /// The notification service keeps its background-task budget around this
    /// call, so deny is awaited rather than fire-and-forget.
    func denyPairingAndWait(serverId: String, approvalId: String) async {
        await PairingApprovalController.shared.performNotificationDeny(
            serverId: serverId,
            approvalId: approvalId,
            coordinator: coordinator
        )
    }

    // MARK: - Web and system

    private func presentWebLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            systemOpen(url)
            return
        }
#if DEBUG
        let mode = _browserLinkPreferenceForTesting ?? AppPreferences.Browser.linkOpeningMode
#else
        let mode = AppPreferences.Browser.linkOpeningMode
#endif
        switch mode {
        case .inApp:
            browserPresent(url)
        case .external:
            systemOpen(url)
        }
    }

    // MARK: - Toasts

    func toast(_ message: String) {
        activeConnection.extensionToast = message
    }

    func toastUnreachable(_ serverId: String) {
        let name = serverStore.server(for: serverId)?.name ?? "Server \(serverId.prefix(8))"
        toast("Could not reach \(name)")
    }

    /// A request that stays parked says it once: retries on the next
    /// foreground are silent. A launch-parked request that only later finds
    /// its server unreachable still says it once.
    func toastUnreachableIfFirstAttempt(_ serverId: String) {
        guard !didToastUnreachable else { return }
        didToastUnreachable = true
        toastUnreachable(serverId)
    }

    func resourceReferenceServerName(_ serverID: String) -> String {
        serverStore.server(for: serverID)?.name ?? "Server \(serverID.prefix(8))"
    }

#if DEBUG
    /// Awaits the work the latest open started, including a parked request
    /// that drains once the app becomes ready. Tests only.
    func _waitForOpenToSettleForTesting() async {
        for _ in 0..<8 {
            let awaited = generation
            await currentTask?.value
            await Task.yield()
            if awaited == generation { return }
        }
    }

    var _hasFinishedLaunchForTesting: Bool { hasFinishedLaunch }
    var _parkedRequestForTesting: AppOpenRequest? { parked }
#endif
}

#if DEBUG
nonisolated(unsafe) private var e2eInviteProcessedThisProcess = false
#endif

extension AppOpener {
#if DEBUG
    /// The DEBUG/E2E in-app browser hook: it is an open like any other.
    func scheduleE2EInAppBrowserIfRequested() {
        guard let url = Self.e2eInAppBrowserURL() else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            open(.webLink(url))
        }
    }

    static var e2eLaunchInviteAlreadyProcessed: Bool { e2eInviteProcessedThisProcess }

    /// Claim the E2E launch invite once per process, like the URL handler did.
    static func claimE2ELaunchInvite(_ url: URL) -> Bool {
        guard let e2eInvite = ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"],
              url.absoluteString == e2eInvite else {
            return true
        }
        guard !e2eInviteProcessedThisProcess else { return false }
        e2eInviteProcessedThisProcess = true
        return true
    }

    private static func e2eInAppBrowserURL() -> URL? {
        let rawURL = ProcessInfo.processInfo.environment["OPPI_E2E_OPEN_IN_APP_BROWSER_URL"]
            ?? ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("--e2e-open-in-app-browser=") })?
                .dropFirst("--e2e-open-in-app-browser=".count)
                .description

        guard let rawURL,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
#endif
}
