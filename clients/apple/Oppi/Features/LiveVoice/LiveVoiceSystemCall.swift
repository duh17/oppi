@preconcurrency import AVFoundation
import CallKit
import Foundation
import Observation

/// What `LiveVoiceSystemCall` needs from CallKit: the provider's reports, the call
/// controller's requests, and the provider delegate's callbacks (`events`), on the main actor.
/// `CallKitLiveVoiceTelephony` is the real one; tests drive a fake.
@MainActor
protocol LiveVoiceTelephony: AnyObject {
    var events: LiveVoiceTelephonyEvents? { get set }
    /// `CXCallController.request`: the system answers by performing the action (`events`).
    func request(_ action: CXCallAction) async throws
    func reportConnecting(call: UUID)
    func reportConnected(call: UUID)
    func reportUpdate(call: UUID, displayName: String)
    func reportEnded(call: UUID, reason: CXCallEndedReason)
}

/// A call action the system performs, whether the app or the system asked for it.
enum LiveVoiceSystemAction: Equatable {
    case start(call: UUID)
    case end(call: UUID)
    case setMuted(call: UUID, muted: Bool)
    case setHeld(call: UUID, onHold: Bool)
}

@MainActor
protocol LiveVoiceTelephonyEvents: AnyObject {
    /// True fulfills the action, false fails it.
    func perform(_ action: LiveVoiceSystemAction) -> Bool
    func audioSessionDidActivate()
    func audioSessionDidDeactivate()
    func providerDidReset()
}

/// The app's Live Voice call as a system call: CallKit shows it (the status bar and Dynamic
/// Island call indicator, the in-call UI), and the two sides drive each other. There is at most
/// one, the `LiveVoiceCallCenter` call it was started for.
///
/// - Start: `start` (after `LiveVoiceCallController.prepareStart`) asks CallKit for an outgoing
///   call, then starts the app's call. The system shows it connecting at once and connected when
///   the server confirms the call. When CallKit
///   refuses (another call, a policy, no CallKit here), the app's call starts anyway without
///   it and activates its own audio session: Live Voice never fails because the system call did.
/// - End: the system's End ends the app's call. The app's End hangs up the system call with an
///   end action; a call the server ended is reported as the other side hanging up, and a
///   failed or dropped call as failed.
/// - Mute: every mute the system performs is the call's mute, whoever asked for it: its UI, a
///   headset or AirPods gesture, or the app, whose mute asks the system for the same mute. The
///   app asks only when its mute differs from the system's last one, so a perform never echoes
///   back, and when performs cross the last one wins on both sides.
/// - Hold and audio: the call's audio runs only while CallKit has the audio session active and
///   the call is not on hold. A phone call answered over it holds it: the mic and playback stop
///   and the server call stays up with its keepalive; unhold resumes them. A session the system
///   never activates (after the start, or after unhold) fails the call with the reason.
///
/// The system UI shows the session's title, or "Live Voice" for a session the scoped locks
/// keep out of notifications. Nothing else about the session is handed to CallKit, and calls
/// stay out of Recents.
@MainActor
final class LiveVoiceSystemCall: LiveVoiceTelephonyEvents {
    static let lockedDisplayName = "Live Voice"

    private struct Active {
        let id: UUID
        let controller: LiveVoiceCallController
        let key: LiveVoiceCallCenter.CallKey
        var displayName: String
        var reportedConnected = false
        /// What the system last knew: the mute it performed, or the one the app asked for.
        var systemMuted = false
        var watch: Task<Void, Never>?
        /// CallKit has the call's audio session active.
        var audioActive = false
        /// Fails the call when the activation never comes.
        var activationDeadline: Task<Void, Never>?
    }

    /// Shown on the call surface when the system never gave the call its audio.
    static let noAudioText = "Live Voice couldn't get audio from iOS. Try again; if it keeps happening, quit and reopen Oppi."

    private var active: Active?
    private let makeTelephony: @MainActor () -> LiveVoiceTelephony?
    private var madeTelephony = false
    private var telephonyInstance: LiveVoiceTelephony?
    private let displayName: @MainActor @Sendable (LiveVoiceCallCenter.CallKey) -> String
    private let configureAudioSession: @MainActor () throws -> Void
    private let activationTimeout: Duration

    /// - Parameters:
    ///   - telephony: made on the first call, so the provider exists only once Live Voice is used.
    ///   - displayName: what the system UI calls the session; read again whenever it may change.
    ///   - activationTimeout: how long after the start action the system may take to activate
    ///     the audio session before the call fails instead of staying live and silent.
    init(
        telephony: @escaping @MainActor () -> LiveVoiceTelephony? = { CallKitLiveVoiceTelephony.make() },
        displayName: @escaping @MainActor @Sendable (LiveVoiceCallCenter.CallKey) -> String,
        configureAudioSession: @escaping @MainActor () throws -> Void = { try LiveVoiceDuplexCaptureEngine.configureSession() },
        activationTimeout: Duration = .seconds(5)
    ) {
        makeTelephony = telephony
        self.displayName = displayName
        self.configureAudioSession = configureAudioSession
        self.activationTimeout = activationTimeout
    }

    /// Previews and tests: every call starts without CallKit.
    static func withoutCallKit() -> LiveVoiceSystemCall {
        LiveVoiceSystemCall(telephony: { nil }, displayName: { _ in lockedDisplayName })
    }

    private var telephony: LiveVoiceTelephony? {
        if !madeTelephony {
            madeTelephony = true
            telephonyInstance = makeTelephony()
            telephonyInstance?.events = self
        }
        return telephonyInstance
    }

    /// The system call's id while one is up.
    var callId: UUID? { active?.id }

    /// Starts `controller`'s call (`run`) as a system call, or without one when CallKit refuses.
    /// Returns once the app's call is confirmed, failed, or ended.
    func start(
        _ controller: LiveVoiceCallController,
        key: LiveVoiceCallCenter.CallKey,
        run: @MainActor () async -> Void
    ) async {
        if let stale = active {
            // The last call ended and its watch has not caught up yet.
            finish(stale)
        }
        guard let telephony else {
            await runWithoutSystemCall(controller, reason: "unavailable", run: run)
            return
        }
        let id = UUID()
        let name = displayName(key)
        active = Active(id: id, controller: controller, key: key, displayName: name)
        // The audio waits for CallKit to activate the session.
        controller.useSystemAudioSession(true)
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
        action.isVideo = false
        do {
            try await telephony.request(action)
        } catch {
            if active?.id == id { active = nil }
            await runWithoutSystemCall(controller, reason: "refused", error: error, run: run)
            return
        }
        // The system ended or reset the call during the request: it never starts.
        guard let requested = active, requested.id == id else { return }
        // End in the app during the request: hang up the call it asked for.
        guard controller.isStarting else {
            finish(requested)
            return
        }
        await run()
        guard let call = active, call.id == id else { return }
        guard controller.isLive else {
            finish(call)
            return
        }
        watch(call)
    }

    private func runWithoutSystemCall(
        _ controller: LiveVoiceCallController,
        reason: String,
        error: Error? = nil,
        run: @MainActor () async -> Void
    ) async {
        var metadata = ["reason": reason]
        if let error {
            metadata["error_domain"] = (error as NSError).domain
            metadata["error_code"] = String((error as NSError).code)
        }
        // End in the app while CallKit was asked: nothing to start.
        guard controller.isStarting else { return }
        ClientLog.warning("LiveVoice", "Call starts without CallKit", metadata: metadata)
        controller.useSystemAudioSession(false)
        await run()
    }

    /// Follows the app's call until it ends: connected, mute, a changed title or lock, the end.
    private func watch(_ call: Active) {
        let id = call.id
        let controller = call.controller
        let key = call.key
        let displayName = displayName
        let states = Observations { @MainActor in
            WatchedState(
                isLive: controller.isLive,
                isMuted: controller.isMuted,
                isConfirmed: controller.callState?.lifecycle == .active,
                displayName: displayName(key)
            )
        }
        active?.watch = Task { [weak self] in
            for await state in states {
                guard let self, self.active?.id == id else { return }
                if !self.apply(state) { return }
            }
        }
    }

    private struct WatchedState: Equatable, Sendable {
        var isLive: Bool
        var isMuted: Bool
        var isConfirmed: Bool
        var displayName: String
    }

    /// False once the call is over.
    private func apply(_ state: WatchedState) -> Bool {
        guard var call = active, let telephony else { return false }
        guard state.isLive else {
            finish(call)
            return false
        }
        if state.isConfirmed, !call.reportedConnected {
            call.reportedConnected = true
            telephony.reportConnected(call: call.id)
        }
        if state.displayName != call.displayName {
            call.displayName = state.displayName
            telephony.reportUpdate(call: call.id, displayName: state.displayName)
        }
        active = call
        if state.isMuted != call.systemMuted {
            requestMute(state.isMuted, call: call)
        }
        return true
    }

    private func requestMute(_ muted: Bool, call: Active) {
        guard let telephony else { return }
        let action = CXSetMutedCallAction(call: call.id, muted: muted)
        let previous = call.systemMuted
        active?.systemMuted = muted
        let id = call.id
        Task { [weak self] in
            do {
                try await telephony.request(action)
            } catch {
                ClientLog.warning("LiveVoice", "CallKit mute request failed", metadata: [
                    "error_domain": (error as NSError).domain,
                    "error_code": String((error as NSError).code),
                ])
                // The system kept its mute; a later change of the app's asks again.
                guard let self, self.active?.id == id, self.active?.systemMuted == muted else { return }
                self.active?.systemMuted = previous
            }
        }
    }

    /// The system call is over on this side: stop following it.
    private func release(_ call: Active) {
        if active?.id == call.id { active = nil }
        call.watch?.cancel()
        call.activationDeadline?.cancel()
    }

    /// The app's call is over: hang up the system call with the reason it ended.
    private func finish(_ call: Active) {
        release(call)
        guard let telephony else { return }
        switch call.controller.lastError {
        case nil:
            // The person pressed End in the app: the system hangs up the same way as its own End.
            let id = call.id
            Task {
                do {
                    try await telephony.request(CXEndCallAction(call: id))
                } catch {
                    telephony.reportEnded(call: id, reason: .remoteEnded)
                }
            }
        case LiveVoiceCallController.endedText?:
            telephony.reportEnded(call: call.id, reason: .remoteEnded)
        default:
            telephony.reportEnded(call: call.id, reason: .failed)
        }
    }

    // MARK: LiveVoiceTelephonyEvents

    func perform(_ action: LiveVoiceSystemAction) -> Bool {
        switch action {
        case .start(let id):
            guard let call = active, call.id == id else { return false }
            // CallKit activates the session after this; it must already have the call's
            // category (Apple's "Making and receiving VoIP calls").
            do {
                try configureAudioSession()
            } catch {
                ClientLog.warning("LiveVoice", "Audio session configuration failed", metadata: [
                    "error_domain": (error as NSError).domain,
                    "error_code": String((error as NSError).code),
                ])
            }
            telephony?.reportUpdate(call: id, displayName: call.displayName)
            telephony?.reportConnecting(call: id)
            armActivationDeadline(for: id)
            return true
        case .end(let id):
            // An end for a call already gone (the app hung up first) has nothing left to do.
            guard let call = active, call.id == id else { return true }
            release(call)
            call.controller.stopStarting()
            Task { await call.controller.end() }
            return true
        case .setMuted(let id, let muted):
            guard let call = active, call.id == id else { return false }
            // Authoritative whoever asked: the app's own request lands as a no-op.
            active?.systemMuted = muted
            call.controller.setMuted(muted)
            return true
        case .setHeld(let id, let onHold):
            guard let call = active, call.id == id else { return false }
            call.controller.setOnHold(onHold)
            if onHold {
                // A held call has no audio by design.
                active?.activationDeadline?.cancel()
                active?.activationDeadline = nil
            } else if !call.audioActive {
                // Unhold: the system gives the session back, or the call fails with the reason.
                armActivationDeadline(for: id)
            }
            return true
        }
    }

    func audioSessionDidActivate() {
        active?.audioActive = true
        active?.activationDeadline?.cancel()
        active?.activationDeadline = nil
        active?.controller.setAudioSessionActive(true)
    }

    /// The system activates the session soon after the start action is fulfilled, and again
    /// after unhold. When it never does (a stale audio session ID in callservicesd, Apple DTS in
    /// forums thread 837211), the call would sit live and silent: fail it with the reason instead.
    private func armActivationDeadline(for id: UUID) {
        let timeout = activationTimeout
        active?.activationDeadline?.cancel()
        active?.activationDeadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let call = self.active, call.id == id,
                  !call.audioActive, !call.controller.isOnHold else { return }
            ClientLog.warning("LiveVoice", "CallKit never activated the audio session", metadata: [
                "timeout": String(describing: timeout),
            ], flush: true)
            // Not cancelled by the release below: the end it sends must still go out.
            var expired = call
            expired.activationDeadline = nil
            self.release(expired)
            self.telephony?.reportEnded(call: id, reason: .failed)
            await call.controller.end(failing: Self.noAudioText)
        }
    }

    func audioSessionDidDeactivate() {
        active?.audioActive = false
        active?.controller.setAudioSessionActive(false)
    }

    /// The system dropped every call: the app's call ends too.
    func providerDidReset() {
        guard let call = active else { return }
        release(call)
        call.controller.stopStarting()
        Task { await call.controller.end() }
    }
}

extension LiveVoiceSystemCall {
    /// The session's title for the system call UI, or "Live Voice" while a scoped lock keeps
    /// the session's text out of notifications and Live Activities: the in-call UI shows on
    /// the Lock Screen too.
    static func displayName(
        for key: LiveVoiceCallCenter.CallKey,
        locks: ScopedLockService,
        session: Session?
    ) -> String {
        let target = locks.sessionTarget(
            serverId: key.serverId,
            sessionId: key.sessionId,
            workspaceId: session?.workspaceId
        )
        guard !locks.hidesContentOutsideApp(target), let session else { return lockedDisplayName }
        return session.displayTitle
    }
}

/// CallKit's provider and call controller for `LiveVoiceSystemCall`: one provider for the app,
/// for one audio call with a generic handle and no Recents entry. The system names the call's
/// app with the bundle's display name (Oppi); `CXProviderConfiguration(localizedName:)` is
/// deprecated since iOS 14.
@MainActor
final class CallKitLiveVoiceTelephony: NSObject, LiveVoiceTelephony, CXProviderDelegate {
    weak var events: LiveVoiceTelephonyEvents?
    private let provider: CXProvider
    private let callController = CXCallController()

    /// Nil in the Simulator, which has no call service: every request there fails with
    /// NSCocoaErrorDomain 4099 ("Couldn't communicate with a helper application") and the
    /// provider resets. Live Voice runs without CallKit instead.
    static func make() -> LiveVoiceTelephony? {
        #if targetEnvironment(simulator)
        nil
        #else
        CallKitLiveVoiceTelephony()
        #endif
    }

    private override init() {
        provider = CXProvider(configuration: Self.configuration())
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    private static func configuration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        return configuration
    }

    func request(_ action: CXCallAction) async throws {
        if action is CXStartCallAction {
            // Setting the configuration hands callservicesd the app's current audio session
            // ID. A stale one leaves it unable to activate the session (no didActivate) for
            // every later call; Apple DTS's workaround is to set it before each call
            // (developer.apple.com/forums/thread/837211).
            provider.configuration = Self.configuration()
        }
        let transaction = CXTransaction(action: action)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func reportConnecting(call: UUID) {
        provider.reportOutgoingCall(with: call, startedConnectingAt: nil)
    }

    func reportConnected(call: UUID) {
        provider.reportOutgoingCall(with: call, connectedAt: nil)
    }

    func reportUpdate(call: UUID, displayName: String) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: displayName)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsHolding = true
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportCall(with: call, updated: update)
    }

    func reportEnded(call: UUID, reason: CXCallEndedReason) {
        provider.reportCall(with: call, endedAt: nil, reason: reason)
    }

    // MARK: CXProviderDelegate (main queue)

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { events?.providerDidReset() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        complete(action, .start(call: action.callUUID))
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        complete(action, .end(call: action.callUUID))
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        complete(action, .setMuted(call: action.callUUID, muted: action.isMuted))
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        complete(action, .setHeld(call: action.callUUID, onHold: action.isOnHold))
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { events?.audioSessionDidActivate() }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { events?.audioSessionDidDeactivate() }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        let kind = String(describing: type(of: action))
        MainActor.assumeIsolated {
            ClientLog.warning("LiveVoice", "CallKit action timed out", metadata: ["action": kind])
        }
    }

    private nonisolated func complete(_ action: CXAction, _ systemAction: LiveVoiceSystemAction) {
        let performed = MainActor.assumeIsolated { events?.perform(systemAction) == true }
        if performed {
            action.fulfill()
        } else {
            action.fail()
        }
    }
}
