import Foundation
import Observation

/// Owns one detail request generation so a canceled or superseded response
/// cannot replace a newer resource summary or content.
@MainActor @Observable
final class ServerResourceDetailLoader<Detail> {
    private(set) var target: ServerResourceDetailNavTarget
    private(set) var detail: Detail?
    private(set) var isLoading: Bool
    private(set) var error: String?
    private(set) var usesDetailSummary: Bool

    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(initialDetail: Detail? = nil, target: ServerResourceDetailNavTarget) {
        self.target = target
        self.detail = initialDetail
        self.isLoading = initialDetail == nil
        self.usesDetailSummary = initialDetail != nil
    }

    func load(
        target: ServerResourceDetailNavTarget,
        fetch: @escaping @MainActor () async throws -> Detail
    ) {
        task?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let targetChanged = self.target != target
        self.target = target
        if targetChanged {
            detail = nil
            usesDetailSummary = false
        }
        isLoading = detail == nil
        error = nil

        task = Task { @MainActor [weak self] in
            do {
                let response = try await fetch()
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestGeneration,
                      self.target == target else {
                    return
                }
                self.detail = response
                self.usesDetailSummary = true
                self.error = nil
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestGeneration,
                      self.target == target else {
                    return
                }
                self.error = error.localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }

    /// A successful catalog mutation is authoritative until a later detail GET succeeds.
    func invalidateSummaryAfterAuthoritativeMutation() {
        usesDetailSummary = false
        error = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation &+= 1
        isLoading = false
    }
}

enum ServerResourceDetailLoadError: LocalizedError {
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let serverName):
            "Not connected to \(serverName)."
        }
    }
}
