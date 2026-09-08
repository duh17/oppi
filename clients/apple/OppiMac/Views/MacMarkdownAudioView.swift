@preconcurrency import AVFoundation
import Observation
import SwiftUI

struct MacMarkdownAudioView: View {
    let embed: MarkdownAudioEmbed
    var worktreeId: String? = nil
    @Environment(\.macOpenFileViewer) private var openFileViewer
    @Environment(\.macMarkdownAudioSource) private var sourceProvider
    @Environment(\.theme) private var theme
    @State private var controller = MacMarkdownAudioController()

    private var request: MacMarkdownAudioRequest { .init(embed: embed, worktreeId: worktreeId) }

    var body: some View {
        HStack(spacing: 10) {
            MacMarkdownAudioButton(
                symbol: controller.phase.symbol, label: controller.phase.actionLabel,
                identifier: "markdown-audio.play"
            ) { controller.toggle(request, source: sourceProvider) }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(embed.displayLabel).lineLimit(1)
                Text(controller.phase.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            MacMarkdownAudioButton(
                symbol: "arrow.up.right.square", label: "Open audio file",
                identifier: "markdown-audio.open"
            ) { controller.open(request, source: sourceProvider, action: openFileViewer) }
            .frame(width: 28, height: 32)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg.highlight, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-audio")
        .onChange(of: request, initial: true) { _, next in controller.bind(next) }
        .onDisappear { controller.cancel() }
    }
}

/// AppKit buttons keep the compact strip's media actions keyboard-focusable
/// and exposed as native controls inside the hosted Markdown hierarchy.
private struct MacMarkdownAudioButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let identifier: String
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.press)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
    }
    @MainActor final class Coordinator: NSObject {
        var action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
        @objc func press() { action() }
    }
}

private struct MacMarkdownAudioSourceKey: EnvironmentKey {
    static let defaultValue: MacMarkdownAudioController.SourceProvider = { try await MacMarkdownAudioSource.local($0) }
}

extension EnvironmentValues {
    var macMarkdownAudioSource: MacMarkdownAudioController.SourceProvider {
        get { self[MacMarkdownAudioSourceKey.self] }
        set { self[MacMarkdownAudioSourceKey.self] = newValue }
    }
}

enum MacMarkdownAudioPhase: Equatable {
    case idle, loading, playing, paused, unavailable

    var symbol: String {
        switch self {
        case .idle, .paused: "play.fill"
        case .loading: "stop.fill"
        case .playing: "pause.fill"
        case .unavailable: "arrow.clockwise"
        }
    }
    var actionLabel: String {
        switch self {
        case .idle, .paused: "Play audio"
        case .loading: "Cancel audio loading"
        case .playing: "Pause audio"
        case .unavailable: "Retry audio"
        }
    }
    var status: String {
        switch self {
        case .idle: "Audio"
        case .loading: "Loading audio…"
        case .playing: "Playing"
        case .paused: "Paused"
        case .unavailable: "Audio unavailable"
        }
    }
}

enum MacMarkdownAudioEvent: Sendable { case ready, finished, failed }

@MainActor
protocol MacMarkdownAudioBackend: AnyObject {
    func start(_ event: @escaping @MainActor @Sendable (MacMarkdownAudioEvent) -> Void)
    func play()
    func pause()
    func teardown()
}

/// No source lookup or player creation on mount. Every ready callback is gated
/// by the same generation as the explicit play, including after row removal.
@MainActor @Observable
final class MacMarkdownAudioController {
    typealias SourceProvider = @MainActor @Sendable (MacMarkdownAudioRequest) async throws -> MacMarkdownAudioSource.Resolved
    typealias BackendFactory = @MainActor (MacAuthenticatedMediaSource) -> any MacMarkdownAudioBackend
    private(set) var phase: MacMarkdownAudioPhase = .idle
    @ObservationIgnored private(set) var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var request: MacMarkdownAudioRequest?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var backend: (any MacMarkdownAudioBackend)?
    @ObservationIgnored private let makeBackend: BackendFactory

    init(makeBackend: @escaping BackendFactory = { MacMarkdownAudioSession(source: $0) }) {
        self.makeBackend = makeBackend
    }

    func bind(_ request: MacMarkdownAudioRequest) {
        guard self.request != request else { return }
        cancel()
        self.request = request
    }

    func toggle(_ request: MacMarkdownAudioRequest, source: @escaping SourceProvider) {
        bind(request)
        switch phase {
        case .loading: cancel(); return
        case .playing: backend?.pause(); phase = .paused; return
        case .paused: backend?.play(); phase = .playing; return
        case .idle, .unavailable: break
        }
        cancel()
        phase = .loading
        let current = generation
        pendingTask = Task { [weak self] in
            do {
                let resolved = try await source(request)
                guard let self, !Task.isCancelled, generation == current else { return }
                let backend = makeBackend(resolved.media)
                self.backend = backend
                backend.start { [weak self] event in
                    guard let self, generation == current else { return }
                    switch event {
                    case .ready:
                        guard phase == .loading else { return }
                        self.backend?.play()
                        phase = .playing
                    case .finished: cancel()
                    case .failed: cancel(); phase = .unavailable
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                cancel()
                phase = .unavailable
            }
        }
    }

    func open(_ request: MacMarkdownAudioRequest, source: @escaping SourceProvider, action: MacOpenFileViewerAction) {
        bind(request)
        cancel()
        phase = .loading
        let current = generation
        pendingTask = Task { [weak self] in
            do {
                let resolved = try await source(request)
                guard let self, !Task.isCancelled, generation == current else { return }
                cancel()
                action(resolved.filePlan)
            } catch {
                guard let self, !Task.isCancelled, generation == current else { return }
                cancel()
                phase = .unavailable
            }
        }
    }

    func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        let old = backend
        backend = nil
        old?.teardown()
        phase = .idle
    }
}

@MainActor
private final class MacMarkdownAudioSession: MacMarkdownAudioBackend {
    private let session: MacAuthenticatedMediaPlaybackSession
    private var observation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    init(source: MacAuthenticatedMediaSource) {
        session = MacAuthenticatedMediaPlaybackSession(source: source)
    }

    func start(_ event: @escaping @MainActor @Sendable (MacMarkdownAudioEvent) -> Void) {
        guard let item = session.player.currentItem else { event(.failed); return }
        observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            let status = item.status
            Task { @MainActor in
                switch status {
                case .readyToPlay: event(.ready)
                case .failed: event(.failed)
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in Task { @MainActor in event(.finished) } }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { _ in Task { @MainActor in event(.failed) } }
    }

    func play() { session.player.play() }
    func pause() { session.player.pause() }
    func teardown() {
        observation?.invalidate()
        observation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        session.teardown()
    }
}
