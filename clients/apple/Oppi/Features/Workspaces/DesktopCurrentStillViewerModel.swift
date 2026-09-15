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

enum DesktopViewGrantStatus: Equatable, Sendable {
    case none
    case granted(expiresAt: Date)
    case notGranted

    init(_ error: Error) {
        guard let apiError = error as? APIError else {
            self = .none
            return
        }
        switch apiError {
        case .codedServer(_, _, let code) where code == "view_grant_not_bound":
            self = .notGranted
        case .codedServer, .server, .invalidResponse:
            self = .none
        }
    }

    var message: String {
        switch self {
        case .none:
            "No view session."
        case .granted(let expiresAt):
            "Granted to this device until \(expiresAt.formatted(date: .abbreviated, time: .standard))."
        case .notGranted:
            "View session is not granted to this device."
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
    private(set) var viewGrantStatus: DesktopViewGrantStatus = .none

    private let fetchCurrent: @Sendable () async throws -> DesktopCurrentStill
    private let fetchViewSession: (@Sendable () async throws -> DesktopViewSession)?
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

    init(
        fetchCurrent: @escaping @Sendable () async throws -> DesktopCurrentStill,
        fetchViewSession: (@Sendable () async throws -> DesktopViewSession)? = nil
    ) {
        self.fetchCurrent = fetchCurrent
        self.fetchViewSession = fetchViewSession
    }

    func load() async {
        generation += 1
        let currentGeneration = generation
        let previous = phase
        let previousStatus = viewGrantStatus
        inFlight = true
        // Keep loaded/failed chrome mounted during refetch so pull-to-refresh
        // cannot cancel into a stuck ProgressView. Initial load stays .loading.
        do {
            let still = try await fetchCurrent()
            guard currentGeneration == generation else { return }
            phase = .loaded(still)
            await loadViewGrantStatus(generation: currentGeneration, previous: previousStatus)
            guard currentGeneration == generation else { return }
            inFlight = false
        } catch is CancellationError {
            finishCanceled(previous: previous, generation: currentGeneration)
        } catch let urlError as URLError where urlError.code == .cancelled {
            finishCanceled(previous: previous, generation: currentGeneration)
        } catch {
            guard currentGeneration == generation else { return }
            phase = .failed(DesktopCurrentStillViewerFailure(error))
            await loadViewGrantStatus(generation: currentGeneration, previous: previousStatus)
            guard currentGeneration == generation else { return }
            inFlight = false
        }
    }

    private func loadViewGrantStatus(
        generation currentGeneration: Int,
        previous: DesktopViewGrantStatus
    ) async {
        guard let fetchViewSession else { return }
        do {
            let session = try await fetchViewSession()
            guard currentGeneration == generation else { return }
            viewGrantStatus = .granted(expiresAt: session.expiresAt)
        } catch is CancellationError {
            guard currentGeneration == generation else { return }
            viewGrantStatus = previous
        } catch let urlError as URLError where urlError.code == .cancelled {
            guard currentGeneration == generation else { return }
            viewGrantStatus = previous
        } catch {
            guard currentGeneration == generation else { return }
            viewGrantStatus = DesktopViewGrantStatus(error)
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
