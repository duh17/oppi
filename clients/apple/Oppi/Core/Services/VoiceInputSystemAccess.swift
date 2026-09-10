@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "VoiceInput")

@MainActor
protocol VoiceInputSystemAccessing {
    var hasPermissions: Bool { get }
    var hasMicPermission: Bool { get }
    func requestPermissions() async -> Bool
    func requestMicPermission() async -> Bool
    func activateAudioSession() throws
    func deactivateAudioSession()
}

@MainActor
struct VoiceInputSystemAccess: VoiceInputSystemAccessing {
    static let live = Self()

    #if os(iOS)
    static let recordingCategory: AVAudioSession.Category = .record
    static let recordingMode: AVAudioSession.Mode = .default
    static let recordingCategoryOptions: AVAudioSession.CategoryOptions = VoiceInputAudioRoutePlanner.plan(
        availableInputs: []
    ).options
    #endif

    var hasPermissions: Bool {
        let mic = AVAudioApplication.shared.recordPermission == .granted
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        return mic && speech
    }

    var hasMicPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    func requestPermissions() async -> Bool {
        let mic = await Self.requestMicPermission()
        guard mic else { return false }

        let speech = await Self.requestSpeechPermission()
        return speech
    }

    func requestMicPermission() async -> Bool {
        await Self.requestMicPermission()
    }

    func activateAudioSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let usedBuiltInFallback = try Self.configureAndActivate(
            setCategory: { options in
                try session.setCategory(Self.recordingCategory, mode: Self.recordingMode, options: options)
            },
            setActive: { active, options in try session.setActive(active, options: options) }
        )
        // Apple requires category + mode + activation before preferred-input
        // changes. Re-read ports now, not from the previous playback session.
        var availableInputs = (session.availableInputs ?? []).map(VoiceInputAudioRouteInput.init)
        if usedBuiltInFallback || VoiceInputAudioRoutePlanner.shouldResetPreferredInput(
            preferredUID: session.preferredInput?.uid,
            availableInputs: availableInputs
        ) {
            try? session.setPreferredInput(nil)
            availableInputs = (session.availableInputs ?? []).map(VoiceInputAudioRouteInput.init)
        }
        if usedBuiltInFallback {
            availableInputs = availableInputs.filter { $0.portType == .builtInMic }
        }
        var plan = VoiceInputAudioRoutePlanner.plan(availableInputs: availableInputs)
        Self.apply(plan, to: session)
        if plan.preferredInputUID != nil,
           session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) == false,
           availableInputs.contains(where: { $0.portType == .bluetoothHFP }) {
            logger.warning("Bluetooth HFP did not become the input route; falling back to built-in mic")
            plan = VoiceInputAudioRoutePlanner.plan(
                availableInputs: VoiceInputAudioRoutePlanner.excludingBluetoothHFP(availableInputs)
            )
            Self.apply(plan, to: session)
        }
        #endif
    }

    func deactivateAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        #endif
    }

    #if os(iOS)
    /// The real configuration/activation sequence, with closures only at the
    /// hardware boundary so tests can reject category or activation separately.
    /// Bluetooth is optional: retry once with no Bluetooth category options.
    /// Returns true when the caller must prefer the built-in microphone.
    static func configureAndActivate(
        setCategory: (AVAudioSession.CategoryOptions) throws -> Void,
        setActive: (Bool, AVAudioSession.SetActiveOptions) throws -> Void
    ) throws -> Bool {
        do {
            try setCategory(recordingCategoryOptions)
            // notifyOthersOnDeactivation is only valid with active=false.
            try setActive(true, [])
            return false
        } catch {
            let failure = error as NSError
            logger.warning(
                "Dictation audio configuration failed (\(failure.domain, privacy: .public)/\(failure.code)); retrying without Bluetooth"
            )
            try? setActive(false, .notifyOthersOnDeactivation)
            try setCategory([])
            try setActive(true, [])
            return true
        }
    }

    // setPreferredPolarPattern, then setPreferredDataSource.
    private static func apply(_ plan: VoiceInputAudioRoutePlan, to session: AVAudioSession) {
        guard let uid = plan.preferredInputUID else { return }
        guard let port = session.availableInputs?.first(where: { $0.uid == uid }) else {
            logger.warning("Preferred input \(uid, privacy: .public) is not in availableInputs")
            return
        }
        do {
            try session.setPreferredInput(port)
        } catch {
            logger.warning("setPreferredInput failed: \(error.localizedDescription, privacy: .public)")
        }

        guard let dataSourceName = plan.preferredDataSourceName else { return }
        let resolvedPort = session.preferredInput ?? port
        guard let dataSource = resolvedPort.dataSources?.first(where: {
            $0.dataSourceName == dataSourceName
        }) else {
            logger.warning(
                "Preferred data source \(dataSourceName, privacy: .public) is not available"
            )
            return
        }
        if let polar = plan.preferredPolarPattern {
            do {
                try dataSource.setPreferredPolarPattern(polar)
            } catch {
                logger.warning(
                    "setPreferredPolarPattern failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        do {
            try resolvedPort.setPreferredDataSource(dataSource)
        } catch {
            logger.warning(
                "setPreferredDataSource failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif

    nonisolated private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated private static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
