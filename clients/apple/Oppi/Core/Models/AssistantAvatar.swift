import Foundation
import UIKit

/// Avatar style for the assistant icon in chat bubbles and empty state.
enum AssistantAvatar: Equatable, Sendable {
    /// Official Pi logo mark from pi.dev.
    case officialPi
    /// Classic π text character.
    case piText
    /// Game of Life grid forming π — unique per session.
    case golGrid
    /// User-chosen emoji character.
    case emoji(String)
    /// Apple Genmoji. Image content is validated before persistence and paired
    /// with its picker-provided description so accessibility never has to rebuild it.
    @available(iOS 18.0, *)
    case genmoji(data: Data, contentDescription: String)

    var displayName: String {
        switch self {
        case .officialPi: return "Official Pi"
        case .piText: return "Classic π"
        case .golGrid: return "Grid π"
        case .emoji(let char): return char
        case .genmoji: return "Genmoji"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .officialPi, .piText, .golGrid:
            return displayName
        case .emoji(let value):
            return "Emoji \(value)"
        case .genmoji(_, let contentDescription):
            return contentDescription
        }
    }

    var pickerDescription: String? {
        switch self {
        case .officialPi:
            return "Official Pi logo"
        case .piText:
            return "Monospaced assistant glyph"
        case .golGrid:
            return "Game of Life grid with spark cells"
        case .emoji, .genmoji:
            return nil
        }
    }

    var cacheIdentifier: String {
        switch self {
        case .officialPi:
            return "officialPi"
        case .piText:
            return "piText"
        case .golGrid:
            return "golGrid"
        case .emoji(let char):
            return "emoji:\(char)"
        case .genmoji:
            // Persisted snapshots carry a one-time fingerprint. This fallback
            // identity deliberately never hashes image bytes on a row update.
            return "genmoji"
        }
    }

    /// Built-in choices for the picker (not including user-set emoji/genmoji).
    static let builtinCases: [AssistantAvatar] = [.officialPi, .piText, .golGrid]

    enum PersistenceError: LocalizedError, Equatable {
        case invalidEmoji
        case invalidGenmojiData
        case invalidGenmojiDescription

        var errorDescription: String? {
            switch self {
            case .invalidEmoji:
                return "Choose exactly one Unicode emoji."
            case .invalidGenmojiData:
                return "The selected Genmoji image could not be validated. Please choose it again."
            case .invalidGenmojiDescription:
                return "The selected Genmoji needs a valid description. Please choose it again."
            }
        }
    }

    @MainActor private static let persistence = AssistantAvatarPersistence(defaults: .standard)

    /// The in-memory persisted avatar snapshot. Its identity is derived once at
    /// load time, so mounted rows never hash or compare Genmoji bytes.
    @MainActor
    static var currentSnapshot: AssistantAvatarSnapshot {
        persistence.snapshot
    }

    @MainActor
    static var current: AssistantAvatar {
        currentSnapshot.avatar
    }

    /// Call when another process or a test changes the defaults directly.
    /// Normal writes use `setCurrent(_:)` and replace the snapshot themselves.
    @MainActor
    static func reloadAfterExternalChange() {
        persistence.invalidate()
        NotificationCenter.default.post(name: .assistantAvatarDidChange, object: nil)
    }

    /// Validates a draft before a picker commits it. The default persistence
    /// instance retains the resulting decode when it later commits the same value.
    @MainActor
    static func prepareForPersistence(_ avatar: AssistantAvatar) throws -> AssistantAvatar {
        try persistence.prepare(avatar)
    }

    /// Validates the complete value before the first UserDefaults mutation.
    /// Rejection is observable and leaves both persisted state and listeners unchanged.
    @MainActor
    @discardableResult
    static func setCurrent(_ avatar: AssistantAvatar) throws -> AssistantAvatar {
        let persisted = try persistence.setCurrent(avatar)
        NotificationCenter.default.post(name: .assistantAvatarDidChange, object: nil)
        return persisted
    }

    /// Returns the already-validated raster for the device-local persisted
    /// Genmoji without comparing its bytes. Draft renderers must decode their
    /// own input instead.
    @MainActor
    static func cachedImage(for avatar: AssistantAvatar) -> UIImage? {
        persistence.image(for: avatar)
    }
}

/// A loaded persisted value plus its lightweight cache identity and decoded image.
/// UIKit row rendering stays on the main actor, as does `UIImage` access.
@MainActor
struct AssistantAvatarSnapshot {
    let avatar: AssistantAvatar
    let cacheIdentifier: String
    let image: UIImage?

    init(avatar: AssistantAvatar, cacheIdentifier: String? = nil, image: UIImage? = nil) {
        self.avatar = avatar
        self.cacheIdentifier = cacheIdentifier ?? avatar.cacheIdentifier
        self.image = image
    }
}

/// Owns device-local assistant-avatar persistence and its bounded Genmoji cache.
/// The injected read/fingerprint/decode boundaries keep the row hot path testable.
@MainActor
final class AssistantAvatarPersistence {
    typealias Decode = @MainActor (Data) -> UIImage?
    typealias Read = @MainActor () -> Source
    typealias Fingerprint = @MainActor (Data) -> String

    private static let typeKey = "assistantAvatarType"
    private static let emojiKey = "assistantAvatarEmoji"
    private static let genmojiKey = "assistantAvatarGenmoji"
    private static let genmojiDescriptionKey = "assistantAvatarGenmojiDescription"
    private static let maximumGenmojiBytes = 2 * 1_024 * 1_024

    struct Source {
        let type: String
        let emoji: String?
        let genmojiData: Data?
        let genmojiDescription: String?

        init(type: String, emoji: String?, genmojiData: Data?, genmojiDescription: String?) {
            self.type = type
            self.emoji = emoji
            self.genmojiData = genmojiData
            self.genmojiDescription = genmojiDescription
        }
    }

    private let defaults: UserDefaults?
    private let read: Read
    private let fingerprint: Fingerprint
    private let decode: Decode
    private var cached: AssistantAvatarSnapshot?
    private var preparedDraft: (avatar: AssistantAvatar, image: UIImage?)?

    init(defaults: UserDefaults, decode: @escaping Decode = AssistantAvatarPersistence.decodeHEIF) {
        self.defaults = defaults
        read = {
            Source(
                type: defaults.string(forKey: Self.typeKey) ?? "piText",
                emoji: defaults.string(forKey: Self.emojiKey),
                genmojiData: defaults.data(forKey: Self.genmojiKey),
                genmojiDescription: defaults.string(forKey: Self.genmojiDescriptionKey)
            )
        }
        fingerprint = Self.fingerprint
        self.decode = decode
    }

    init(read: @escaping Read, fingerprint: @escaping Fingerprint, decode: @escaping Decode) {
        defaults = nil
        self.read = read
        self.fingerprint = fingerprint
        self.decode = decode
    }

    var snapshot: AssistantAvatarSnapshot {
        if let cached { return cached }
        return load(source: read())
    }

    var current: AssistantAvatar {
        snapshot.avatar
    }

    func invalidate() {
        cached = nil
        preparedDraft = nil
    }

    func image(for avatar: AssistantAvatar) -> UIImage? {
        guard case .genmoji = avatar,
              case .genmoji = cached?.avatar else {
            return nil
        }
        return cached?.image
    }

    func prepare(_ avatar: AssistantAvatar) throws -> AssistantAvatar {
        let prepared = try prepared(avatar)
        preparedDraft = prepared
        return prepared.avatar
    }

    @discardableResult
    func setCurrent(_ avatar: AssistantAvatar) throws -> AssistantAvatar {
        let preparedValue: (avatar: AssistantAvatar, image: UIImage?)
        if let preparedDraft, preparedDraft.avatar == avatar {
            preparedValue = preparedDraft
        } else {
            preparedValue = try prepared(avatar)
        }
        self.preparedDraft = nil
        guard let defaults else {
            cached = makeSnapshot(avatar: preparedValue.avatar, image: preparedValue.image)
            return preparedValue.avatar
        }

        switch preparedValue.avatar {
        case .officialPi:
            persistBuiltin("officialPi", defaults: defaults)
        case .piText:
            persistBuiltin("piText", defaults: defaults)
        case .golGrid:
            persistBuiltin("golGrid", defaults: defaults)
        case .emoji(let emoji):
            defaults.set("emoji", forKey: Self.typeKey)
            defaults.set(emoji, forKey: Self.emojiKey)
            clearGenmojiPersistence(defaults: defaults)
        case .genmoji(let data, let contentDescription):
            defaults.set("genmoji", forKey: Self.typeKey)
            defaults.set(data, forKey: Self.genmojiKey)
            defaults.set(contentDescription, forKey: Self.genmojiDescriptionKey)
        }
        cached = makeSnapshot(avatar: preparedValue.avatar, image: preparedValue.image)
        return preparedValue.avatar
    }

    private func load(source: Source) -> AssistantAvatarSnapshot {
        switch source.type {
        case "officialPi":
            return cache(avatar: .officialPi, image: nil)
        case "piText":
            return cache(avatar: .piText, image: nil)
        case "golGrid":
            return cache(avatar: .golGrid, image: nil)
        case "emoji":
            guard case .emoji(let emoji) = AgentIconValue.classify(source.emoji) else {
                return normalizeToPiText()
            }
            return cache(avatar: .emoji(emoji), image: nil)
        case "genmoji":
            guard #available(iOS 18.0, *),
                  let data = source.genmojiData,
                  !data.isEmpty,
                  data.count <= Self.maximumGenmojiBytes,
                  let contentDescription = validGenmojiDescription(source.genmojiDescription),
                  let decoded = decode(data) else {
                return normalizeToPiText()
            }
            return cache(
                avatar: .genmoji(data: data, contentDescription: contentDescription),
                image: decoded
            )
        default:
            return normalizeToPiText()
        }
    }

    private func cache(avatar: AssistantAvatar, image: UIImage?) -> AssistantAvatarSnapshot {
        let snapshot = makeSnapshot(avatar: avatar, image: image)
        cached = snapshot
        return snapshot
    }

    private func makeSnapshot(avatar: AssistantAvatar, image: UIImage?) -> AssistantAvatarSnapshot {
        let identity: String
        switch avatar {
        case .genmoji(let data, _):
            identity = "genmoji:\(fingerprint(data))"
        default:
            identity = avatar.cacheIdentifier
        }
        return AssistantAvatarSnapshot(avatar: avatar, cacheIdentifier: identity, image: image)
    }

    private func normalizeToPiText() -> AssistantAvatarSnapshot {
        if let defaults {
            persistBuiltin("piText", defaults: defaults)
        }
        return cache(avatar: .piText, image: nil)
    }

    private func prepared(_ avatar: AssistantAvatar) throws -> (avatar: AssistantAvatar, image: UIImage?) {
        switch avatar {
        case .officialPi, .piText, .golGrid:
            return (avatar, nil)
        case .emoji(let rawValue):
            guard case .emoji(let emoji) = AgentIconValue.classify(rawValue) else {
                throw AssistantAvatar.PersistenceError.invalidEmoji
            }
            return (.emoji(emoji), nil)
        case .genmoji(let data, let contentDescription):
            guard !data.isEmpty, data.count <= Self.maximumGenmojiBytes,
                  let image = decode(data) else {
                throw AssistantAvatar.PersistenceError.invalidGenmojiData
            }
            guard let description = validGenmojiDescription(contentDescription) else {
                throw AssistantAvatar.PersistenceError.invalidGenmojiDescription
            }
            return (.genmoji(data: data, contentDescription: description), image)
        }
    }

    private func persistBuiltin(_ type: String, defaults: UserDefaults) {
        defaults.set(type, forKey: Self.typeKey)
        defaults.removeObject(forKey: Self.emojiKey)
        clearGenmojiPersistence(defaults: defaults)
    }

    private func clearGenmojiPersistence(defaults: UserDefaults) {
        defaults.removeObject(forKey: Self.genmojiKey)
        defaults.removeObject(forKey: Self.genmojiDescriptionKey)
    }

    private func validGenmojiDescription(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 256 else { return nil }
        return trimmed
    }

    private static func fingerprint(_ data: Data) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        return "\(data.count)-\(String(value, radix: 16))"
    }

    private static func decodeHEIF(_ data: Data) -> UIImage? {
        try? IconAssetCache.decodeRemoteHEIF(data: data, size: 512).image
    }
}
