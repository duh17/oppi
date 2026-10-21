import Foundation
import Observation
import UIKit

/// Reads a host's colors over a terminal's side channel and holds what it found.
/// A cached read is the starting point, so the terminal is colored before the
/// first command returns; the read that follows replaces it.
@MainActor @Observable
final class SSHTerminalColorLoader {
    /// One side command on the terminal's connection.
    typealias Run = @MainActor (String) async throws -> SSHExecResult

    private(set) var resolution: SSHTerminalColorResolution?
    /// What the terminal paints with; nil is the app's own theme.
    var theme: SSHTerminalColorTheme? { resolution?.theme }

    @ObservationIgnored private let profileID: UUID?
    @ObservationIgnored private let store: SSHTerminalColorStore

    init(profileID: UUID?, choice: SSHTerminalColorChoice, store: SSHTerminalColorStore = SSHTerminalColorStore()) {
        self.profileID = profileID
        self.store = store
        resolution = Self.starting(profileID: profileID, choice: choice, store: store)
    }

    /// The choice changed: the cached read for the new one, or the app's theme.
    func use(_ choice: SSHTerminalColorChoice) {
        guard resolution?.choice != choice else { return }
        resolution = Self.starting(profileID: profileID, choice: choice, store: store)
    }

    private static func starting(profileID: UUID?, choice: SSHTerminalColorChoice, store: SSHTerminalColorStore) -> SSHTerminalColorResolution? {
        if choice == .oppi { return SSHTerminalColorResolution(choice: .oppi, theme: nil, missing: nil) }
        return profileID.flatMap { store.cached(for: $0, choice: choice) }
    }

    /// Reads the host once. A connection that fails mid-read leaves the colors as they were.
    func load(choice: SSHTerminalColorChoice, dark: Bool, run: Run) async {
        guard let found = await Self.read(choice: choice, dark: dark, run: run), !Task.isCancelled else { return }
        resolution = found
        if let profileID { store.cache(found, for: profileID) }
    }

    private enum ThemeRead {
        case failed
        case missing
        case found(SSHTerminalGhosttyConfig.Parsed)
    }

    /// Nil when the connection failed: nothing was learned.
    nonisolated static func read(choice: SSHTerminalColorChoice, dark: Bool, run: Run) async -> SSHTerminalColorResolution? {
        func resolution(_ theme: SSHTerminalColorTheme, missing: String?) -> SSHTerminalColorResolution {
            SSHTerminalColorResolution(choice: choice, theme: theme.isEmpty ? nil : theme, missing: missing)
        }
        switch choice {
        case .oppi:
            return SSHTerminalColorResolution(choice: choice, theme: nil, missing: nil)
        case let .named(name):
            switch await themeFile(name, run: run) {
            case .failed: return nil
            case .missing: return resolution(.init(), missing: name)
            case let .found(file):
                let theme = SSHTerminalGhosttyConfig.resolve(config: .init(), themeFile: file, themeName: name)
                return resolution(theme, missing: theme.isEmpty ? name : nil)
            }
        case .host:
            guard let result = try? await run(SSHTerminalGhosttyRemote.configCommand()),
                  result.exitStatus == 0 else { return nil }
            let config = SSHTerminalGhosttyConfig.parse(result.output)
            guard let name = config.theme?.name(dark: dark) else {
                return resolution(SSHTerminalGhosttyConfig.resolve(config: config, themeFile: nil, themeName: nil), missing: nil)
            }
            switch await themeFile(name, run: run) {
            case .failed: return nil
            case .missing: return resolution(SSHTerminalGhosttyConfig.resolve(config: config, themeFile: nil, themeName: nil), missing: name)
            case let .found(file):
                return resolution(SSHTerminalGhosttyConfig.resolve(config: config, themeFile: file, themeName: name), missing: nil)
            }
        }
    }

    private nonisolated static func themeFile(_ name: String, run: Run) async -> ThemeRead {
        guard SSHTerminalGhosttyConfig.isReadableThemeName(name) else { return .missing }
        guard let result = try? await run(SSHTerminalGhosttyRemote.themeCommand(name)) else { return .failed }
        guard result.exitStatus == 0 else { return .missing }
        return .found(SSHTerminalGhosttyConfig.parse(result.output))
    }

    /// The themes the host can offer: its own folder, then the bundled ones.
    nonisolated static func listThemes(run: Run) async -> [String]? {
        guard let result = try? await run(SSHTerminalGhosttyRemote.listCommand()), result.exitStatus == 0 else { return nil }
        return SSHTerminalGhosttyRemote.parseThemeList(result.output)
    }
}

extension UIColor {
    convenience init(_ rgb: SSHTerminalRGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
