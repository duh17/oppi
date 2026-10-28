import Foundation

/// A server route that holds settings. One case per route in
/// `protocol/settings.json`; a declaration names the route and the field of its
/// JSON document it owns.
enum SettingEndpoint: String, Hashable, Sendable, CaseIterable {
    /// `GET`/`PUT /server/auto-title`: `{ enabled, model, revision? }`.
    case autoTitle = "/server/auto-title"

    var path: String { rawValue }

    /// The route's row in `protocol/settings.json`, where the server lists the
    /// setting's scope and whether its saves carry a revision.
    /// `SettingsCatalogContractTests` holds the declarations to that row.
    var registryKey: String {
        switch self {
        case .autoTitle: "autoTitle"
        }
    }
}

/// Which of Pi's settings files a Pi-owned setting is written to.
enum PiSettingsLevel: String, Hashable, Sendable {
    case global
    case project
}

/// Where a setting is stored, which decides the adapter that reads and writes
/// it and the scope the page says. The enum is the full set of places a
/// setting can live; a slice that needs one adds its adapter to
/// `SettingsStore` without reshaping a declaration.
enum SettingStorage: Hashable, Sendable {
    /// `UserDefaults` on this device. `perServer`: the value is kept per paired
    /// server (push enable, Live Activities, Dictation consent).
    case device(perServer: Bool)
    /// One field of a server route's document. `revisioned`: the route returns
    /// a `revision` and rejects a stale write with `409 revision_conflict`.
    case server(SettingEndpoint, revisioned: Bool)
    /// One field of a workspace.
    case workspace(field: String)
    /// This device's own value, kept on the server.
    case deviceOnServer(SettingEndpoint, field: String)
    /// Pi's own settings file, read and written through a server route.
    case piOwned(SettingEndpoint, level: PiSettingsLevel)

    /// The scope a page says for a setting kept here. `serverName` and
    /// `workspaceName` are the visible server's and workspace's names; a
    /// missing one reads as a generic noun rather than an empty string.
    func scope(serverName: String?, workspaceName: String?) -> SettingsScope {
        let server = serverName ?? String(localized: "this server")
        switch self {
        case .device(let perServer):
            return perServer ? .deviceOnServer(server) : .device
        case .server, .piOwned:
            return .server(server)
        case .workspace:
            return .workspace(workspaceName ?? String(localized: "this workspace"))
        case .deviceOnServer:
            return .deviceOnServer(server)
        }
    }
}

/// When a change is written.
enum SaveMode: Hashable, Sendable {
    /// A single control writes as soon as it changes.
    case immediate
    /// Fields that validate together, saved by one Save on the named form.
    case draft(form: String)
}

/// The words a setting carries with it, so every row and page that shows it
/// says the same thing.
struct SettingCopy: Hashable, Sendable {
    /// The row's title.
    var title: String
    /// What the setting does, for the section's footer.
    var footer: String?
    /// Words a person must agree to before the setting turns on.
    var consent: String?

    init(title: String, footer: String? = nil, consent: String? = nil) {
        self.title = title
        self.footer = footer
        self.consent = consent
    }
}

/// One setting, declared once: its identity, where it is stored, what it
/// defaults to, what it accepts, when it saves, and what it says. Rows, the
/// store, and the contract test with the server all read this.
struct SettingDeclaration<Value: Codable & Equatable & Sendable>: Sendable {
    /// The kit identifier: the accessibility identifier of the row that shows
    /// it, `settings.<page>.<row>`.
    let id: String
    /// The storage key: a `UserDefaults` key, or a field of the endpoint's JSON.
    let key: String
    let storage: SettingStorage
    let `default`: Value
    /// The reason a value is refused, or `nil` when it is acceptable.
    let validate: @Sendable (Value) -> String?
    let save: SaveMode
    let copy: SettingCopy

    init(
        id: String,
        key: String,
        storage: SettingStorage,
        default defaultValue: Value,
        validate: @escaping @Sendable (Value) -> String? = { _ in nil },
        save: SaveMode = .immediate,
        copy: SettingCopy
    ) {
        self.id = id
        self.key = key
        self.storage = storage
        self.default = defaultValue
        self.validate = validate
        self.save = save
        self.copy = copy
    }

    /// The type-erased identity, for the catalog's list and the contract test.
    var descriptor: SettingDescriptor {
        SettingDescriptor(id: id, key: key, storage: storage, valueType: String(describing: Value.self))
    }
}

/// A declaration without its value type.
struct SettingDescriptor: Hashable, Sendable {
    let id: String
    let key: String
    let storage: SettingStorage
    let valueType: String
}

/// The one place Oppi's settings are declared. A setting that is not here has
/// no row, no store entry, and no server field to agree on. See
/// `dev/architecture-client.md`, "Settings pages".
enum SettingsCatalog {
    // MARK: - Sessions

    /// Which backend names a session on this device. A device setting on the
    /// existing `AppPreferenceStore` key, so `AppPreferences` and the chat read
    /// the same value; it never writes a server field.
    static let autoNameProvider = SettingDeclaration<AppPreferenceStore.Session.AutoTitleProvider>(
        id: "settings.sessions.autoNameProvider",
        key: AppPreferenceStore.Session.autoTitleProviderKey,
        storage: .device(perServer: false),
        default: AppPreferenceStore.Session.autoTitleProviderDefault,
        copy: SettingCopy(title: String(localized: "Auto-Name"))
    )

    /// Whether the server names sessions from their first message, for every
    /// device that uses it.
    static let autoNameServerEnabled = SettingDeclaration<Bool>(
        id: "settings.sessions.autoNameServerEnabled",
        key: "enabled",
        storage: .server(.autoTitle, revisioned: true),
        default: false,
        copy: SettingCopy(
            title: String(localized: "Name Sessions on Server"),
            footer: String(localized: "The server names a new session from its first message, whichever device started it. It needs a model.")
        )
    )

    /// The model the server names sessions with (`provider/model`). Empty means
    /// none is chosen yet, and the server names nothing.
    static let autoNameServerModel = SettingDeclaration<String>(
        id: "settings.sessions.autoNameServerModel",
        key: "model",
        storage: .server(.autoTitle, revisioned: true),
        default: "",
        validate: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Choose a model.") : nil },
        copy: SettingCopy(title: String(localized: "Model"))
    )

    /// Every declared setting, type-erased. Ids and storage keys are unique
    /// across it (`SettingsCatalogTests`).
    static let all: [SettingDescriptor] = [
        autoNameProvider.descriptor,
        autoNameServerEnabled.descriptor,
        autoNameServerModel.descriptor,
    ]
}
