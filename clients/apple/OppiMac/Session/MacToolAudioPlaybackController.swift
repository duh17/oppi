@preconcurrency import AVFoundation
import Foundation
import Observation
import SwiftUI

enum MacToolAudioSource: Equatable, Sendable {
    case ownerSocket(MacAuthenticatedMediaSource)
    case inlineWAV(Data)

    var identity: String {
        switch self {
        case .ownerSocket(let source):
            "owner:\(source.identity)"
        case .inlineWAV(let data):
            "wav:\(data.count):\(data.prefix(12).base64EncodedString())"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.ownerSocket(let lhsSource), .ownerSocket(let rhsSource)):
            return lhsSource.identity == rhsSource.identity
        case (.inlineWAV(let lhsData), .inlineWAV(let rhsData)):
            return lhsData == rhsData
        default:
            return false
        }
    }
}

enum MacToolAudioPlaybackEvent: Equatable, Sendable {
    case playing
    case finished
    case failed(String)
}

@MainActor
protocol MacToolAudioPlaybackBackend: AnyObject {
    func start(onEvent: @escaping @MainActor @Sendable (MacToolAudioPlaybackEvent) -> Void)
    func stop()
}

enum MacToolAudioPlaybackPhase: Equatable, Sendable {
    case idle
    case loading
    case playing
    case failed(String)
}

/// One playback owner for completed voice rows. Starting another row stops the
/// first, matching the iOS global audio-player behavior. Live autoplay remains
/// independently owned by `MacVoiceReplyPlayer`.
@MainActor
@Observable
final class MacToolAudioPlaybackController {
    enum State: Equatable {
        case idle
        case loading(itemID: String)
        case playing(itemID: String)
        case failed(itemID: String, message: String)
    }

    typealias BackendFactory = @MainActor (MacToolAudioSource) throws -> any MacToolAudioPlaybackBackend

    static let shared = MacToolAudioPlaybackController()

    private(set) var state: State = .idle

    @ObservationIgnored private let makeBackend: BackendFactory
    @ObservationIgnored private var backend: (any MacToolAudioPlaybackBackend)?
    @ObservationIgnored private var generation: UInt64 = 0

    init(makeBackend: @escaping BackendFactory = MacToolAudioPlaybackBackendFactory.make) {
        self.makeBackend = makeBackend
    }

    func phase(for itemID: String) -> MacToolAudioPlaybackPhase {
        switch state {
        case .idle:
            return .idle
        case .loading(let activeItemID):
            return activeItemID == itemID ? .loading : .idle
        case .playing(let activeItemID):
            return activeItemID == itemID ? .playing : .idle
        case .failed(let failedItemID, let message):
            return failedItemID == itemID ? .failed(message) : .idle
        }
    }

    func toggle(itemID: String, source: MacToolAudioSource) {
        switch state {
        case .loading(let activeItemID) where activeItemID == itemID,
             .playing(let activeItemID) where activeItemID == itemID:
            stop()
            return
        default:
            break
        }

        invalidateAndDetachBackend()
        let startGeneration = generation
        state = .loading(itemID: itemID)

        do {
            let backend = try makeBackend(source)
            self.backend = backend
            backend.start { [weak self] event in
                guard let self, self.generation == startGeneration else { return }
                self.handle(event, itemID: itemID)
            }
        } catch {
            state = .failed(
                itemID: itemID,
                message: error.localizedDescription.isEmpty
                    ? "Audio playback failed"
                    : error.localizedDescription
            )
        }
    }

    func stop() {
        invalidateAndDetachBackend()
        state = .idle
    }

    private func handle(_ event: MacToolAudioPlaybackEvent, itemID: String) {
        switch event {
        case .playing:
            state = .playing(itemID: itemID)
        case .finished:
            invalidateAndDetachBackend()
            state = .idle
        case .failed(let message):
            invalidateAndDetachBackend()
            state = .failed(itemID: itemID, message: message)
        }
    }

    private func invalidateAndDetachBackend() {
        // Invalidate first: a backend is allowed to synchronously report an
        // event while stop tears down AVFoundation objects.
        generation &+= 1
        let detached = backend
        backend = nil
        detached?.stop()
    }
}

enum MacToolAudioSourceResolver {
    static let maxDecodedBytes = 10 * 1_024 * 1_024

    static func source(
        media: ToolContentDescriptor.Media,
        sessionID: String?,
        routeScope: SessionRouteScope?,
        ownerToken: String? = MacAPIClient.readOwnerToken(),
        socketPath: String = MacLocalAPISocket.path(
            dataDir: NSString("~/.config/oppi").expandingTildeInPath
        )
    ) -> MacToolAudioSource? {
        if let audio = media.audio, isWAV(audio.mimeType) {
            if !audio.attachmentId.isEmpty,
               let sessionID, !sessionID.isEmpty,
               let token = ownerToken, !token.isEmpty,
               let source = MacOwnerMediaSource.sessionAttachment(
                sessionID: sessionID,
                attachmentID: audio.attachmentId,
                mimeType: audio.mimeType,
                token: token,
                socketPath: socketPath,
                scope: routeScope
               ) {
                return .ownerSocket(source)
            }
            if let base64 = audio.base64, let data = decodeWAV(base64: base64) {
                return .inlineWAV(data)
            }
        }

        if media.filePath == "Voice message",
           let clip = AudioExtractor.extract(from: media.output).first(where: { isWAV($0.mimeType) }),
           let data = decodeWAV(base64: clip.base64) {
            return .inlineWAV(data)
        }
        return nil
    }

    static func decodeWAV(base64: String) -> Data? {
        let normalized = base64
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty,
              normalized.utf8.count <= ((maxDecodedBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: normalized),
              !data.isEmpty,
              data.count <= maxDecodedBytes else {
            return nil
        }
        return data
    }

    private static func isWAV(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let normalized = mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "audio/wav" || normalized == "audio/x-wav"
    }
}

struct MacToolAudioPlaybackButtonPaint: Equatable, Sendable {
    let systemImage: String
    let showsProgress: Bool
    let accessibilityLabel: String
    let help: String
    let isFailure: Bool

    static func make(for phase: MacToolAudioPlaybackPhase) -> Self {
        switch phase {
        case .idle:
            Self(
                systemImage: "play.fill",
                showsProgress: false,
                accessibilityLabel: "Play voice message",
                help: "Play voice message",
                isFailure: false
            )
        case .loading:
            Self(
                systemImage: "stop.fill",
                showsProgress: true,
                accessibilityLabel: "Stop voice message",
                help: "Loading voice message",
                isFailure: false
            )
        case .playing:
            Self(
                systemImage: "stop.fill",
                showsProgress: false,
                accessibilityLabel: "Stop voice message",
                help: "Stop voice message",
                isFailure: false
            )
        case .failed(let message):
            Self(
                systemImage: "exclamationmark.triangle.fill",
                showsProgress: false,
                accessibilityLabel: "Retry voice message",
                help: message,
                isFailure: true
            )
        }
    }
}

struct MacToolAudioPlaybackButtonLabel: View {
    let phase: MacToolAudioPlaybackPhase
    @Environment(\.theme) private var theme

    var body: some View {
        let paint = MacToolAudioPlaybackButtonPaint.make(for: phase)
        ZStack {
            Circle()
                .fill(theme.bg.highlight)
            Circle()
                .stroke(theme.text.tertiary.opacity(0.35), lineWidth: 1)
            if paint.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent.purple)
            } else {
                Image(systemName: paint.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(paint.isFailure ? theme.accent.red : theme.accent.purple)
            }
        }
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .accessibilityLabel(paint.accessibilityLabel)
        .help(paint.help)
    }
}

struct MacToolAudioPlaybackButton: View {
    let itemID: String
    let source: MacToolAudioSource
    var controller: MacToolAudioPlaybackController = .shared

    var body: some View {
        Button {
            controller.toggle(itemID: itemID, source: source)
        } label: {
            MacToolAudioPlaybackButtonLabel(phase: controller.phase(for: itemID))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mac.toolAudioPlayback.\(itemID)")
    }
}

@MainActor
enum MacToolAudioPlaybackBackendFactory {
    static func make(_ source: MacToolAudioSource) throws -> any MacToolAudioPlaybackBackend {
        switch source {
        case .ownerSocket(let source):
            return MacOwnerSocketAudioPlaybackBackend(source: source)
        case .inlineWAV(let data):
            return try MacInlineWAVPlaybackBackend(data: data)
        }
    }
}

@MainActor
private final class MacOwnerSocketAudioPlaybackBackend: MacToolAudioPlaybackBackend {
    private let session: MacAuthenticatedMediaPlaybackSession
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(source: MacAuthenticatedMediaSource) {
        session = MacAuthenticatedMediaPlaybackSession(source: source)
    }

    func start(onEvent: @escaping @MainActor @Sendable (MacToolAudioPlaybackEvent) -> Void) {
        let player = session.player
        guard let item = player.currentItem else {
            onEvent(.failed("Voice message is unavailable"))
            return
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in onEvent(.finished) }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            Task { @MainActor in
                switch item.status {
                case .readyToPlay:
                    player.play()
                    onEvent(.playing)
                case .failed:
                    onEvent(.failed(item.error?.localizedDescription ?? "Voice message failed to load"))
                case .unknown:
                    break
                @unknown default:
                    onEvent(.failed("Voice message failed to load"))
                }
            }
        }
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        session.teardown()
    }
}

@MainActor
private final class MacInlineWAVPlaybackBackend: MacToolAudioPlaybackBackend {
    private let player: AVAudioPlayer
    private var playbackDelegate: MacInlineWAVPlaybackDelegate?

    init(data: Data) throws {
        player = try AVAudioPlayer(data: data)
    }

    func start(onEvent: @escaping @MainActor @Sendable (MacToolAudioPlaybackEvent) -> Void) {
        let playbackDelegate = MacInlineWAVPlaybackDelegate { event in
            Task { @MainActor in onEvent(event) }
        }
        self.playbackDelegate = playbackDelegate
        player.delegate = playbackDelegate
        player.prepareToPlay()
        guard player.play() else {
            onEvent(.failed("Voice message could not start"))
            return
        }
        onEvent(.playing)
    }

    func stop() {
        player.stop()
        player.delegate = nil
        playbackDelegate = nil
    }
}

private final class MacInlineWAVPlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (MacToolAudioPlaybackEvent) -> Void

    init(onEvent: @escaping @Sendable (MacToolAudioPlaybackEvent) -> Void) {
        self.onEvent = onEvent
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onEvent(flag ? .finished : .failed("Voice message playback ended unexpectedly"))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        onEvent(.failed(error?.localizedDescription ?? "Voice message could not be decoded"))
    }
}
