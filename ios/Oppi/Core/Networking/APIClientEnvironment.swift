import SwiftUI

// MARK: - Environment key for APIClient

/// Allows views that only need REST access to depend on `APIClient` directly
/// instead of observing all 95+ properties on `ServerConnection`.
///
/// Usage:
///   @Environment(\.apiClient) private var apiClient
///
/// Injected at the app root alongside other stores.
/// Since `APIClient` is an actor (not `@Observable`), a custom key is required.
private struct APIClientKey: EnvironmentKey {
    static let defaultValue: APIClient? = nil
}

extension EnvironmentValues {
    var apiClient: APIClient? {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }
}
