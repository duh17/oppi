import Foundation
import Testing
@testable import Oppi

@MainActor
@Suite("Mac tool audio playback")
struct MacToolAudioPlaybackControllerTests {
    @Test func toggleMovesThroughLoadingPlayingAndStop() throws {
        let harness = PlaybackHarness()
        let controller = MacToolAudioPlaybackController(makeBackend: harness.makeBackend)
        let source = MacToolAudioSource.inlineWAV(Data([0, 1, 2]))

        controller.toggle(itemID: "voice-1", source: source)
        #expect(controller.state == .loading(itemID: "voice-1"))

        let backend = try #require(harness.backends.first)
        backend.send(.playing)
        #expect(controller.state == .playing(itemID: "voice-1"))

        controller.toggle(itemID: "voice-1", source: source)
        #expect(controller.state == .idle)
        #expect(backend.stopCount == 1)
    }

    @Test func startingAnotherRowStopsPreviousAndIgnoresItsLateCompletion() throws {
        let harness = PlaybackHarness()
        let controller = MacToolAudioPlaybackController(makeBackend: harness.makeBackend)
        let source = MacToolAudioSource.inlineWAV(Data([0, 1, 2]))

        controller.toggle(itemID: "voice-a", source: source)
        let first = try #require(harness.backends.first)
        first.send(.playing)
        controller.toggle(itemID: "voice-b", source: source)

        #expect(first.stopCount == 1)
        #expect(controller.state == .loading(itemID: "voice-b"))
        first.send(.finished)
        #expect(controller.state == .loading(itemID: "voice-b"))
    }

    @Test func startingAnotherRowWhileFirstIsLoadingStartsSecond() throws {
        let harness = PlaybackHarness()
        let controller = MacToolAudioPlaybackController(makeBackend: harness.makeBackend)
        let source = MacToolAudioSource.inlineWAV(Data([0, 1, 2]))

        controller.toggle(itemID: "voice-a", source: source)
        let first = try #require(harness.backends.first)
        controller.toggle(itemID: "voice-b", source: source)

        #expect(first.stopCount == 1)
        #expect(controller.state == .loading(itemID: "voice-b"))
        #expect(harness.backends.count == 2)
    }

    @Test func failurePaintsRetryAndRetryCreatesFreshBackend() throws {
        let harness = PlaybackHarness()
        let controller = MacToolAudioPlaybackController(makeBackend: harness.makeBackend)
        let source = MacToolAudioSource.inlineWAV(Data([0, 1, 2]))

        controller.toggle(itemID: "voice-1", source: source)
        let first = try #require(harness.backends.first)
        first.send(.failed("Could not decode WAV"))

        #expect(controller.state == .failed(itemID: "voice-1", message: "Could not decode WAV"))
        #expect(controller.phase(for: "voice-1") == .failed("Could not decode WAV"))

        controller.toggle(itemID: "voice-1", source: source)
        #expect(controller.state == .loading(itemID: "voice-1"))
        #expect(harness.backends.count == 2)
    }

    @Test func backendFactoryFailureIsVisibleAndFinishReturnsToIdle() throws {
        let source = MacToolAudioSource.inlineWAV(Data([0, 1, 2]))
        let failing = MacToolAudioPlaybackController { _ in
            throw PlaybackTestError.cannotStart
        }
        failing.toggle(itemID: "voice-fail", source: source)
        #expect(failing.phase(for: "voice-fail") == .failed("Playback could not start"))

        let harness = PlaybackHarness()
        let finishing = MacToolAudioPlaybackController(makeBackend: harness.makeBackend)
        finishing.toggle(itemID: "voice-finish", source: source)
        let backend = try #require(harness.backends.first)
        backend.send(.finished)
        #expect(finishing.state == .idle)
    }

    @Test func resolverUsesRouteScopedAttachmentAndNeverLeaksOwnerToken() throws {
        let media = voiceMedia(attachmentID: "att 9", base64: nil)
        let control = try #require(MacToolAudioSourceResolver.source(
            media: media,
            sessionID: "sess-1",
            routeScope: .control,
            ownerToken: "sk_secret",
            socketPath: "/tmp/oppi.sock"
        ))
        let workspace = try #require(MacToolAudioSourceResolver.source(
            media: media,
            sessionID: "sess-1",
            routeScope: .workspace("ws-1"),
            ownerToken: "sk_secret",
            socketPath: "/tmp/oppi.sock"
        ))

        guard case .ownerSocket(let controlSource) = control,
              case .ownerSocket(let workspaceSource) = workspace else {
            Issue.record("Expected owner-socket attachment sources")
            return
        }
        #expect(controlSource.requestPath == "/control-sessions/sess-1/attachments/att%209")
        #expect(workspaceSource.requestPath == "/sessions/sess-1/attachments/att%209")
        #expect(!controlSource.identity.contains("sk_secret"))
        #expect(!workspaceSource.identity.contains("sk_secret"))
    }

    @Test func resolverDecodesDescriptorAndDataURIWAVButRejectsInvalidOrOversizedAudio() throws {
        let wav = Data([82, 73, 70, 70, 1, 2, 3, 4])
        let descriptor = try #require(MacToolAudioSourceResolver.source(
            media: voiceMedia(attachmentID: "", base64: wav.base64EncodedString()),
            sessionID: nil,
            routeScope: nil,
            ownerToken: nil
        ))
        let dataURI = try #require(MacToolAudioSourceResolver.source(
            media: ToolContentDescriptor.Media(
                output: "Transcript\ndata:audio/wav;base64,\(wav.base64EncodedString())",
                filePath: "Voice message",
                startLine: 1,
                attachments: [],
                audio: nil
            ),
            sessionID: nil,
            routeScope: nil,
            ownerToken: nil
        ))

        guard case .inlineWAV(let descriptorData) = descriptor,
              case .inlineWAV(let uriData) = dataURI else {
            Issue.record("Expected inline WAV sources")
            return
        }
        #expect(descriptorData == wav)
        #expect(uriData == wav)
        #expect(MacToolAudioSourceResolver.source(
            media: voiceMedia(attachmentID: "", base64: "not-base64"),
            sessionID: nil,
            routeScope: nil,
            ownerToken: nil
        ) == nil)
        #expect(MacToolAudioSourceResolver.source(
            media: ToolContentDescriptor.Media(
                output: "data:audio/wav;base64,\(wav.base64EncodedString())",
                filePath: "recording.wav",
                startLine: 1,
                attachments: [],
                audio: nil
            ),
            sessionID: nil,
            routeScope: nil,
            ownerToken: nil
        ) == nil)
        #expect(MacToolAudioSourceResolver.decodeWAV(
            base64: Data(repeating: 0, count: 10 * 1_024 * 1_024 + 1).base64EncodedString()
        ) == nil)
    }

    @Test func buttonPaintCoversAllFourInteractiveStates() {
        #expect(MacToolAudioPlaybackButtonPaint.make(for: .idle).systemImage == "play.fill")
        #expect(MacToolAudioPlaybackButtonPaint.make(for: .loading).showsProgress)
        #expect(MacToolAudioPlaybackButtonPaint.make(for: .playing).systemImage == "stop.fill")
        let failure = MacToolAudioPlaybackButtonPaint.make(for: .failed("Broken audio"))
        #expect(failure.systemImage == "exclamationmark.triangle.fill")
        #expect(failure.accessibilityLabel == "Retry voice message")
        #expect(failure.help == "Broken audio")
    }

    @Test func timelineHeaderPlacesRealAudioControlBeforeDisclosureAndKeepsRouteScope() throws {
        let timeline = try source(named: "OppiMac/Views/MacSessionTimelineViews.swift")
        let headerStart = try #require(timeline.range(of: "private var header: some View"))
        let summaryStart = try #require(
            timeline.range(of: "private var headerSummary: some View", range: headerStart.upperBound..<timeline.endIndex)
        )
        let headerEnd = try #require(
            timeline.range(of: "private var headerTitle: some View", range: summaryStart.upperBound..<timeline.endIndex)
        )
        let header = String(timeline[headerStart.lowerBound..<summaryStart.lowerBound])
        let summary = String(timeline[summaryStart.lowerBound..<headerEnd.lowerBound])
        let audioButton = try #require(header.range(of: "MacToolAudioPlaybackButton"))
        let disclosure = try #require(header.range(of: "if canExpand"))

        #expect(audioButton.lowerBound < disclosure.lowerBound)
        #expect(!header.contains("accessibilityElement(children: .combine)"))
        #expect(summary.contains("accessibilityElement(children: .ignore)"))
        #expect(summary.contains("accessibilityLabel(headerAccessibilityLabel)"))
        #expect(!summary.contains("MacToolAudioPlaybackButton"))
        #expect(timeline.contains("routeScope: store.selectedTarget?.routeScope"))
        #expect(timeline.contains("itemID: itemID"))
        #expect(timeline.contains("MacToolAudioSourceResolver.source"))
    }

    private func voiceMedia(attachmentID: String, base64: String?) -> ToolContentDescriptor.Media {
        ToolContentDescriptor.Media(
            output: "Voice message",
            filePath: nil,
            startLine: 1,
            attachments: [],
            audio: ToolContentDescriptor.AudioMessage(
                text: "Voice message",
                attachmentId: attachmentID,
                mimeType: "audio/wav",
                durationSeconds: 1.5,
                playbackBehavior: nil,
                base64: base64
            )
        )
    }

    private func source(named relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
private final class PlaybackHarness {
    private(set) var backends: [PlaybackBackendSpy] = []

    func makeBackend(_ source: MacToolAudioSource) throws -> any MacToolAudioPlaybackBackend {
        let backend = PlaybackBackendSpy()
        backends.append(backend)
        return backend
    }
}

@MainActor
private final class PlaybackBackendSpy: MacToolAudioPlaybackBackend {
    private var onEvent: (@MainActor @Sendable (MacToolAudioPlaybackEvent) -> Void)?
    private(set) var stopCount = 0

    func start(onEvent: @escaping @MainActor @Sendable (MacToolAudioPlaybackEvent) -> Void) {
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
    }

    func send(_ event: MacToolAudioPlaybackEvent) {
        onEvent?(event)
    }
}

private enum PlaybackTestError: LocalizedError {
    case cannotStart

    var errorDescription: String? { "Playback could not start" }
}
