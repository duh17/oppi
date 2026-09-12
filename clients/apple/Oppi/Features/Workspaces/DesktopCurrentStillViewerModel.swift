import Foundation
import Observation

enum DesktopCurrentStillViewerFailure: Equatable, Sendable {
    case remoteViewOff
    case noneAvailable
    case companionDown
    case unavailable

    init(_ error: Error) {
        guard let apiError = error as? APIError else {
            self = .unavailable
            return
        }
        switch apiError {
        case .server(let status, _), .codedServer(let status, _, _):
            switch status {
            case 403:
                self = .remoteViewOff
            case 404:
                self = .noneAvailable
            case 502:
                self = .companionDown
            default:
                self = .unavailable
            }
        case .invalidResponse:
            self = .unavailable
        }
    }

    /// Explains the Mac-side grant instead of showing an HTTP status as the only copy.
    var message: String {
        switch self {
        case .remoteViewOff:
            "Remote view is off on the Mac. In Oppi Desktop Companion, turn on Allow paired devices to view this still."
        case .noneAvailable:
            "No still is available. Capture one in Oppi Desktop Companion, then allow paired devices to view it."
        case .companionDown:
            "Oppi Desktop Companion is not running. Open it on the Mac, then retry."
        case .unavailable:
            "Couldn't load the Mac still. Check Oppi Desktop Companion, then retry."
        }
    }
}

enum DesktopCurrentStillViewerPhase: Equatable, Sendable {
    case loading
    case loaded(DesktopCurrentStill)
    case failed(DesktopCurrentStillViewerFailure)
}

/// Fetches the current remote-shared Mac still. Refresh refetches only; it never recaptures.
@MainActor
@Observable
final class DesktopCurrentStillViewerModel {
    private(set) var phase: DesktopCurrentStillViewerPhase = .loading

    private let fetchCurrent: @Sendable () async throws -> DesktopCurrentStill
    private var generation = 0

    var still: DesktopCurrentStill? {
        if case .loaded(let still) = phase { return still }
        return nil
    }

    var failure: DesktopCurrentStillViewerFailure? {
        if case .failed(let failure) = phase { return failure }
        return nil
    }

    private var inFlight = false

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    /// True while a refetch is running on a loaded or failed screen. Do not swap to ProgressView.
    var isRefreshing: Bool { inFlight && !isLoading }

    var canRetry: Bool {
        !inFlight && !isLoading
    }

    init(fetchCurrent: @escaping @Sendable () async throws -> DesktopCurrentStill) {
        self.fetchCurrent = fetchCurrent
    }

    func load() async {
        generation += 1
        let currentGeneration = generation
        let previous = phase
        inFlight = true
        // Keep loaded/failed chrome mounted during refetch so pull-to-refresh
        // cannot cancel into a stuck ProgressView. Initial load stays .loading.
        do {
            let still = try await fetchCurrent()
            guard currentGeneration == generation else { return }
            inFlight = false
            phase = .loaded(still)
        } catch is CancellationError {
            finishCanceled(previous: previous, generation: currentGeneration)
        } catch let urlError as URLError where urlError.code == .cancelled {
            finishCanceled(previous: previous, generation: currentGeneration)
        } catch {
            guard currentGeneration == generation else { return }
            inFlight = false
            phase = .failed(DesktopCurrentStillViewerFailure(error))
        }
    }

    private func finishCanceled(
        previous: DesktopCurrentStillViewerPhase,
        generation currentGeneration: Int
    ) {
        guard currentGeneration == generation else { return }
        inFlight = false
        if case .loading = previous {
            phase = .failed(.unavailable)
        }
    }

    func refresh() async {
        await load()
    }
}
