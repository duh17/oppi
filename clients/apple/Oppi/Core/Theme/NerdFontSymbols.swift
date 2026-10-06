import BackgroundAssets
import CoreText
import OSLog
import Synchronization
import System
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "NerdFontSymbols")

/// Nerd Font icon glyphs (Powerline, devicons, Font Awesome, Octicons,
/// Codicons, Material Design) for terminal prompts and tool output.
///
/// The font is not bundled. It ships as the Apple-hosted Background Assets
/// pack `NerdFontSymbols` (prefetch policy, built by
/// `scripts/build-nerd-font-asset-pack.sh` and uploaded to App Store
/// Connect). Once the pack is local, the font is registered for this process
/// and every code font lists it as a cascade fallback, so each family shows
/// the icons without a patched copy. Until then, those code points render as
/// they always have.
@MainActor @Observable
final class NerdFontSymbols {
    static let shared = NerdFontSymbols()

    enum Status: Equatable {
        case checking
        case downloading(fractionCompleted: Double)
        case installed
        case unavailable(String)
    }

    nonisolated static let assetPackID = "NerdFontSymbols"
    /// Path in the shared asset-pack namespace (see the pack's Manifest.json).
    nonisolated static let fontPath = "NerdFontSymbols/SymbolsNerdFontMono-Regular.ttf"
    nonisolated static let postScriptName = "SymbolsNFM"

    private(set) var status: Status = .checking
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Read off the main actor while fonts are built.
    nonisolated private static let fallback = Mutex<UIFontDescriptor?>(nil)

    /// The symbols font itself, once registered. UIKit system fonts (SF Mono)
    /// ignore a custom cascade list when drawing, so a painter that must show
    /// icons with every family draws uncovered private-use characters with this.
    nonisolated static func font(size: CGFloat) -> UIFont? {
        guard fallback.withLock({ $0 }) != nil else { return nil }
        return UIFont(name: postScriptName, size: size)
    }

    /// Nerd Font icons live in the Unicode private-use areas.
    nonisolated static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || scalar.value >= 0xF0000
    }

    /// Adds the symbols font as a cascade fallback once it is registered.
    /// Bundled code fonts honor it in every text view; SF Mono does not.
    nonisolated static func withFallback(_ font: UIFont) -> UIFont {
        guard let symbols = fallback.withLock({ $0 }) else { return font }
        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: [symbols]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    /// Starts once per launch: makes the pack local (downloading it if the
    /// prefetch has not finished) and registers the font. Retry after a failure.
    func load() {
        guard loading == nil, status != .installed else { return }
        loading = Task {
            await makeAvailable()
            loading = nil
        }
    }

    private func makeAvailable() async {
        status = .checking
        let manager = AssetPackManager.shared
        let progress = Task { [weak self] in
            for await update in manager.statusUpdates(forAssetPackWithID: Self.assetPackID) {
                guard case .downloading(_, let progress) = update else { continue }
                self?.status = .downloading(fractionCompleted: progress.fractionCompleted)
            }
        }
        defer { progress.cancel() }
        do {
            let pack = try await manager.assetPack(withID: Self.assetPackID)
            // Returns at once when the pack is already local.
            try await manager.ensureLocalAvailability(of: pack)
            try await install(fontAt: Self.fontURL())
        } catch {
            logger.error("Nerd Font symbols unavailable: \(error.localizedDescription, privacy: .public)")
            status = .unavailable(error.localizedDescription)
        }
    }

    /// Registers the font file for this process and makes it every code
    /// font's fallback.
    func install(fontAt url: URL) async throws {
        try await Self.register(url)
        Self.fallback.withLock { $0 = UIFontDescriptor(fontAttributes: [.name: Self.postScriptName]) }
        status = .installed
        // Same path as a Code Font change: rebuild AppFont, then tell live
        // surfaces (the SSH terminal) to rebuild theirs.
        AppFont.rebuild()
        FontPreferenceStore.notifyDidChange()
    }

    /// `url(for:)` must not run on the main thread.
    nonisolated private static func fontURL() async throws -> URL {
        try AssetPackManager.shared.url(for: FilePath(fontPath))
    }

    nonisolated private static func register(_ url: URL) async throws {
        let failure: String? = await withCheckedContinuation { continuation in
            var message: String?
            CTFontManagerRegisterFontURLs([url] as CFArray, .process, true) { errors, done in
                if let error = (errors as? [CFError])?.first,
                   CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                    message = CFErrorCopyDescription(error) as String
                }
                if done { continuation.resume(returning: message) }
                return true
            }
        }
        if let failure { throw RegistrationError(message: failure) }
        guard UIFont(name: postScriptName, size: 12) != nil else {
            throw RegistrationError(message: "\(postScriptName) did not load from the asset pack")
        }
    }

    private struct RegistrationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
