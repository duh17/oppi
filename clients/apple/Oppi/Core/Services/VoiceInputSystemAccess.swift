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
    func activateAudioSession(inAppPlaybackActive: Bool) throws
    func activateBuiltInAudioSession(inAppPlaybackActive: Bool) throws
    func deactivateAudioSession()
}

@MainActor
struct VoiceInputSystemAccess: VoiceInputSystemAccessing {
    static let live = Self()

    #if os(iOS)
    // HFP couples input and output. Record-only produced a valid 24 kHz
    // AirPods input but a 0 Hz output and AURemoteIO start failure on device.
    static let recordingCategory: AVAudioSession.Category = .playAndRecord
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

    func activateAudioSession(inAppPlaybackActive: Bool) throws {
        try activateAudioSession(preferBuiltIn: false, inAppPlaybackActive: inAppPlaybackActive)
    }

    func activateBuiltInAudioSession(inAppPlaybackActive: Bool) throws {
        try activateAudioSession(preferBuiltIn: true, inAppPlaybackActive: inAppPlaybackActive)
    }

    private func activateAudioSession(preferBuiltIn: Bool, inAppPlaybackActive: Bool) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Snapshot before changing category: once HFP is offered it outranks A2DP,
        // erasing the signal that media was already playing through AirPods.
        let preserveA2DPOutput = Self.shouldPreserveA2DPOutput(
            hasA2DPOutput: session.currentRoute.outputs.contains { $0.portType == .bluetoothA2DP },
            externalAudioPlaying: session.isOtherAudioPlaying,
            inAppPlaybackActive: inAppPlaybackActive
        )
        let usedBuiltInFallback = try Self.configureAndActivate(
            preferBuiltIn: preferBuiltIn,
            preserveA2DPOutput: preserveA2DPOutput,
            setCategory: { category, mode, options in
                try session.setCategory(category, mode: mode, options: options)
            },
            setActive: { active, options in try session.setActive(active, options: options) },
            setAllowHaptics: { try session.setAllowHapticsAndSystemSoundsDuringRecording($0) }
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
            // Restore the pre-routing-feature capture path: measurement mode,
            // primary built-in mic, no front/cardioid request. Applying the
            // normal planner here would immediately reapply the failing route.
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                for source in builtIn.dataSources ?? [] where source.preferredPolarPattern != nil {
                    try? source.setPreferredPolarPattern(nil)
                }
                try? builtIn.setPreferredDataSource(nil)
                try session.setPreferredInput(builtIn)
            }
            return
        }
        let plan = VoiceInputAudioRoutePlanner.plan(
            availableInputs: availableInputs,
            preserveA2DPOutput: preserveA2DPOutput
        )
        Self.apply(plan, to: session)
        ClientLog.info("VoiceInput", "Dictation audio session activated", metadata: [
            "preserve_a2dp": preserveA2DPOutput ? "1" : "0",
            "preferred_input_port": plan.preferredInputUID.flatMap { uid in
                availableInputs.first(where: { $0.uid == uid })?.portType.rawValue
            } ?? "system",
            "input_ports": session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ","),
            "output_ports": session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","),
        ])
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
    static func shouldPreserveA2DPOutput(
        hasA2DPOutput: Bool,
        externalAudioPlaying: Bool,
        inAppPlaybackActive: Bool
    ) -> Bool {
        hasA2DPOutput && (externalAudioPlaying || inAppPlaybackActive)
    }

    /// The real configuration/activation sequence, with closures only at the
    /// hardware boundary so tests can reject category or activation separately.
    /// Bluetooth is optional: retry once with no Bluetooth category options.
    /// Returns true when the caller must prefer the built-in microphone.
    static func configureAndActivate(
        preferBuiltIn: Bool = false,
        preserveA2DPOutput: Bool = false,
        setCategory: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) throws -> Void,
        setActive: (Bool, AVAudioSession.SetActiveOptions) throws -> Void,
        setAllowHaptics: (Bool) throws -> Void = { _ in }
    ) throws -> Bool {
        // iOS suppresses feedback during recording by default. Permission to
        // play it is separate from AppHaptics' user preference; never let an
        // optional feedback failure prevent microphone capture.
        do {
            try setAllowHaptics(true)
        } catch {
            logger.warning("Could not enable recording haptics: \(error.localizedDescription, privacy: .public)")
        }
        let plannedOptions = VoiceInputAudioRoutePlanner.plan(
            availableInputs: [],
            preserveA2DPOutput: preserveA2DPOutput
        ).options
        let fallbackOptions = VoiceInputAudioRoutePlanner.builtInFallbackOptions(
            preserveA2DPOutput: preserveA2DPOutput
        )
        do {
            try setCategory(
                recordingCategory,
                preferBuiltIn ? .measurement : recordingMode,
                preferBuiltIn ? fallbackOptions : plannedOptions
            )
            // notifyOthersOnDeactivation is only valid with active=false.
            try setActive(true, [])
            return preferBuiltIn
        } catch {
            guard !preferBuiltIn else { throw error }
            let failure = error as NSError
            logger.warning(
                "Dictation audio configuration failed (\(failure.domain, privacy: .public)/\(failure.code)); retrying without HFP"
            )
            // Do not deactivate between attempts. Capture may be joining a
            // session that already has mixed playback; deactivation would stop
            // that surviving player before the built-in retry.
            try setCategory(recordingCategory, .measurement, fallbackOptions)
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
