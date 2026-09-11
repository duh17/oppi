@preconcurrency import AVFoundation
import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "VoiceInput")

/// On-device speech-to-text using `SpeechAnalyzer` (iOS 26+).
///
/// Prefers Apple's general-purpose `SpeechTranscriber` and falls back to
/// `DictationTranscriber` when the newer model is unavailable for the current
/// device or locale. Both engines stream progressive results. `SpeechTranscriber`
/// keeps volatile partials and omits `fastResults` so long takes keep full context.
///
/// **Language detection:** By default, follows the active keyboard language
/// at mic-tap time (Chinese keyboard → Chinese model, English keyboard →
/// English model). Users can override to a specific locale in Settings.
///
/// Results are either **volatile** (immediate rough guesses that update
/// as more context arrives) or **finalized** (accurate, won't change).
/// The manager accumulates finalized text and replaces the volatile
/// portion on each update, exposing a combined `currentTranscript`.
///
/// **Key design: transcribers are never reused.** A speech transcriber
/// becomes invalid after its analyzer is finalized. We create a fresh
/// pair for each recording session. Pre-warming only checks model
/// availability and caches the audio format.
///
/// Audio engine setup is extracted to a `nonisolated` helper to avoid
/// MainActor isolation violations in the audio tap callback.
@MainActor
protocol VoicePlaybackInterrupter: AnyObject {
    var hasActivePlayback: Bool { get }
    func stop()
}

/// Hardware playback gate used by dictation startup.
///
/// This intentionally excludes presentation-only coordinators. Voice input needs
/// the concrete playback owner so it can block late voice-card autoplay and
/// streaming chunks for the whole capture window.
@MainActor
protocol VoicePlaybackCaptureCoordinating: AnyObject {
    /// Item ownership can outlive audible playback (paused/loading UI).
    var hasActivePlayback: Bool { get }
    /// True only while audio is playing or waiting with nonzero playback intent.
    var isPlaybackActiveForCapture: Bool { get }
    func beginCaptureInterruption()
    func endCaptureInterruption()
}

/// Visible composer that owns the shared dictation manager.
/// Hint refresh never claims this; only explicit activation does.
struct VoiceComposerOwner: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case conversation(sessionId: String)
        case standalone
    }

    let serverId: String
    let kind: Kind
}

/// Identity of one capture take. `composerGeneration` is the owner at start,
/// not whoever later claims the shared manager.
struct VoiceCaptureTakeIdentity: Equatable, Sendable {
    let requestID: Int
    let composerGeneration: Int
}

struct VoiceCaptureFailure: Equatable, Sendable {
    let take: VoiceCaptureTakeIdentity
    let source: String
    let message: String
}

@MainActor @Observable
final class VoiceInputManager {

    // MARK: - Types

    enum State: Equatable, Sendable {
        case idle
        case preparingModel
        case recording
        case processing
        case error(String)
    }

    enum TranscriptionEngine: String, Equatable, Sendable {
        case modernSpeech
        case classicDictation
        case serverDictation

        var logName: String {
            switch self {
            case .modernSpeech: return "speech"
            case .classicDictation: return "dictation"
            case .serverDictation: return "server"
            }
        }
    }

    enum EngineMode: String, Equatable, Sendable {
        case auto
        case onDevice
        case remote

        var logName: String {
            switch self {
            case .auto: return "auto"
            case .onDevice: return "on_device"
            case .remote: return "remote"
            }
        }
    }

    enum RouteIndicator: Equatable, Sendable {
        case auto
        case onDevice
        case remote

        var accessibilityLabel: String {
            switch self {
            case .auto: return "Automatic"
            case .onDevice: return "On-device"
            case .remote: return "Server"
            }
        }
    }

    /// Yuwp-style preview split for full-replacement transcript updates.
    /// Everything after `committedText` stays visually volatile until the next
    /// segment commit (`snap`) settles it.
    private struct ReplaceTranscriptState {
        var committedText = ""
        var activeText = ""
        /// Best-known settled prefix carried across later corrections.
        /// Stored as text, not a raw count, so boundary protection survives
        /// word merges/splits and other length-changing corrections.
        private var protectedCommittedText = ""

        var isTracking: Bool {
            !committedText.isEmpty || !activeText.isEmpty
        }

        mutating func reset() {
            committedText = ""
            activeText = ""
            protectedCommittedText = ""
        }

        mutating func applyReplacement(
            fullText: String,
            snap: Bool,
            explicitCommittedText: String? = nil,
            explicitActiveText: String? = nil
        ) {
            let trimmedFullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFullText.isEmpty else {
                reset()
                return
            }

            if snap {
                committedText = trimmedFullText
                activeText = ""
                protectedCommittedText = trimmedFullText
                return
            }

            let trimmedCommitted = explicitCommittedText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedActive = explicitActiveText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let protectedBoundary = Self.inferredProtectedBoundary(
                in: trimmedFullText,
                protectedText: protectedCommittedText
            )

            if explicitCommittedText != nil || explicitActiveText != nil,
               let boundary = Self.boundaryFromExplicitSplit(
                    in: trimmedFullText,
                    explicitCommittedText: trimmedCommitted,
                    explicitActiveText: trimmedActive,
                    protectedBoundary: protectedBoundary
               ) {
                applyBoundary(boundary, in: trimmedFullText)
                return
            }

            if let boundary = Self.boundaryFromCommittedPrefix(
                in: trimmedFullText,
                committedText: committedText,
                protectedBoundary: protectedBoundary
            ) {
                applyBoundary(boundary, in: trimmedFullText)
                return
            }

            if let boundary = protectedBoundary {
                applyBoundary(boundary, in: trimmedFullText)
                return
            }

            committedText = ""
            activeText = trimmedFullText
        }

        func visibleActiveSuffixLength(in displayText: String) -> Int {
            guard isTracking else { return 0 }
            let trimmedDisplayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedDisplayText.isEmpty else { return 0 }

            let committedPrefixLength = committedVisiblePrefixLength(in: trimmedDisplayText)
            return max(0, trimmedDisplayText.count - committedPrefixLength)
        }

        func committedVisiblePrefixLength(in displayText: String) -> Int {
            guard !displayText.isEmpty, !committedText.isEmpty else { return 0 }
            var boundary = min(displayText.count, Self.commonPrefixCount(displayText, committedText))

            if !activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               boundary < displayText.count {
                let index = displayText.index(displayText.startIndex, offsetBy: boundary)
                if Self.isWhitespace(displayText[index]) {
                    boundary = min(displayText.count, boundary + 1)
                }
            }

            return boundary
        }

        private mutating func applyBoundary(_ boundary: Int, in fullText: String) {
            let clampedBoundary = max(0, min(boundary, fullText.count))
            let boundaryIndex = fullText.index(fullText.startIndex, offsetBy: clampedBoundary)
            committedText = String(fullText[..<boundaryIndex])

            var activeStart = boundaryIndex
            if activeStart < fullText.endIndex, Self.isWhitespace(fullText[activeStart]) {
                activeStart = fullText.index(after: activeStart)
            }
            activeText = String(fullText[activeStart...])

            if !committedText.isEmpty {
                protectedCommittedText = committedText
            }
        }

        private static func boundaryFromExplicitSplit(
            in fullText: String,
            explicitCommittedText: String?,
            explicitActiveText: String?,
            protectedBoundary: Int?
        ) -> Int? {
            let minimumBoundary = protectedBoundary ?? 0

            if let activeText = explicitActiveText,
               !activeText.isEmpty,
               let activeBoundary = boundaryFromActiveSuffix(in: fullText, activeText: activeText) {
                return max(minimumBoundary, activeBoundary)
            }

            if let committedText = explicitCommittedText,
               !committedText.isEmpty,
               let committedBoundary = bestPrefixBoundary(for: committedText, in: fullText) {
                return max(minimumBoundary, committedBoundary)
            }

            if minimumBoundary > 0 {
                return minimumBoundary
            }

            return nil
        }

        private static func boundaryFromCommittedPrefix(
            in fullText: String,
            committedText: String,
            protectedBoundary: Int?
        ) -> Int? {
            let trimmedCommitted = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommitted.isEmpty else { return protectedBoundary }
            guard let boundary = bestPrefixBoundary(for: trimmedCommitted, in: fullText) else {
                return protectedBoundary
            }
            if let protectedBoundary {
                return max(boundary, protectedBoundary)
            }
            return boundary
        }

        private static func boundaryFromActiveSuffix(in fullText: String, activeText: String) -> Int? {
            guard !activeText.isEmpty, fullText.hasSuffix(activeText) else { return nil }
            let activeStart = fullText.index(fullText.endIndex, offsetBy: -activeText.count)
            if activeStart > fullText.startIndex {
                let previous = fullText.index(before: activeStart)
                if isWhitespace(fullText[previous]) {
                    return fullText.distance(from: fullText.startIndex, to: previous)
                }
            }
            return fullText.distance(from: fullText.startIndex, to: activeStart)
        }

        private static func inferredProtectedBoundary(in fullText: String, protectedText: String) -> Int? {
            let trimmedProtected = protectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedProtected.isEmpty else { return nil }
            return bestPrefixBoundary(for: trimmedProtected, in: fullText)
        }

        private static func bestPrefixBoundary(for targetText: String, in fullText: String) -> Int? {
            guard !targetText.isEmpty, !fullText.isEmpty else { return nil }

            if fullText == targetText {
                return fullText.count
            }

            let separator = targetText + " "
            if fullText.hasPrefix(separator) {
                return targetText.count
            }

            if let tokenBoundary = bestTokenPrefixBoundary(for: targetText, in: fullText) {
                return tokenBoundary
            }

            return bestCharacterPrefixBoundary(for: targetText, in: fullText)
        }

        private static func bestCharacterPrefixBoundary(for targetText: String, in fullText: String) -> Int? {
            let target = Array(targetText)
            let full = Array(fullText)
            var previous = Array(0...full.count)
            var current = Array(repeating: 0, count: full.count + 1)

            for (i, targetCharacter) in target.enumerated() {
                current[0] = i + 1
                for (j, fullCharacter) in full.enumerated() {
                    let substitutionCost = targetCharacter == fullCharacter ? 0 : 1
                    current[j + 1] = min(
                        previous[j + 1] + 1,
                        current[j] + 1,
                        previous[j] + substitutionCost
                    )
                }
                swap(&previous, &current)
            }

            var bestBoundary: Int?
            var bestDistance = Int.max
            var bestSimilarity = -Double.infinity

            for boundary in 0...full.count {
                let distance = previous[boundary]
                let denominator = max(target.count, boundary, 1)
                let similarity = 1 - (Double(distance) / Double(denominator))
                let isBetter = distance < bestDistance
                    || (distance == bestDistance && similarity > bestSimilarity)
                    || (distance == bestDistance && similarity == bestSimilarity
                        && boundary > (bestBoundary ?? 0))
                if isBetter {
                    bestBoundary = boundary
                    bestDistance = distance
                    bestSimilarity = similarity
                }
            }

            guard let bestBoundary, bestSimilarity >= 0.6 else { return nil }
            return bestBoundary
        }

        private struct WordToken {
            let text: String
            let boundary: Int
        }

        private static func bestTokenPrefixBoundary(for targetText: String, in fullText: String) -> Int? {
            let targetTokens = wordTokens(in: targetText)
            let fullTokens = wordTokens(in: fullText)
            guard !targetTokens.isEmpty, !fullTokens.isEmpty else { return nil }

            var previous = Array(0...fullTokens.count)
            var current = Array(repeating: 0, count: fullTokens.count + 1)

            for (i, targetToken) in targetTokens.enumerated() {
                current[0] = i + 1
                for (j, fullToken) in fullTokens.enumerated() {
                    let substitutionCost = targetToken.text == fullToken.text ? 0 : 1
                    current[j + 1] = min(
                        previous[j + 1] + 1,
                        current[j] + 1,
                        previous[j] + substitutionCost
                    )
                }
                swap(&previous, &current)
            }

            var bestBoundary: Int?
            var bestDistance = Int.max
            var bestSimilarity = -Double.infinity

            for tokenCount in 1...fullTokens.count {
                let distance = previous[tokenCount]
                let denominator = max(targetTokens.count, tokenCount, 1)
                let similarity = 1 - (Double(distance) / Double(denominator))
                let boundary = fullTokens[tokenCount - 1].boundary
                let isBetter = distance < bestDistance
                    || (distance == bestDistance && similarity > bestSimilarity)
                    || (distance == bestDistance && similarity == bestSimilarity
                        && boundary > (bestBoundary ?? 0))
                if isBetter {
                    bestBoundary = boundary
                    bestDistance = distance
                    bestSimilarity = similarity
                }
            }

            guard let bestBoundary, bestSimilarity >= 0.65 else { return nil }
            return bestBoundary
        }

        private static func wordTokens(in text: String) -> [WordToken] {
            let nsText = text as NSString
            var tokens: [WordToken] = []

            text.enumerateSubstrings(
                in: text.startIndex..<text.endIndex,
                options: [.byWords, .substringNotRequired]
            ) { _, substringRange, _, _ in
                let nsRange = NSRange(substringRange, in: text)
                let tokenText = nsText.substring(with: nsRange).lowercased()
                let boundary = nsRange.location + nsRange.length
                tokens.append(WordToken(text: tokenText, boundary: boundary))
            }

            return tokens
        }

        private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
            var count = 0
            var leftIndex = lhs.startIndex
            var rightIndex = rhs.startIndex

            while leftIndex < lhs.endIndex,
                  rightIndex < rhs.endIndex,
                  lhs[leftIndex] == rhs[rightIndex] {
                count += 1
                leftIndex = lhs.index(after: leftIndex)
                rightIndex = rhs.index(after: rightIndex)
            }

            return count
        }

        private static func isWhitespace(_ character: Character) -> Bool {
            character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
    }

    // MARK: - Published State

    private(set) var state: State = .idle
    private(set) var captureFailure: VoiceCaptureFailure?
    var currentComposerCaptureFailure: VoiceCaptureFailure? {
        guard captureFailure?.take.composerGeneration == composerGeneration else { return nil }
        return captureFailure
    }
    @ObservationIgnored private var captureFailureHandler: (@MainActor () -> Void)?
    private struct CaptureReleaseObserver {
        let isPlaybackActive: @MainActor () -> Bool
        let restorePlaybackSession: @MainActor () -> Bool
    }
    @ObservationIgnored private var captureReleaseObservers: [UUID: CaptureReleaseObserver] = [:]
    @ObservationIgnored private(set) var composerStartupID: UUID?

    /// A composer attempt starts before its async preparation. Keep its identity
    /// on the shared owner so inline/expanded handoff cannot revive old cleanup.
    func beginComposerStartup() throws -> UUID {
        try validateStartAdmission()
        let id = UUID()
        composerStartupID = id
        return id
    }

    func observeCaptureRelease(
        isPlaybackActive: @escaping @MainActor () -> Bool,
        restorePlaybackSession: @escaping @MainActor () -> Bool
    ) -> UUID {
        let id = UUID()
        captureReleaseObservers[id] = CaptureReleaseObserver(
            isPlaybackActive: isPlaybackActive,
            restorePlaybackSession: restorePlaybackSession
        )
        return id
    }

    func removeCaptureReleaseObserver(_ id: UUID) {
        captureReleaseObservers[id] = nil
    }

    private(set) var finalizedTranscript = ""
    private(set) var volatileTranscript = ""
    /// Monotonic revision for composer presentation updates.
    ///
    /// Some dictation events change only certainty state (volatile → settled)
    /// while leaving the visible transcript string unchanged. The composer uses
    /// this revision to refresh styling for same-text segment commits.
    private(set) var transcriptPresentationRevision = 0
    private var correctionHighlightText = ""
    private var correctionHighlightRanges: [NSRange] = []
    private var correctionHighlightTask: Task<Void, Never>?
    private(set) var audioLevel: Float = 0

    /// Short language code for the active recording session (e.g. "EN", "中").
    /// Set at recording start from the resolved locale. Nil when not recording.
    private(set) var activeLanguageLabel: String?

    /// Effective engine selected for the current voice session.
    /// Set at start of recording (including preparing) and cleared on teardown.
    private(set) var activeEngine: TranscriptionEngine?

    /// Source UI that owns the active recording session.
    /// Dictation uses one shared manager, so consumers must check this before
    /// applying transcript revisions to their own text binding.
    private(set) var activeRecordingSource: String?

    func isActiveRecordingSource(_ source: String) -> Bool {
        activeRecordingSource == source
    }

    var currentTranscript: String {
        let base: String
        if typewriterAnimator.isAnimating {
            // During animation, show the partially revealed text.
            base = typewriterAnimator.displayText + volatileTranscript
        } else {
            base = finalizedTranscript + volatileTranscript
        }
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Visible volatile suffix in the current transcript preview.
    /// Used by the composer to tint unstable text without affecting settled text.
    var currentTranscriptVolatileSuffixLength: Int {
        if replaceTranscriptState.isTracking {
            return replaceTranscriptState.visibleActiveSuffixLength(in: currentTranscript)
        }

        if typewriterAnimator.isAnimating {
            return min(currentTranscript.count, typewriterAnimator.visibleAnimatedSuffixLength)
        }

        guard !volatileTranscript.isEmpty else { return 0 }
        return min(currentTranscript.count, volatileTranscript.count)
    }

    /// Word ranges that were corrected during the most recent settle/commit.
    /// Ranges are relative to the dictated transcript (not any typed prefix).
    var currentTranscriptCorrectionRanges: [NSRange] {
        let referenceText = finalizedTranscript + volatileTranscript
        guard !referenceText.isEmpty, correctionHighlightText == referenceText else { return [] }
        return correctionHighlightRanges
    }

    var isRecording: Bool { state == .recording }
    var isProcessing: Bool { state == .processing }
    var isPreparing: Bool { state == .preparingModel }

    /// Route indicator for UI badges.
    /// While recording/preparing, this reflects the resolved engine.
    /// When idle, this reflects configured engine mode.
    var routeIndicator: RouteIndicator {
        if let activeEngine {
            switch activeEngine {
            case .serverDictation:
                return .remote
            case .modernSpeech, .classicDictation:
                return .onDevice
            }
        }

        switch engineMode {
        case .auto:
            return .auto
        case .onDevice:
            return .onDevice
        case .remote:
            return .remote
        }
    }

    // MARK: - Private

    /// Shared helpers for pluggable provider routing + active session lifecycle.
    private let providerRegistry: VoiceProviderRegistry
    private let routeResolver: VoiceInputRouteResolver
    private let sessionMonitor: VoiceInputSessionMonitor
    private let systemAccess: any VoiceInputSystemAccessing
    private weak var playbackCoordinator: (any VoicePlaybackCaptureCoordinating)?
    private weak var interruptedPlaybackCoordinator: (any VoicePlaybackCaptureCoordinating)?
    private var playbackCaptureInterruptionActive = false

    /// Drives character-by-character text reveal for server dictation updates.
    let typewriterAnimator = TypewriterAnimator()

    /// Operation lock — prevents overlapping async operations.
    private var operationInFlight = false

    /// Request ID for start operations, used to cancel stale in-flight starts.
    private var nextStartRequestID = 0
    private var activeStartRequestID: Int?
    /// Composer generation that owned the take when `activeStartRequestID` was assigned.
    private var activeStartComposerGeneration: Int?

    // MARK: - Session Attribution

    /// Active session ID for metric attribution. Set by ChatView on session connect.
    var activeSessionId: String?

    // MARK: - Dictation Telemetry State

    private var activeMetricAnnotation: VoiceMetricAnnotation?
    private var activeDictationMetricTags: [String: String] = [:]
    private var dictationSessionStart: ContinuousClock.Instant?
    private var recordingStart: ContinuousClock.Instant?
    private var resultUpdateCount = 0
    private var replaceTranscriptState = ReplaceTranscriptState()
    private var lastCaptureAudioAt: ContinuousClock.Instant?
    private var captureHealthTask: Task<Void, Never>?
    private var activeCaptureRebuildID: UUID?
    private var pendingCaptureRebuild = false
    private var captureStallRebuildsThisTake = 0
    private var captureRecoveryAudioBeganAt: ContinuousClock.Instant?

    private static let correctionHighlightDuration: Duration = .milliseconds(600)
    private static let captureStallTimeoutMs = 1_500
    private static let maxCaptureRebuildsPerTake = 2

    // MARK: - Server Configuration

    /// Server credentials for the Oppi dictation endpoint.
    /// Set by ChatView when server connection is active.
    private(set) var serverCredentials: ServerCredentials?
    private(set) var serverConnection: ServerConnection?
    private(set) var serverDictationTarget: ServerDictationTarget?

    /// User-selected engine routing mode.
    private(set) var engineMode: EngineMode = .auto

    private var composerOwner: VoiceComposerOwner?
    private var composerGeneration = 0
    #if os(iOS)
    nonisolated(unsafe) private var audioRouteChangeObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Init

    /// Process-wide capture owner. Apple allows few simultaneous `SpeechAnalyzer`
    /// sessions; Chat and Quick Session never dictate at once, so they share this
    /// manager. Each take still builds a fresh analyzer — a transcriber is invalid
    /// after finalize.
    static let shared = VoiceInputManager()

    init(
        providerRegistry: VoiceProviderRegistry = .makeDefault(),
        routeResolver: VoiceInputRouteResolver = VoiceInputRouteResolver(),
        sessionMonitor: VoiceInputSessionMonitor = VoiceInputSessionMonitor(),
        systemAccess: any VoiceInputSystemAccessing = VoiceInputSystemAccess.live
    ) {
        self.providerRegistry = providerRegistry
        self.routeResolver = routeResolver
        self.sessionMonitor = sessionMonitor
        self.systemAccess = systemAccess
        loadPreferences()
        #if os(iOS)
        observeAudioRouteChanges()
        #endif
    }

    deinit {
        #if os(iOS)
        if let audioRouteChangeObserver {
            NotificationCenter.default.removeObserver(audioRouteChangeObserver)
        }
        #endif
    }

    /// Reload persisted voice settings.
    func loadPreferences() {
        applyEngineMode(from: AppPreferences.Voice.engineMode)
    }

    /// Update server credentials for the dictation provider.
    /// Called by ChatView when the server connection state changes.
    func setServerCredentials(_ credentials: ServerCredentials?) {
        serverCredentials = credentials
        if credentials != nil {
            // Server readiness is credential-bound; Apple model/format readiness
            // is not. Composer reactivation must not erase on-device prewarming.
            providerRegistry.provider(for: .serverDictation)?.invalidateCache()
        }
        let host = credentials?.host ?? "none"
        logger.info("Server credentials: \(credentials != nil ? "set" : "cleared") host=\(host)")
    }

    func setPlaybackInterrupter(_ coordinator: (any VoicePlaybackCaptureCoordinating)?) {
        playbackCoordinator = coordinator
    }

    /// Update the server connection reference for the dictation provider.
    /// Called by ChatView alongside setServerCredentials.
    func setServerConnection(_ connection: ServerConnection?) {
        serverConnection = connection
    }

    /// Legacy session-audio target hook. Server-bound dictation leaves this nil.
    func setServerDictationTarget(_ target: ServerDictationTarget?) {
        serverDictationTarget = target
    }

    /// Set engine mode directly.
    func setEngineMode(_ mode: EngineMode) {
        guard engineMode != mode else { return }
        engineMode = mode
        activeEngine = nil
        providerRegistry.provider(for: .serverDictation)?.invalidateCache()
        logger.info("Engine mode: \(mode.logName)")
    }

    /// Visible conversation composer claims the shared manager and restores its server.
    @discardableResult
    func activateConversationComposer(
        serverId: String,
        sessionId: String,
        credentials: ServerCredentials?,
        connection: ServerConnection?
    ) -> Int {
        let owner = VoiceComposerOwner(serverId: serverId, kind: .conversation(sessionId: sessionId))
        return claimComposer(owner, credentials: credentials, connection: connection)
    }

    /// Conversation-free composer. Does not clear the previous conversation cache.
    @discardableResult
    func beginStandaloneComposer(
        serverId: String,
        credentials: ServerCredentials?,
        connection: ServerConnection?
    ) -> Int {
        let owner = VoiceComposerOwner(serverId: serverId, kind: .standalone)
        return claimComposer(owner, credentials: credentials, connection: connection)
    }

    func endComposer(generation: Int) {
        guard generation == composerGeneration else { return }
        composerOwner = nil
    }

    private func claimComposer(
        _ owner: VoiceComposerOwner,
        credentials: ServerCredentials?,
        connection: ServerConnection?
    ) -> Int {
        composerGeneration += 1
        composerOwner = owner
        if case .conversation(let sessionId) = owner.kind {
            activeSessionId = sessionId
        } else {
            activeSessionId = nil
        }
        setServerCredentials(credentials)
        setServerConnection(connection)
        setServerDictationTarget(nil)
        return composerGeneration
    }

    /// Frozen per-take snapshot. Named so SwiftLint does not treat this as a large tuple.
    private struct AuthorizedTakeSnapshot {
        let credentials: ServerCredentials?
        let connection: ServerConnection?
        let target: ServerDictationTarget?
    }

    private func freezeAuthorizedTake() -> AuthorizedTakeSnapshot {
        AuthorizedTakeSnapshot(
            credentials: serverCredentials,
            connection: serverConnection,
            target: serverDictationTarget
        )
    }

    func currentCaptureTakeIdentity() -> VoiceCaptureTakeIdentity? {
        guard let activeStartRequestID, let activeStartComposerGeneration else { return nil }
        switch state {
        case .preparingModel, .recording:
            return VoiceCaptureTakeIdentity(
                requestID: activeStartRequestID,
                composerGeneration: activeStartComposerGeneration
            )
        default:
            return nil
        }
    }

    private func clearActiveStartIdentity() {
        activeStartRequestID = nil
        activeStartComposerGeneration = nil
    }

    func cancelRecording(matching identity: VoiceCaptureTakeIdentity?) async {
        guard let identity else { return }
        guard currentCaptureTakeIdentity() == identity else { return }
        await cancelRecording()
    }

    // MARK: - Locale Resolution
    /// Resolve the effective engine, considering mode + server availability.
    private func effectiveEngine(for locale: Locale) async -> TranscriptionEngine {
        let fallback = Self.preferredEngine(for: locale)
        let resolved = await routeResolver.resolveEngine(
            mode: engineMode,
            fallback: fallback,
            locale: locale,
            serverCredentials: serverCredentials,
            serverDictationAvailable: serverConnection?.serverDictationAvailable ?? false
        )

        // Tests and previews often register only one on-device provider. Keep
        // capability-aware production routing while allowing narrow registries
        // to exercise startup behavior with their registered fallback provider.
        if providerRegistry.provider(for: resolved) == nil,
           resolved != .serverDictation {
            if providerRegistry.provider(for: fallback) != nil {
                return fallback
            }
            let alternative: TranscriptionEngine = fallback == .modernSpeech
                ? .classicDictation
                : .modernSpeech
            if providerRegistry.provider(for: alternative) != nil {
                return alternative
            }
        }

        return resolved
    }

    private func validateServerDictationAvailabilityIfNeeded(
        for engine: TranscriptionEngine,
        take: AuthorizedTakeSnapshot
    ) throws {
        guard engine == .serverDictation else { return }
        guard take.credentials != nil, take.connection != nil else {
            throw VoiceInputError.serverNotConnected
        }
    }

    private func provider(
        for engine: TranscriptionEngine
    ) throws -> any VoiceTranscriptionProvider {
        guard let provider = providerRegistry.provider(for: engine) else {
            throw VoiceInputError.internalError("No voice provider registered for \(engine.rawValue)")
        }
        return provider
    }

    private func applyEngineMode(from preference: AppPreferences.Voice.EngineMode) {
        switch preference {
        case .auto:
            setEngineMode(.auto)
        case .onDevice:
            setEngineMode(.onDevice)
        case .remote:
            setEngineMode(.remote)
        }
    }

    // MARK: - Pre-warm

    /// Check model availability and cache audio format in the background.
    /// Call from ChatView's .task {} so the first mic tap is fast.
    /// Safe to call multiple times — no-ops after first success for the same locale+engine.
    func prewarm(keyboardLanguage: String? = nil, source: String = "unknown") async {
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        let engine = await effectiveEngine(for: locale)
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        let prewarmStart = ContinuousClock.now
        guard state == .idle else { return }

        do {
            try await provider(for: engine).prewarm(
                context: VoiceProviderContext(
                    locale: locale,
                    source: source,
                    serverCredentials: serverCredentials,
                    serverConnection: serverConnection,
                    serverDictationTarget: serverDictationTarget
                )
            )

            let durationMs = prewarmStart.elapsedMs()
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "ok"
            )
            logger.info("Pre-warmed \(engine.logName) model (locale: \(localeID))")
        } catch is CancellationError {
            let durationMs = prewarmStart.elapsedMs()
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "cancelled"
            )
            logger.info("Pre-warm cancelled for \(engine.logName) (locale: \(localeID))")
        } catch {
            let durationMs = prewarmStart.elapsedMs()
            recordVoiceMetric(
                .voicePrewarmMs,
                valueMs: durationMs,
                annotation: metricAnnotation,
                phase: .prewarm,
                status: "error",
                extraTags: ["error": String(describing: type(of: error))]
            )
            logger.warning("Pre-warm failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Permissions

    /// Request mic + speech permissions. Returns true if both granted.
    func requestPermissions() async -> Bool {
        let granted = await systemAccess.requestPermissions()
        guard granted else {
            if AVAudioApplication.shared.recordPermission != .granted {
                logger.warning("Microphone permission denied")
            } else {
                logger.warning("Speech recognition permission denied")
            }
            return false
        }
        return true
    }

    // MARK: - Recording

    private func validateStartAdmission() throws {
        guard !operationInFlight else {
            logger.warning("Cannot start: operation already in flight")
            throw VoiceInputError.captureBusy
        }
        switch state {
        case .idle, .error:
            // A failed take has already been torn down. The visible mic offers
            // retry immediately; don't silently reject it during the error timer.
            break
        default:
            logger.warning("Cannot start: state is \(String(describing: self.state))")
            throw VoiceInputError.captureBusy
        }
    }

    /// Start recording and streaming transcription.
    /// Pass `keyboardLanguage` from the text view's `textInputMode?.primaryLanguage`
    /// to match the user's active keyboard. Falls back to device locale when nil.
    func startRecording(
        keyboardLanguage: String? = nil, source: String = "unknown",
        onCaptureFailure: (@MainActor () -> Void)? = nil
    ) async throws {
        try validateStartAdmission()
        captureFailure = nil
        captureFailureHandler = onCaptureFailure
        nextStartRequestID += 1
        let requestID = nextStartRequestID
        activeStartRequestID = requestID
        activeStartComposerGeneration = composerGeneration
        operationInFlight = true
        var ownsOperation = true
        defer {
            if ownsOperation {
                operationInFlight = false
            }
            switch state {
            case .preparingModel, .recording:
                break
            default:
                if activeStartRequestID == requestID {
                    clearActiveStartIdentity()
                }
            }
        }

        finalizedTranscript = ""
        volatileTranscript = ""
        captureStallRebuildsThisTake = 0
        captureRecoveryAudioBeganAt = nil
        pendingCaptureRebuild = false
        activeCaptureRebuildID = nil
        activeMetricAnnotation = nil
        activeDictationMetricTags = [:]
        dictationSessionStart = nil
        recordingStart = nil
        resultUpdateCount = 0
        replaceTranscriptState.reset()
        activeRecordingSource = source
        let frozenTake = freezeAuthorizedTake()

        state = .preparingModel
        let startTime = ContinuousClock.now
        let locale = Self.resolvedLocale(keyboardLanguage: keyboardLanguage)
        let localeID = locale.identifier(.bcp47)
        activeLanguageLabel = Self.languageLabel(for: locale)
        let engine = await effectiveEngine(for: locale)
        guard activeStartRequestID == requestID, state == .preparingModel else {
            ownsOperation = false
            throw CancellationError()
        }
        dictationSessionStart = startTime
        activeEngine = engine
        beginPlaybackCaptureInterruptionIfNeeded()

        // SpeechAnalyzer/DictationTranscriber capture needs microphone access.
        // Do not gate on legacy SFSpeechRecognizer authorization here: users can
        // deny that permission while on-device dictation remains usable, and the
        // provider will surface any real analyzer/model failure during startup.
        if !systemAccess.hasMicPermission {
            guard await systemAccess.requestMicPermission() else {
                if activeStartRequestID == requestID {
                    endPlaybackCaptureInterruptionIfNeeded()
                    activeEngine = nil
                    activeRecordingSource = nil
                    state = .error("Microphone permission denied")
                    scheduleErrorReset()
                } else {
                    ownsOperation = false
                    throw CancellationError()
                }
                throw VoiceInputError.microphonePermissionDenied
            }
        }

        guard activeStartRequestID == requestID, state == .preparingModel else {
            ownsOperation = false
            throw CancellationError()
        }
        let metricAnnotation = VoiceMetricAnnotation(
            engine: engine.logName,
            locale: localeID,
            source: source
        )
        activeMetricAnnotation = metricAnnotation

        let context = VoiceProviderContext(
            locale: locale,
            source: source,
            serverCredentials: frozenTake.credentials,
            serverConnection: frozenTake.connection,
            serverDictationTarget: frozenTake.target
        )
        var modelPathTag = "warm_cache"

        do {
            let provider = try provider(for: engine)
            try validateServerDictationAvailabilityIfNeeded(for: engine, take: frozenTake)
            try ensureStartRequestActive(requestID)

            let timings = try await startProviderRecording(
                requestID: requestID,
                startTime: startTime,
                locale: locale,
                provider: provider,
                context: context,
                metricAnnotation: metricAnnotation,
                modelPathTag: &modelPathTag
            )

            state = .recording
            #if os(iOS)
            startCaptureHealthWatch()
            #endif

            // Emit telemetry AFTER state transition — off the critical path
            emitStartupTelemetry(timings, annotation: metricAnnotation)
            logger.error("Voice setup: recording started in \(timings.totalMs)ms total (engine: \(engine.logName), locale: \(localeID))")
            return
        } catch is CancellationError {
            let totalMs = startTime.elapsedMs()
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "cancelled",
                extraTags: ["path": modelPathTag]
            )
            logger.info("Voice setup cancelled")
            if activeStartRequestID == requestID {
                let stillOwns = await cleanupFailedStart(for: requestID)
                if stillOwns {
                    state = .idle
                } else {
                    ownsOperation = false
                }
            } else {
                ownsOperation = false
            }
            return
        } catch {
            let totalMs = startTime.elapsedMs()
            let userFacingMessage = userFacingErrorMessage(for: error)
            let errorKind = Self.metricErrorKind(for: error)
            let failure = error as NSError
            ClientLog.error("VoiceInput", "Dictation start failed", metadata: [
                "phase": "setup",
                "engine": engine.logName,
                "source": source,
                "errorDomain": failure.domain,
                "errorCode": String(failure.code),
            ])
            recordVoiceMetric(
                .voiceSetupMs,
                valueMs: totalMs,
                annotation: metricAnnotation,
                phase: .total,
                status: "error",
                extraTags: [
                    "path": modelPathTag,
                    "error": String(describing: type(of: error)),
                    "error_kind": errorKind,
                ]
            )
            recordDictationCountMetric(
                .dictationError,
                value: 1,
                annotation: metricAnnotation,
                status: "error",
                extraTags: [
                    "phase": "setup",
                    "error_kind": errorKind,
                ]
            )
            if engine == .serverDictation {
                logger.error(
                    "Server dictation setup failed: \(userFacingMessage, privacy: .public)"
                )
            } else {
                logger.error("Voice setup failed: \(userFacingMessage, privacy: .public)")
            }
            if activeStartRequestID == requestID {
                let stillOwns = await cleanupFailedStart(for: requestID)
                if stillOwns {
                    state = .error(userFacingMessage)
                    scheduleErrorReset()
                } else {
                    ownsOperation = false
                }
            } else {
                ownsOperation = false
            }
            throw error
        }
    }

    /// Stop recording. Finalizes transcription and waits for last results.
    /// Returns the final transcript captured before session teardown.
    @discardableResult
    func stopRecording() async -> String {
        guard state == .recording else {
            logger.warning("Cannot stop: state is \(String(describing: self.state))")
            return ""
        }
        guard !operationInFlight else {
            logger.warning("Cannot stop: operation already in flight")
            return ""
        }
        operationInFlight = true
        defer { operationInFlight = false }

        let stoppingTake = currentCaptureTakeIdentity()
        state = .processing
        typewriterAnimator.commitCurrentAnimation()
        logger.info("Stopping recording")

        let finalizeStart = ContinuousClock.now
        let previewTranscript = currentTranscript
        let audioDurationMs = recordingStart?.elapsedMs() ?? 0

        await sessionMonitor.stop()

        // The results callback latches every fatal error synchronously, including
        // converter flush failure inside stop(). Stop alone owns this drain; never
        // publish incomplete text or overwrite the failed take with success.
        if let failure = captureFailure, failure.take == stoppingTake {
            teardownSession()
            releaseAudioSessionAfterCapture()
            state = .error(failure.message)
            return ""
        }

        let finalizeMs = finalizeStart.elapsedMs()
        let sessionMs = dictationSessionStart?.elapsedMs() ?? finalizeMs
        emitDictationStopTelemetry(
            finalizeMs: finalizeMs,
            sessionMs: sessionMs,
            audioDurationMs: audioDurationMs,
            previewTranscript: previewTranscript,
            finalTranscript: currentTranscript
        )

        let result = currentTranscript

        teardownSession()
        releaseAudioSessionAfterCapture()
        state = .idle
        logger.info("Stopped. Transcript length: \(result.count) chars")
        return result
    }

    /// Cancel recording without finalizing. Discards all text.
    func cancelRecording() async {
        guard state == .recording || state == .preparingModel else {
            logger.warning("Cannot cancel: state is \(String(describing: self.state))")
            return
        }
        logger.info("Cancelling recording")

        if state == .preparingModel, let activeEngine {
            try? provider(for: activeEngine).cancelPreparation()
        }

        // Retire first, but do not release admission until the shared hardware
        // drain finishes. A competing startup/stream cleanup must lose ownership.
        let generation = nextStartRequestID
        clearActiveStartIdentity()
        state = .processing
        await sessionMonitor.cancel()
        guard nextStartRequestID == generation, state == .processing else { return }
        teardownSession()
        releaseAudioSessionAfterCapture()

        emitDictationCancelTelemetry()
        operationInFlight = false
        state = .idle
    }

    // MARK: - Startup Timings (deferred telemetry)

    /// Captured during startProviderRecording, emitted after state = .recording.
    private struct StartupTimings {
        var modelReadyMs: Int = 0
        var transcriberCreateMs: Int = 0
        var analyzerStartMs: Int = 0
        var audioStartMs: Int = 0
        var audioSessionMs: Int = 0
        var totalMs: Int = 0
        var pathTag: String = "warm_cache"
        var providerTags: [String: String] = [:]
    }

    private func emitStartupTelemetry(
        _ timings: StartupTimings,
        annotation: VoiceMetricAnnotation
    ) {
        // Build merged tags once (deferred — not on hot path).
        var tags = ["path": timings.pathTag]
        for (k, v) in timings.providerTags { tags[k] = v }
        activeDictationMetricTags = tags

        recordVoiceMetric(.voiceSetupMs, valueMs: timings.modelReadyMs,
                          annotation: annotation, phase: .modelReady, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.transcriberCreateMs,
                          annotation: annotation, phase: .transcriberCreate, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.analyzerStartMs,
                          annotation: annotation, phase: .analyzerStart, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.audioSessionMs,
                          annotation: annotation, phase: .audioSession, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.audioStartMs,
                          annotation: annotation, phase: .audioStart, status: "ok", extraTags: tags)
        recordVoiceMetric(.voiceSetupMs, valueMs: timings.totalMs,
                          annotation: annotation, phase: .total, status: "ok", extraTags: tags)
        recordDictationMetric(
            .dictationSetupMs,
            valueMs: timings.totalMs,
            annotation: annotation,
            status: "ok",
            extraTags: tags
        )
    }

    // MARK: - Provider Recording

    private func startProviderRecording(
        requestID: Int,
        startTime: ContinuousClock.Instant,
        locale: Locale,
        provider: any VoiceTranscriptionProvider,
        context: VoiceProviderContext,
        metricAnnotation: VoiceMetricAnnotation,
        modelPathTag: inout String
    ) async throws -> StartupTimings {
        var timings = StartupTimings()

        let modelPhaseStart = ContinuousClock.now
        var preparation = try await provider.prepareSession(context: context)
        try ensureStartRequestActive(requestID)

        modelPathTag = preparation.pathTag
        timings.pathTag = modelPathTag
        timings.providerTags = preparation.setupMetricTags
        timings.modelReadyMs = modelPhaseStart.elapsedMs()

        let transcriberStart = ContinuousClock.now
        var session = try provider.makeSession(context: context, preparation: preparation)
        activeLanguageLabel = Self.languageLabel(for: locale)
        timings.transcriberCreateMs = transcriberStart.elapsedMs()

        try ensureStartRequestActive(requestID)
        bindSessionMonitor(session, metricAnnotation: metricAnnotation)

        let audioSessionStart = ContinuousClock.now
        try setupAudioSession()
        timings.audioSessionMs = audioSessionStart.elapsedMs()
        let sessionTimings: VoiceSessionStartTimings
        do {
            sessionTimings = try await session.start()
        } catch {
            if error is CancellationError { throw error }
            try ensureStartRequestActive(requestID)
            let failure = error as NSError
            // Remote ASR still captures locally. Its AVAudioEngine can fail
            // after activation succeeded, so activation-only fallback misses it.
            // Never retry a server/network error as an audio route failure.
            let isCaptureFailure = switch error {
            case VoiceInputError.audioCaptureUnavailable: true
            default: failure.domain == "com.apple.coreaudio.avfaudio"
            }
            guard provider.engine != .serverDictation || isCaptureFailure else { throw error }
            ClientLog.error("VoiceInput", "Capture start failed; retrying built-in microphone", metadata: [
                "phase": "capture_start",
                "engine": provider.engine.logName,
                "errorDomain": failure.domain,
                "errorCode": String(failure.code),
            ])
            await sessionMonitor.cancel()
            try ensureStartRequestActive(requestID)
            // The failed engine has released hardware. Reconfigure the still-active
            // mixed session directly so surviving playback is not deactivated.
            try systemAccess.activateBuiltInAudioSession(
                inAppPlaybackActive: hasActiveInAppPlayback
            )
            // Preferred-input/data-source changes can reconfigure hardware.
            // Build the new engine only after the reset's settling interval.
            try await Task.sleep(for: .milliseconds(250))
            try ensureStartRequestActive(requestID)

            if provider.engine == .serverDictation {
                // makeSession consumes the readiness task and recording stream.
                // Cancellation invalidated both; a fresh engine needs a fresh take.
                provider.cancelPreparation()
                preparation = try await provider.prepareSession(context: context)
                try ensureStartRequestActive(requestID)
                modelPathTag = preparation.pathTag
                timings.pathTag = preparation.pathTag
                timings.providerTags = preparation.setupMetricTags
            }
            timings.providerTags["audio_route"] = "built_in_fallback"
            session = try provider.makeSession(context: context, preparation: preparation)
            bindSessionMonitor(session, metricAnnotation: metricAnnotation)
            sessionTimings = try await session.start()
        }
        try ensureStartRequestActive(requestID)

        timings.analyzerStartMs = sessionTimings.analyzerStartMs
        timings.audioStartMs = sessionTimings.audioStartMs
        timings.totalMs = startTime.elapsedMs()
        recordingStart = ContinuousClock.now
        lastCaptureAudioAt = recordingStart
        for (key, value) in DictationAudioEngineHelper.sessionRouteMetadata() {
            timings.providerTags[key] = value
        }

        return timings
    }

    private func bindSessionMonitor(
        _ session: any VoiceTranscriptionSession,
        metricAnnotation: VoiceMetricAnnotation
    ) {
        let requestID = activeStartRequestID
        sessionMonitor.bind(
            session: session,
            recordingStartTime: ContinuousClock.now,
            onAudioLevel: { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.lastCaptureAudioAt = .now
                if let recoveryStart = self.captureRecoveryAudioBeganAt,
                   recoveryStart.elapsedMs() >= Self.captureStallTimeoutMs {
                    self.captureStallRebuildsThisTake = 0
                    self.captureRecoveryAudioBeganAt = nil
                }
            },
            onEvent: { [weak self] event in
                self?.applySessionEvent(event, annotation: metricAnnotation)
            },
            onFirstTranscript: { [weak self] latencyMs, resultType in
                guard let self else { return }
                self.recordVoiceMetric(
                    .voiceFirstResultMs,
                    valueMs: latencyMs,
                    annotation: metricAnnotation,
                    phase: .firstResult,
                    status: "ok",
                    extraTags: ["result_type": resultType]
                )
                self.recordDictationMetric(
                    .dictationFirstResultMs,
                    valueMs: latencyMs,
                    annotation: metricAnnotation,
                    status: "ok",
                    extraTags: ["result_type": resultType]
                )
                logger.error("Voice latency: first result in \(latencyMs)ms (type: \(resultType))")
            },
            onError: { [weak self] error in
                guard let self, self.activeStartRequestID == requestID else { return }
                // Must run before the monitor's results task completes, for
                // analyzer/transport errors as well as overflow. An async latch
                // lets Stop publish incomplete text before it observes failure.
                self.failCaptureForSessionError(error, annotation: metricAnnotation)
            }
        )
    }

    // MARK: - Setup

    /// Media preparation must consult the capture owner, not infer ownership
    /// from AVAudioSession.category (which persists after deactivation).
    var ownsCaptureAudioSession: Bool {
        switch state {
        case .preparingModel, .recording, .processing: true
        case .idle, .error: false
        }
    }

    private func setupAudioSession() throws {
        try systemAccess.activateAudioSession(
            inAppPlaybackActive: hasActiveInAppPlayback
        )
    }

    private func deactivateAudioSession() {
        systemAccess.deactivateAudioSession()
    }

    #if os(iOS)
    private func observeAudioRouteChanges() {
        guard audioRouteChangeObserver == nil else { return }
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previous = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription
            let previousHadBluetooth = previous?.inputs.contains {
                $0.portType == .bluetoothHFP
            } == true
            let previousInputUIDs = Set(previous?.inputs.map(\.uid) ?? [])
            let currentInputUIDs = Set(AVAudioSession.sharedInstance().currentRoute.inputs.map(\.uid))
            let routeInputChanged = previousInputUIDs != currentInputUIDs
            Task { @MainActor in
                await self?.handleAudioRouteChange(
                    rawReason: rawReason,
                    previousHadBluetooth: previousHadBluetooth,
                    routeInputChanged: routeInputChanged
                )
            }
        }
    }

    func handleLostBluetoothRoute(rawReason: UInt?, previousHadBluetooth: Bool) async {
        await handleAudioRouteChange(
            rawReason: rawReason,
            previousHadBluetooth: previousHadBluetooth
        )
    }

    func handleAudioRouteChange(
        rawReason: UInt?,
        previousHadBluetooth: Bool,
        routeInputChanged: Bool = true
    ) async {
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
        metadata["reason"] = reason.map { String($0.rawValue) } ?? "nil"
        metadata["previous_had_bluetooth"] = previousHadBluetooth ? "1" : "0"
        metadata["state"] = String(describing: state)
        ClientLog.info("VoiceInput", "Audio route changed", metadata: metadata)

        guard Self.shouldHandleCaptureRouteChange(reason: reason) else { return }
        guard Self.shouldRebuildCaptureForRouteChange(
            reason: reason,
            routeInputChanged: routeInputChanged
        ) else { return }
        guard state == .recording || state == .preparingModel else { return }

        // Category/preferred-input setup emits expected configuration changes
        // before the first engine owns capture. Ignore those; only a real lost
        // Bluetooth microphone can invalidate startup.
        if state == .preparingModel, activeCaptureRebuildID == nil {
            guard reason == .oldDeviceUnavailable, previousHadBluetooth else { return }
            await failActiveCaptureForDeadPipeline(
                previousHadBluetooth: previousHadBluetooth,
                reason: reason,
                errorKind: "bluetooth_route_lost"
            )
            return
        }

        await rebuildOrFailActiveCapture(
            previousHadBluetooth: previousHadBluetooth,
            reason: reason,
            trigger: "route_change"
        )
    }

    private func rebuildOrFailActiveCapture(
        previousHadBluetooth: Bool,
        reason: AVAudioSession.RouteChangeReason?,
        trigger: String
    ) async {
        guard state == .recording else { return }
        let takeID = activeStartRequestID
        let generation = nextStartRequestID
        guard takeID != nil else { return }
        guard activeCaptureRebuildID == nil else {
            pendingCaptureRebuild = true
            return
        }
        let rebuildID = UUID()
        activeCaptureRebuildID = rebuildID
        defer {
            if activeCaptureRebuildID == rebuildID {
                activeCaptureRebuildID = nil
                if pendingCaptureRebuild,
                   activeStartRequestID == takeID,
                   nextStartRequestID == generation,
                   state == .recording {
                    pendingCaptureRebuild = false
                    Task { @MainActor [weak self] in
                        await self?.rebuildOrFailActiveCapture(
                            previousHadBluetooth: previousHadBluetooth,
                            reason: reason,
                            trigger: "queued_route_change"
                        )
                    }
                }
            }
        }

        if trigger == "stall" {
            captureStallRebuildsThisTake += 1
        }
        var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
        metadata["trigger"] = trigger
        metadata["rebuild_attempt"] = String(captureStallRebuildsThisTake)
        metadata["reason"] = reason.map { String($0.rawValue) } ?? "nil"

        guard trigger != "stall" || captureStallRebuildsThisTake <= Self.maxCaptureRebuildsPerTake else {
            ClientLog.error("VoiceInput", "Capture rebuild budget exhausted", metadata: metadata)
            await failActiveCaptureForDeadPipeline(
                previousHadBluetooth: previousHadBluetooth,
                reason: reason,
                errorKind: "capture_pipeline_dead"
            )
            return
        }

        do {
            // Do not re-run setupAudioSession here: category selection could
            // overwrite a newly settling route or replace active A2DP with HFP.
            // The OS already changed the route; wait, then rebuild the engine.
            try await Task.sleep(for: .milliseconds(250))
            guard activeStartRequestID == takeID, nextStartRequestID == generation else { return }
            guard state == .recording else { return }
            try await sessionMonitor.rebuildAudioCapture()
            guard activeStartRequestID == takeID, nextStartRequestID == generation else { return }
            lastCaptureAudioAt = .now
            if trigger == "stall" {
                captureRecoveryAudioBeganAt = .now
            }
            state = .recording
            metadata.merge(DictationAudioEngineHelper.sessionRouteMetadata()) { _, new in new }
            metadata["status"] = "ok"
            ClientLog.info("VoiceInput", "Capture rebuilt onto current microphone", metadata: metadata)
            for (key, value) in DictationAudioEngineHelper.sessionRouteMetadata() {
                activeDictationMetricTags[key] = value
            }
            startCaptureHealthWatch()
        } catch is CancellationError {
            guard activeStartRequestID == takeID, nextStartRequestID == generation else { return }
            await failActiveCaptureForDeadPipeline(
                previousHadBluetooth: previousHadBluetooth,
                reason: reason,
                errorKind: "capture_pipeline_dead"
            )
        } catch {
            guard activeStartRequestID == takeID, nextStartRequestID == generation else { return }
            guard state == .recording else { return }
            metadata["status"] = "error"
            metadata["error_domain"] = (error as NSError).domain
            metadata["error_code"] = String((error as NSError).code)
            ClientLog.error("VoiceInput", "Capture rebuild failed", metadata: metadata)
            await failActiveCaptureForDeadPipeline(
                previousHadBluetooth: previousHadBluetooth,
                reason: reason,
                errorKind: trigger == "stall" ? "capture_pipeline_dead" : "bluetooth_route_lost"
            )
        }
    }

    private func failActiveCaptureForDeadPipeline(
        previousHadBluetooth: Bool,
        reason: AVAudioSession.RouteChangeReason?,
        errorKind: String
    ) async {
        guard state == .recording || state == .preparingModel else { return }
        logger.warning("Dictation capture pipeline dead; failing the take (\(errorKind, privacy: .public))")
        let failedTake = currentCaptureTakeIdentity()
        let failedSource = activeRecordingSource
        let failureGeneration = nextStartRequestID
        state = .processing
        clearActiveStartIdentity()
        let message: String
        if reason == .oldDeviceUnavailable, previousHadBluetooth {
            message = "Bluetooth microphone disconnected. This take was discarded. Your earlier draft was kept. Reconnect or use the built-in microphone, then retry."
        } else {
            message = "The microphone route changed and dictation could not keep recording. This take was discarded. Your earlier draft was kept. Retry dictation."
        }
        if let failedTake, let failedSource {
            captureFailure = VoiceCaptureFailure(take: failedTake, source: failedSource, message: message)
            captureFailureHandler?()
            captureFailureHandler = nil
        }
        if let activeEngine {
            try? provider(for: activeEngine).cancelPreparation()
        }
        if let annotation = activeMetricAnnotation {
            recordDictationCountMetric(
                .dictationError, value: 1, annotation: annotation, status: "error",
                extraTags: ["phase": "capture", "error_kind": errorKind]
            )
        }
        await sessionMonitor.cancel()
        guard nextStartRequestID == failureGeneration, state == .processing else { return }
        teardownSession()
        releaseAudioSessionAfterCapture()
        operationInFlight = false
        state = .error(message)
    }

    private func startCaptureHealthWatch() {
        captureHealthTask?.cancel()
        lastCaptureAudioAt = .now
        captureHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
                guard let self, self.state == .recording else { return }
                guard self.activeCaptureRebuildID == nil else { continue }
                guard let last = self.lastCaptureAudioAt else { continue }
                let stalledMs = last.elapsedMs()
                guard stalledMs >= Self.captureStallTimeoutMs else { continue }
                var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
                metadata["stall_ms"] = String(stalledMs)
                ClientLog.warning("VoiceInput", "Capture audio stalled; rebuilding microphone", metadata: metadata)
                await self.rebuildOrFailActiveCapture(
                    previousHadBluetooth: false,
                    reason: nil,
                    trigger: "stall"
                )
            }
        }
    }

    private func stopCaptureHealthWatch() {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        lastCaptureAudioAt = nil
    }

    nonisolated static func shouldRebuildCaptureForRouteChange(
        reason: AVAudioSession.RouteChangeReason?,
        routeInputChanged: Bool
    ) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange, .override:
            routeInputChanged
        default:
            false
        }
    }

    nonisolated static func shouldAbandonCaptureForRouteChange(
        reason: AVAudioSession.RouteChangeReason?,
        previousHadBluetooth: Bool
    ) -> Bool {
        shouldHandleCaptureRouteChange(reason: reason) && previousHadBluetooth && reason == .oldDeviceUnavailable
    }

    nonisolated static func shouldHandleCaptureRouteChange(
        reason: AVAudioSession.RouteChangeReason?
    ) -> Bool {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange, .override:
            true
        default:
            false
        }
    }
    #endif

    private func applySessionEvent(
        _ event: VoiceSessionEvent,
        annotation: VoiceMetricAnnotation
    ) {
        switch event {
        case .partialTranscript(let text):
            replaceTranscriptState.reset()
            volatileTranscript = text
            _ = clearCorrectionHighlight()
            resultUpdateCount += 1
            markTranscriptPresentationChanged()
            logger.debug("Volatile: \(text.count) chars")
        case .appendFinalTranscript(let text):
            replaceTranscriptState.reset()
            finalizedTranscript += text
            volatileTranscript = ""
            _ = clearCorrectionHighlight()
            resultUpdateCount += 1
            markTranscriptPresentationChanged()
            logger.debug("Finalized append: \(text.count) chars")
        case .replaceFinalTranscript(let text, let snap, let committedText, let activeText):
            let previousDisplayText = finalizedTranscript + volatileTranscript
            let previousCommittedPrefixLength = replaceTranscriptState.committedVisiblePrefixLength(
                in: previousDisplayText
            )

            replaceTranscriptState.applyReplacement(
                fullText: text,
                snap: snap,
                explicitCommittedText: committedText,
                explicitActiveText: activeText
            )
            finalizedTranscript = text
            volatileTranscript = ""
            resultUpdateCount += 1
            if state == .recording {
                if snap {
                    // Segment commit: keep the full replacement visible, but
                    // settle the volatile styling immediately.
                    typewriterAnimator.commitCurrentAnimation()
                } else {
                    typewriterAnimator.update(fullText: text)
                }
            }

            let newCommittedPrefixLength = replaceTranscriptState.committedVisiblePrefixLength(in: text)
            let settledPrefixAdvanced = newCommittedPrefixLength > previousCommittedPrefixLength
            let correctionRanges = correctionWordHighlightRanges(
                old: previousDisplayText,
                new: text,
                committedPrefixLength: newCommittedPrefixLength
            )
            if settledPrefixAdvanced, !correctionRanges.isEmpty {
                setCorrectionHighlight(text: text, ranges: correctionRanges)
            } else if correctionHighlightText != text {
                _ = clearCorrectionHighlight()
            }

            markTranscriptPresentationChanged()
            logger.debug("Finalized replace: \(text.count) chars\(snap ? " (snap)" : "")")

        case .remoteChunkTelemetry(let chunk):
            recordRemoteChunkTelemetry(chunk, annotation: annotation)

        case .providerMetricTags(let tags):
            // Merge backend metadata (stt_backend, model) resolved after readiness.
            // Subsequent metrics (finalize, session, audio_duration) get the real values.
            for (key, value) in tags {
                activeDictationMetricTags[key] = value
            }
        }
    }

    // MARK: - Cleanup

    private func teardownSession() {
        captureFailureHandler = nil
        #if os(iOS)
        stopCaptureHealthWatch()
        #endif
        typewriterAnimator.reset()
        sessionMonitor.teardown()
        finalizedTranscript = ""
        volatileTranscript = ""
        replaceTranscriptState.reset()
        _ = clearCorrectionHighlight()
        audioLevel = 0
        activeLanguageLabel = nil
        activeEngine = nil
        activeRecordingSource = nil
        clearActiveStartIdentity()
        activeMetricAnnotation = nil
        activeDictationMetricTags = [:]
        dictationSessionStart = nil
        recordingStart = nil
        resultUpdateCount = 0
    }

    /// Tears down a failed start. Returns false if this request lost ownership
    /// while cancellation suspended, so the caller must not mutate a newer take.
    @discardableResult
    private func cleanupFailedStart(for requestID: Int) async -> Bool {
        guard activeStartRequestID == requestID else { return false }
        await sessionMonitor.cancel()
        guard activeStartRequestID == requestID else { return false }
        teardownSession()
        releaseAudioSessionAfterCapture()
        return true
    }

    private func failCaptureForSessionError(_ error: Error, annotation: VoiceMetricAnnotation) {
        // The public dismiss identity intentionally excludes `.processing`;
        // fatal errors must still identify the take while Stop is finalizing it.
        guard let requestID = activeStartRequestID, let generation = activeStartComposerGeneration,
              let source = activeRecordingSource, captureFailure == nil else { return }
        let take = VoiceCaptureTakeIdentity(requestID: requestID, composerGeneration: generation)
        let stopOwnsDrain = state == .processing
        let wasPreparing = state == .preparingModel
        // Converter, analyzer and transport details belong in diagnostics, not
        // the composer's retry notice. All terminal takes preserve the same draft.
        let message = "Dictation couldn’t continue. This take was discarded. Your earlier draft was kept. Retry dictation."
        let failure = VoiceCaptureFailure(take: take, source: source, message: message)
        // Retire this take before any suspension. Route recovery, another error,
        // and a late startup completion must not publish competing outcomes.
        clearActiveStartIdentity()
        state = .processing
        captureFailure = failure
        let rollback = captureFailureHandler
        captureFailureHandler = nil
        rollback?()
        if wasPreparing, let activeEngine {
            try? provider(for: activeEngine).cancelPreparation()
        }
        recordDictationCountMetric(
            .dictationError, value: 1, annotation: annotation, status: "error",
            extraTags: ["phase": "capture", "error_kind": Self.metricErrorKind(for: error)]
        )
        var metadata = DictationAudioEngineHelper.sessionRouteMetadata()
        metadata["engine"] = annotation.engine
        metadata["source"] = source
        metadata["during_stop"] = String(stopOwnsDrain)
        metadata["error_kind"] = Self.metricErrorKind(for: error)
        metadata["error_domain"] = (error as NSError).domain
        metadata["error_code"] = String((error as NSError).code)
        ClientLog.error("VoiceInput", "Dictation take discarded after fatal session error", metadata: metadata)

        // Cancelling a session already finalizing is not a second drain: its
        // cancel() may be a no-op. Keep ownership until stop() actually returns.
        guard !stopOwnsDrain else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sessionMonitor.cancel()
            guard self.nextStartRequestID == take.requestID, self.state == .processing else { return }
            self.teardownSession()
            self.releaseAudioSessionAfterCapture()
            self.operationInFlight = false
            self.state = .error(failure.message)
        }
    }

    private func scheduleErrorReset() {
        let failedState = state
        let failedRequestGeneration = nextStartRequestID
        Task {
            try? await Task.sleep(for: .seconds(3))
            // A prior take's timer must not dismiss a newer route-loss error.
            if state == failedState, nextStartRequestID == failedRequestGeneration {
                state = .idle
            }
        }
    }

    // MARK: - Helpers

    private var hasActiveInAppPlayback: Bool {
        if AudioPlayerService.isProcessPlaybackActiveForCapture { return true }
        if playbackCoordinator?.isPlaybackActiveForCapture == true { return true }
        return captureReleaseObservers.values.contains { $0.isPlaybackActive() }
    }

    private func beginPlaybackCaptureInterruptionIfNeeded() {
        guard !playbackCaptureInterruptionActive else { return }
        if hasActiveInAppPlayback {
            logger.info("Keeping active audio playback on mixed voice-capture session")
        }
        // The selected server need not own playback. Hold a process claim even
        // without a bound player, and release the same optional coordinator if
        // the visible composer changes server while capture is winding down.
        AudioPlayerService.beginProcessCaptureInterruption(owner: self)
        interruptedPlaybackCoordinator = playbackCoordinator
        interruptedPlaybackCoordinator?.beginCaptureInterruption()
        playbackCaptureInterruptionActive = true
    }

    private func endPlaybackCaptureInterruptionIfNeeded() -> Bool {
        var playbackOwnsSession = false
        if playbackCaptureInterruptionActive {
            interruptedPlaybackCoordinator?.endCaptureInterruption()
            playbackOwnsSession = interruptedPlaybackCoordinator?.isPlaybackActiveForCapture == true
            interruptedPlaybackCoordinator = nil
            playbackOwnsSession = AudioPlayerService.endProcessCaptureInterruption(owner: self) || playbackOwnsSession
            playbackCaptureInterruptionActive = false
        }
        playbackOwnsSession = restoreCaptureReleaseObservers() || playbackOwnsSession
        return playbackOwnsSession
    }

    private func restoreCaptureReleaseObservers() -> Bool {
        var restored = false
        for observer in captureReleaseObservers.values where observer.isPlaybackActive() {
            restored = observer.restorePlaybackSession() || restored
        }
        return restored
    }

    private func releaseAudioSessionAfterCapture() {
        if !endPlaybackCaptureInterruptionIfNeeded() {
            deactivateAudioSession()
        }
    }

    private func markTranscriptPresentationChanged() {
        transcriptPresentationRevision &+= 1
    }

    @discardableResult
    private func clearCorrectionHighlight(cancelTask: Bool = true) -> Bool {
        if cancelTask {
            correctionHighlightTask?.cancel()
            correctionHighlightTask = nil
        }
        guard !correctionHighlightText.isEmpty || !correctionHighlightRanges.isEmpty else {
            return false
        }
        correctionHighlightText = ""
        correctionHighlightRanges = []
        return true
    }

    private func setCorrectionHighlight(text: String, ranges: [NSRange]) {
        _ = clearCorrectionHighlight()
        correctionHighlightText = text
        correctionHighlightRanges = ranges
        correctionHighlightTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.correctionHighlightDuration)
            } catch {
                return
            }
            guard let self else { return }
            self.correctionHighlightTask = nil
            if self.clearCorrectionHighlight(cancelTask: false) {
                self.markTranscriptPresentationChanged()
            }
        }
    }

    private func correctionWordHighlightRanges(
        old oldText: String,
        new newText: String,
        committedPrefixLength: Int
    ) -> [NSRange] {
        guard !oldText.isEmpty, !newText.isEmpty, committedPrefixLength > 0 else { return [] }

        let committedEnd = newText.index(
            newText.startIndex,
            offsetBy: min(committedPrefixLength, newText.count)
        )
        let committedBounds = NSRange(newText.startIndex..<committedEnd, in: newText)

        return Self.correctionWordRanges(old: oldText, new: newText).compactMap { range in
            let visibleRange = NSIntersectionRange(range, committedBounds)
            return visibleRange.length > 0 ? visibleRange : nil
        }
    }

    private struct CorrectionWordToken {
        let text: String
        let range: NSRange
    }

    private static func correctionWordRanges(old: String, new: String) -> [NSRange] {
        guard !old.isEmpty, !new.isEmpty else { return [] }

        let oldTokens = correctionWordTokens(in: old)
        let newTokens = correctionWordTokens(in: new)
        guard !oldTokens.isEmpty, !newTokens.isEmpty else { return [] }

        var prefix = 0
        while prefix < oldTokens.count,
              prefix < newTokens.count,
              oldTokens[prefix].text == newTokens[prefix].text {
            prefix += 1
        }

        // Pure append should not flash correction underline.
        if prefix == oldTokens.count, newTokens.count >= oldTokens.count {
            return []
        }

        var suffix = 0
        while oldTokens.count - suffix - 1 >= prefix,
              newTokens.count - suffix - 1 >= prefix,
              oldTokens[oldTokens.count - suffix - 1].text
                == newTokens[newTokens.count - suffix - 1].text {
            suffix += 1
        }

        let start = prefix
        let end = newTokens.count - suffix
        guard end > start else { return [] }

        return newTokens[start..<end].map(\.range)
    }

    private static func correctionWordTokens(in text: String) -> [CorrectionWordToken] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var tokens: [CorrectionWordToken] = []

        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let nsRange = NSRange(substringRange, in: text)
            let tokenText = nsText.substring(with: nsRange)
            tokens.append(CorrectionWordToken(text: tokenText, range: nsRange))
        }

        // Fallback for scripts where .byWords returns nothing.
        if tokens.isEmpty {
            nsText.enumerateSubstrings(
                in: fullRange,
                options: [.byComposedCharacterSequences]
            ) { substring, range, _, _ in
                guard let substring else { return }
                if substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return
                }
                tokens.append(CorrectionWordToken(text: substring, range: range))
            }
        }

        return tokens
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        VoiceInputTelemetry.userFacingMessage(for: error)
    }

    private static func metricErrorKind(for error: Error) -> String {
        VoiceInputTelemetry.metricErrorKind(for: error)
    }

    private func recordRemoteChunkTelemetry(
        _ chunk: VoiceRemoteChunkTelemetry,
        annotation: VoiceMetricAnnotation
    ) {
        VoiceInputTelemetry.recordRemoteChunkTelemetry(
            chunk,
            annotation: annotation,
            sessionId: activeSessionId
        )
    }

    private func recordVoiceMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        phase: VoiceMetricPhase? = nil,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordMetric(
            metric,
            valueMs: valueMs,
            annotation: annotation,
            sessionId: activeSessionId,
            phase: phase,
            status: status,
            extraTags: extraTags
        )
    }

    private func recordDictationMetric(
        _ metric: ChatMetricName,
        valueMs: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordMetric(
            metric,
            valueMs: valueMs,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func recordDictationCountMetric(
        _ metric: ChatMetricName,
        value: Int,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordCountMetric(
            metric,
            value: value,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func recordDictationRatioMetric(
        _ metric: ChatMetricName,
        value: Double,
        annotation: VoiceMetricAnnotation,
        status: String? = nil,
        extraTags: [String: String] = [:]
    ) {
        VoiceInputTelemetry.recordRatioMetric(
            metric,
            value: value,
            annotation: annotation,
            sessionId: activeSessionId,
            status: status,
            extraTags: mergedDictationMetricTags(extraTags)
        )
    }

    private func mergedDictationMetricTags(_ extraTags: [String: String]) -> [String: String] {
        var tags = activeDictationMetricTags
        for (key, value) in extraTags {
            tags[key] = value
        }
        return tags
    }

    private func emitDictationStopTelemetry(
        finalizeMs: Int,
        sessionMs: Int,
        audioDurationMs: Int,
        previewTranscript: String,
        finalTranscript: String
    ) {
        guard let annotation = activeMetricAnnotation else { return }

        recordDictationMetric(
            .dictationFinalizeMs,
            valueMs: finalizeMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationMetric(
            .dictationSessionMs,
            valueMs: sessionMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationMetric(
            .dictationAudioDurationMs,
            valueMs: audioDurationMs,
            annotation: annotation,
            status: "ok"
        )
        recordDictationCountMetric(
            .dictationResultUpdates,
            value: resultUpdateCount,
            annotation: annotation,
            status: "ok"
        )
        recordDictationRatioMetric(
            .dictationPreviewFinalDelta,
            value: Self.previewFinalDelta(preview: previewTranscript, final: finalTranscript),
            annotation: annotation,
            status: "ok"
        )
    }

    private func emitDictationCancelTelemetry() {
        guard let annotation = activeMetricAnnotation else { return }
        recordDictationCountMetric(
            .dictationCancel,
            value: 1,
            annotation: annotation,
            status: "cancelled"
        )
    }

    private static func previewFinalDelta(preview: String, final: String) -> Double {
        let lhs = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = final.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 0 }
        let distance = levenshteinDistance(Array(lhs), Array(rhs))
        return min(1, Double(distance) / Double(maxLength))
    }

    private static func levenshteinDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for (i, left) in lhs.enumerated() {
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                let substitutionCost = left == right ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }

    private func ensureStartRequestActive(_ requestID: Int) throws {
        guard activeStartRequestID == requestID, state == .preparingModel else {
            throw CancellationError()
        }
    }


}

// MARK: - Testing Support

#if DEBUG
extension VoiceInputManager {
    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    var _testState: State {
        get { state }
        set { state = newValue }
    }

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    var _testOperationInFlight: Bool {
        get { operationInFlight }
        set { operationInFlight = newValue }
    }

    var _testActiveRecordingSource: String? {
        get { activeRecordingSource }
        set { activeRecordingSource = newValue }
    }

    var _testComposerGeneration: Int {
        composerGeneration
    }

    var _testComposerOwner: VoiceComposerOwner? {
        composerOwner
    }

    func _testRestoreCaptureReleaseObservers() -> Bool {
        restoreCaptureReleaseObservers()
    }

    #if os(iOS)
    func _testRebuildActiveCapture(trigger: String = "stall") async {
        await rebuildOrFailActiveCapture(
            previousHadBluetooth: false,
            reason: nil,
            trigger: trigger
        )
    }
    #endif

    // periphery:ignore - used by VoiceInputManagerTests via @testable import
    var _testModelReady: Bool {
        get {
            (providerRegistry.provider(for: .classicDictation) as? AppleOnDeviceVoiceProvider)?._testModelReady ?? false
        }
        set {
            if newValue {
                (providerRegistry.provider(for: .classicDictation) as? AppleOnDeviceVoiceProvider)?._testSetModelReady()
            } else {
                providerRegistry.provider(for: .classicDictation)?.invalidateCache()
            }
        }
    }
}
#endif
