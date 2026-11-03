import Foundation

/// This device's explicit permission for Oppi to send a person's content through a paired
/// server to an AI service: the model provider that answers prompts, or the speech or voice
/// backend that hears dictation and Live Voice (App Review guideline 5.1.2(i)).
///
/// One owner for the grants and the one gating decision every send path asks before user
/// content leaves the device: the composer, Quick Session, Oppi Control, server dictation, and
/// Live Voice ask in-app and may show the consent sheet; Siri, Shortcuts, and the Share
/// extension cannot, so they refuse and say to open Oppi.
///
/// **Scope: per device, per paired server, per recipient.** A model provider is a key in that
/// server's Pi configuration, sent with that server's credentials, and a custom provider name
/// can point anywhere, so a grant on one server never covers another. A voice backend is a
/// server setting too, and its identity includes where it sends audio, so switching backends
/// asks again. Grants live in the App Group defaults so the Share extension and Siri read the
/// same answer; they are never sent anywhere. Removing a server drops its grants.
struct AISharingConsent {
    /// Who receives the content, as the person is told.
    struct Recipient: Hashable, Codable, Sendable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            /// The model provider of the session's model: prompts, conversation context,
            /// attachments, and tool results.
            case modelProvider
            /// The server's speech-to-text backend for server dictation: microphone audio.
            case dictation
            /// The server's Live Voice backend: microphone audio during a call.
            case liveVoice
        }

        let kind: Kind
        /// Identity within a server: a Pi provider key, or a voice backend's target
        /// (`xAI`, an endpoint origin, or `server` when the server does not say).
        let id: String
        /// What the sheet and Settings call it: "Anthropic", "xAI", "a speech service on your
        /// server's computer".
        let name: String
        /// A voice backend on the server's own machine (a loopback endpoint), not a third party.
        var isOnServerComputer: Bool = false

        /// The model provider `providerKey` names (`anthropic`, `openrouter`), or nil for none.
        /// `isOnServerComputer` marks one whose models run on the server's own machine.
        static func modelProvider(_ providerKey: String?, isOnServerComputer: Bool = false) -> Recipient? {
            guard let key = normalizedProviderKey(providerKey) else { return nil }
            return Recipient(
                kind: .modelProvider,
                id: key,
                name: providerDisplayLabel(key),
                isOnServerComputer: isOnServerComputer
            )
        }

        /// The model provider a send reaches: `modelId`'s (a `provider/id` string or a catalog
        /// id), or with no model the server's catalog.
        ///
        /// With no model chosen, a listed default (`isDefault`) names the answer. A server that
        /// lists no default is still unambiguous when every model it offers is one company's:
        /// whichever model answers, that company receives the content.
        ///
        /// Nil when that names no single provider. A short id that several providers serve
        /// (`claude-sonnet-5` from Anthropic and GitHub Copilot) could go to either, so it is
        /// unknown rather than the first match: the sheet must name who really gets the content.
        static func modelProvider(modelId: String?, catalog: [CatalogModel]) -> Recipient? {
            let requested = modelId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requested.isEmpty else {
                let defaults = catalog.filter(\.isDefault)
                return servingProvider(defaults.isEmpty ? catalog : defaults) ?? nil
            }
            // A full id names its provider. Only when none matches is it read as a short id,
            // which is how the server resolves it too.
            for matches in [catalog.filter { $0.fullId == requested }, catalog.filter { $0.shortId == requested }] {
                if let recipient = servingProvider(matches) { return recipient }
            }
            guard let slash = requested.firstIndex(of: "/"), slash != requested.startIndex else { return nil }
            return modelProvider(String(requested[..<slash]))
        }

        /// The provider every model in `matches` belongs to: nil for no match (try another
        /// way), `.some(nil)` when they belong to more than one (ambiguous, so unknown).
        private static func servingProvider(_ matches: [CatalogModel]) -> Recipient?? {
            guard let first = matches.first else { return nil }
            guard matches.allSatisfy({ $0.provider == first.provider }) else { return .some(nil) }
            return .some(modelProvider(first.provider, isOnServerComputer: matches.allSatisfy(\.isLocal)))
        }

        /// A voice feature's backend from `/server/info` `voiceBackends[].target`: `xAI` for
        /// the cloud backend, an endpoint origin for an HTTP one, nil when the server does not
        /// report it.
        static func voice(_ kind: Kind, target: String?) -> Recipient {
            let trimmed = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                return Recipient(kind: kind, id: "server", name: String(localized: "your server's voice service"))
            }
            guard let host = URL(string: trimmed)?.host(percentEncoded: false)?.lowercased() else {
                // A provider name, such as `xAI`.
                return Recipient(kind: kind, id: trimmed, name: trimmed)
            }
            if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasPrefix("127.") {
                return Recipient(
                    kind: kind,
                    id: trimmed,
                    name: String(localized: "a speech service on your server's computer"),
                    isOnServerComputer: true
                )
            }
            return Recipient(kind: kind, id: trimmed, name: host)
        }

        /// The same recipient, whatever it is called now: a name is display only.
        func matches(_ other: Recipient) -> Bool {
            kind == other.kind && id == other.id
        }
    }

    struct Grant: Codable, Equatable, Sendable {
        let serverId: String
        let recipient: Recipient
        let grantedAt: Date
    }

    /// What a send path does now.
    enum Decision: Equatable, Sendable {
        /// Every recipient is allowed: send.
        case send
        /// Show the consent sheet for this recipient, then decide again.
        case ask(Recipient)
        /// Send nothing and show this message.
        case refuse(String)
    }

    /// A model in `GET /models`, as the decision needs it. The Share extension decodes it
    /// straight from the server's list; the app maps `ModelInfo`.
    struct CatalogModel: Decodable, Equatable, Sendable {
        let id: String
        let provider: String
        var isDefault: Bool = false
        /// The server reports the model runs on its own machine (`authKind: "local"`, a
        /// loopback endpoint), not at a third party.
        var isLocal: Bool = false

        init(id: String, provider: String, isDefault: Bool = false, isLocal: Bool = false) {
            self.id = id
            self.provider = provider
            self.isDefault = isDefault
            self.isLocal = isLocal
        }

        private enum CodingKeys: String, CodingKey { case id, provider, isDefault, authKind }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            provider = try c.decode(String.self, forKey: .provider)
            isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            isLocal = try c.decodeIfPresent(String.self, forKey: .authKind) == "local"
        }

        /// `provider/id`. Current servers list ids that way already; older ones list the short id.
        var fullId: String {
            id.hasPrefix("\(provider)/") ? id : "\(provider)/\(id)"
        }

        /// The id within its provider, which another provider can share.
        var shortId: String {
            String(fullId.dropFirst(provider.count + 1))
        }
    }

    static let storageKey = "aiSharingConsent.grants"

    let defaults: UserDefaults

    /// This device's grants, shared with the app's extensions.
    static var device: AISharingConsent { AISharingConsent(defaults: SharedConstants.sharedDefaults) }

    // MARK: - Grants

    var grants: [Grant] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let grants = try? JSONDecoder().decode([Grant].self, from: data) else { return [] }
        return grants
    }

    func isGranted(_ recipient: Recipient, serverId: String) -> Bool {
        grants.contains { $0.serverId == serverId && $0.recipient.matches(recipient) }
    }

    /// Allow: kept until withdrawn or the server is removed.
    func grant(_ recipient: Recipient, serverId: String, at date: Date = Date()) {
        var next = grants.filter { !($0.serverId == serverId && $0.recipient.matches(recipient)) }
        next.append(Grant(serverId: serverId, recipient: recipient, grantedAt: date))
        save(next)
    }

    /// Withdraw: the next send to this recipient asks again.
    func withdraw(_ recipient: Recipient, serverId: String) {
        save(grants.filter { !($0.serverId == serverId && $0.recipient.matches(recipient)) })
    }

    /// The server was removed from this device.
    func withdrawAll(serverId: String) {
        save(grants.filter { $0.serverId != serverId })
    }

    private func save(_ grants: [Grant]) {
        if grants.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(grants) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - The decision

    /// Whether content may go to every recipient now. A nil recipient is a model provider Oppi
    /// could not name (no model chosen and a catalog that lists several companies' models, or an
    /// id several providers serve), which is refused: the person must know who gets it. `canAsk`
    /// is false where no sheet can show (Siri, Shortcuts, the Share extension), which refuses
    /// instead of asking.
    func decide(_ recipients: [Recipient?], serverId: String, canAsk: Bool) -> Decision {
        for recipient in recipients {
            guard let recipient else { return .refuse(Self.unknownProviderMessage) }
            guard !isGranted(recipient, serverId: serverId) else { continue }
            return canAsk ? .ask(recipient) : .refuse(Self.openAppMessage(for: recipient))
        }
        return .send
    }

    static let unknownProviderMessage = String(
        localized: "Oppi can't tell which model provider would get this. Choose a model, then send again. Nothing was sent."
    )

    static func openAppMessage(for recipient: Recipient) -> String {
        String(
            localized: "Oppi hasn't been allowed to send your content to \(recipient.name) on this server. Open Oppi and send a message there to allow it. Nothing was sent."
        )
    }
}
